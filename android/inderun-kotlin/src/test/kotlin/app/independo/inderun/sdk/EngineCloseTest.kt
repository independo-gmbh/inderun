package app.independo.inderun.sdk

import app.independo.inderun.contracts.ArtifactOwner
import app.independo.inderun.contracts.ArtifactReadRequest
import app.independo.inderun.contracts.CancelSemantics
import app.independo.inderun.contracts.Code
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.Format
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.MediaArtifact
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.contracts.Outcome
import app.independo.inderun.contracts.PrepareRequest
import app.independo.inderun.contracts.ProviderDescriptor
import app.independo.inderun.contracts.ProviderDynamicCapabilities
import app.independo.inderun.contracts.ProviderReadiness
import app.independo.inderun.contracts.ProviderSupports
import app.independo.inderun.contracts.ProviderTaskAvailability
import app.independo.inderun.contracts.ProviderTaskCapability
import app.independo.inderun.contracts.ProviderTaskInteraction
import app.independo.inderun.contracts.ProviderTaskOutput
import app.independo.inderun.contracts.ProviderTransport
import app.independo.inderun.contracts.ProviderType
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.Source
import app.independo.inderun.contracts.SourceType
import app.independo.inderun.contracts.SpeechModelPackage
import app.independo.inderun.contracts.SpeechModelVoice
import app.independo.inderun.contracts.StreamEvent
import app.independo.inderun.contracts.TaskInputKind
import app.independo.inderun.contracts.TaskKind
import app.independo.inderun.contracts.TaskOutput
import app.independo.inderun.contracts.TaskOutputType
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TaskResultTelemetry
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ModelProfiles
import app.independo.inderun.core.PreparableProviderAdapter
import app.independo.inderun.core.ProviderPrepareContext
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.core.ProviderStreamContext
import app.independo.inderun.core.ProviderStreamEvent
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.StreamRun
import app.independo.inderun.core.StreamingProviderAdapter
import app.independo.inderun.providers.neuralspeech.FixtureNeuralSpeechRuntime
import app.independo.inderun.providers.neuralspeech.NeuralSpeechProvider
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.util.concurrent.atomic.AtomicInteger

/**
 * `IndeRun.close()`. Kotlin counterpart of Web `engine-close.test.ts` and Swift
 * `EngineCloseTests`. The registry is app-built, so close closes no providers and there is no
 * owned-resources case. Runs on real dispatchers: close hands its sequence to a dispatcher of its
 * own, so virtual time would not advance it.
 */
@RunWith(RobolectricTestRunner::class)
class EngineCloseTest {
    private val textRequest = conformanceRequest()

    private fun engineOf(vararg providers: app.independo.inderun.core.ProviderAdapter) = IndeRun(
        ProviderRegistry().apply { providers.forEach { register(it) } },
        conformanceHostServices(),
    )

    private fun test(block: suspend kotlinx.coroutines.CoroutineScope.() -> Unit) = runBlocking {
        withTimeout(20_000) { block() }
    }

    private fun assertSingleCancelledTerminal(events: List<StreamEvent>) {
        val terminals = events.filter { it.type == "terminal" }
        assertEquals(1, terminals.size)
        assertEquals("nothing follows the terminal", "terminal", events.last().type)
        assertEquals(Outcome.Cancelled, terminals.single().payload?.outcome)
    }

    private suspend fun assertEngineClosed(block: suspend () -> Unit) {
        try {
            block()
            fail("expected engine_closed")
        } catch (error: IndeRunException) {
            assertEquals(IndeRunErrorClass.Unavailable, error.errorClass)
            assertEquals("engine_closed", error.details?.get("code"))
        }
    }

    /** A text provider whose `run` waits for [release]. */
    private class GatedRunProvider : app.independo.inderun.core.ProviderAdapter {
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()

        override fun describe(): ProviderDescriptor = streamDescriptor("gated", streaming = false)

        override suspend fun capabilities(host: HostServices) = ProviderDynamicCapabilities(available = true)

        override suspend fun run(request: TaskRequest, context: RunContext): TaskResult {
            entered.complete(Unit)
            release.await()
            return TaskResult(
                schemaVersion = SchemaVersion.V1_0,
                runId = context.runId,
                output = TaskOutput(type = TaskOutputType.TEXT, text = "ok"),
                finishReason = FinishReason.STOP,
                telemetry = TaskResultTelemetry(providerUsed = "gated", totalMs = 0.0),
            )
        }
    }

    /** A preparable provider whose preparation never finishes on its own. */
    private class HangingPrepareProvider : PreparableProviderAdapter {
        val entered = CompletableDeferred<Unit>()

        @Volatile
        var wasCancelled = false

        override fun describe(): ProviderDescriptor = ProviderDescriptor(
            id = "hang",
            type = ProviderType.Local,
            transport = ProviderTransport.InProcess,
            supports = ProviderSupports(
                run = true,
                streaming = false,
                realtime = false,
                tools = false,
                reasoningEvents = false,
                structuredOutput = false,
                multimodal = false,
            ),
            cancel = CancelSemantics.Soft,
            tasks = listOf("text_to_text"),
            taskCapabilities = listOf(
                ProviderTaskCapability(
                    kind = "text_to_text",
                    inputs = listOf(TaskInputKind.Text),
                    interaction = ProviderTaskInteraction(prepare = true, run = true, stream = false),
                    cancel = CancelSemantics.Soft,
                    outputs = listOf(ProviderTaskOutput(delivery = app.independo.inderun.contracts.OutputDelivery.Inline)),
                ),
            ),
        )

        override suspend fun capabilities(host: HostServices) = ProviderDynamicCapabilities(
            available = true,
            taskCapabilities = listOf(ProviderTaskAvailability(kind = "text_to_text", readiness = ProviderReadiness.Cold)),
        )

        override suspend fun run(request: TaskRequest, context: RunContext): TaskResult = throw UnsupportedOperationException()

        override fun prepare(context: ProviderPrepareContext): Flow<app.independo.inderun.core.PreparationProgress> = flow {
            entered.complete(Unit)
            try {
                awaitCancellation()
            } catch (cancelled: kotlin.coroutines.cancellation.CancellationException) {
                wasCancelled = true
                throw cancelled
            }
        }
    }

    /** A streaming provider that emits up to [limit] deltas as fast as it is let, then waits for cancellation. */
    private class FloodingStreamProvider(private val limit: Int) : StreamingProviderAdapter {
        val emitted = AtomicInteger(0)

        override fun describe(): ProviderDescriptor = streamDescriptor("flood", streaming = true)

        override suspend fun capabilities(host: HostServices) = ProviderDynamicCapabilities(available = true)

        override suspend fun run(request: TaskRequest, context: RunContext): TaskResult = throw UnsupportedOperationException()

        override fun stream(request: TaskRequest, context: ProviderStreamContext): Flow<ProviderStreamEvent> = flow {
            repeat(limit) {
                emit(ProviderStreamEvent.Delta("x"))
                emitted.incrementAndGet()
            }
            awaitCancellation()
        }
    }

    /** A preparable provider that reports up to [limit] progress steps as fast as it is let, then hangs. */
    private class FloodingPrepareProvider(private val limit: Int) : PreparableProviderAdapter {
        private val hanging = HangingPrepareProvider()
        val emitted = AtomicInteger(0)

        override fun describe(): ProviderDescriptor = hanging.describe()

        override suspend fun capabilities(host: HostServices) = hanging.capabilities(host)

        override suspend fun run(request: TaskRequest, context: RunContext): TaskResult = throw UnsupportedOperationException()

        override fun prepare(context: ProviderPrepareContext): Flow<app.independo.inderun.core.PreparationProgress> = flow {
            repeat(limit) { step ->
                emit(app.independo.inderun.core.PreparationProgress(fractionCompleted = step.toDouble() / limit))
                emitted.incrementAndGet()
            }
            awaitCancellation()
        }
    }

    /**
     * Collects [run] on a collector that pauses forever after its first event, lets the producer
     * run until it is held by the full buffer, closes the engine (bounded), and then resumes the
     * collector to read what is left. Returns how many events the provider got out before close,
     * and every event the collector saw.
     */
    private suspend fun kotlinx.coroutines.CoroutineScope.closeUnderAPausedCollector(
        engine: IndeRun,
        run: StreamRun,
        emitted: AtomicInteger,
    ): Pair<Int, List<StreamEvent>> {
        val firstSeen = CompletableDeferred<Unit>()
        val resume = CompletableDeferred<Unit>()
        val events = java.util.Collections.synchronizedList(mutableListOf<StreamEvent>())
        val collector = launch(Dispatchers.Default) {
            run.events.collect { event ->
                events += event
                if (!firstSeen.isCompleted) {
                    firstSeen.complete(Unit)
                    resume.await()
                }
            }
        }
        firstSeen.await()
        // Wait until the bounded buffer holds the producer: it has filled the engine buffer at
        // least, and stopped advancing.
        withTimeout(10_000) {
            var last = -1
            while (emitted.get() < ENGINE_BUFFER || emitted.get() != last) {
                last = emitted.get()
                delay(50)
            }
        }
        val beforeClose = emitted.get()

        withTimeout(5_000) { engine.close() }

        resume.complete(Unit)
        withTimeout(5_000) { collector.join() }
        return beforeClose to events.toList()
    }

    @Test
    fun closeIsBoundedForAStreamWhoseCollectorPausesAndTheProducerIsHeldByABoundedBuffer() = test {
        val provider = FloodingStreamProvider(limit = 10_000)
        val engine = engineOf(provider)
        val run = engine.stream(textRequest)

        val (beforeClose, events) = closeUnderAPausedCollector(engine, run, provider.emitted)

        // The engine buffer plus the provider-event buffer, plus a few in hand: nowhere near the 10k the provider would emit.
        assertTrue("the producer buffered $beforeClose events", beforeClose <= 200)
        assertSingleCancelledTerminal(events)
        assertTrue(events.dropLast(1).all { it.type == "content_delta" })
        // A delta close dropped is not in the terminal's partial text either.
        assertEquals(events.dropLast(1).joinToString("") { it.payload?.text.orEmpty() }, events.last().payload?.partialText)
    }

    @Test
    fun closeIsBoundedForAPrepareWhoseCollectorPausesAndTheProducerIsHeldByABoundedBuffer() = test {
        val provider = FloodingPrepareProvider(limit = 10_000)
        val engine = engineOf(provider)
        val run = engine.prepare(PrepareRequest())

        val (beforeClose, events) = closeUnderAPausedCollector(engine, run, provider.emitted)

        assertTrue("the producer buffered $beforeClose events", beforeClose <= 200)
        assertSingleCancelledTerminal(events)
        assertTrue(events.dropLast(1).all { it.type == "preparation_progress" })
    }

    @Test
    fun closeCancelsAnInFlightStreamWithExactlyOneCancelledTerminalAndNothingAfter() = test {
        val provider = FakeStreamProvider("p1", listOf(Step.Emit(app.independo.inderun.core.ProviderStreamEvent.Delta("a")), Step.WaitForCancellation))
        val engine = engineOf(provider)
        val run = engine.stream(textRequest)
        val collected = async(Dispatchers.Default) { run.events.toList() }
        provider.started.await()

        engine.close()

        assertSingleCancelledTerminal(collected.await())
        assertTrue(provider.wasInterrupted)
    }

    @Test
    fun closeCancelsAnInFlightPrepare() = test {
        val provider = HangingPrepareProvider()
        val engine = engineOf(provider)
        val run = engine.prepare(PrepareRequest())
        val collected = async(Dispatchers.Default) { run.events.toList() }
        provider.entered.await()

        engine.close()

        assertSingleCancelledTerminal(collected.await())
        assertTrue(provider.wasCancelled)
    }

    @Test
    fun closeWaitsForAnInFlightRunToSettleAndDoesNotCancelIt() = test {
        val provider = GatedRunProvider()
        val engine = engineOf(provider)
        val run = async(Dispatchers.Default) { engine.run(textRequest) }
        provider.entered.await()

        val closing = async(Dispatchers.Default) { engine.close() }
        delay(50)
        assertFalse("close must wait for the run", closing.isCompleted)

        provider.release.complete(Unit)
        closing.await()
        assertEquals("ok", run.await().output?.text)
    }

    @Test
    fun callsAfterCloseRejectWithEngineClosed() = test {
        val engine = engineOf(FakeStreamProvider("p1"))
        engine.close()

        assertEngineClosed { engine.run(textRequest) }
        assertEngineClosed { engine.stream(textRequest) }
        assertEngineClosed { engine.prepare(PrepareRequest()) }
        assertEngineClosed { engine.readArtifact(ArtifactReadRequest(artifactId = "x")) }
        assertEngineClosed { engine.speak(SpeakOptions("Hallo", "de-AT"), this) }
        assertEngineClosed { engine.generateSpeech(GenerateSpeechOptions(SpeakOptions("Hallo", "de-AT"))) }
        // checkCapabilities cannot throw on Swift, so every SDK reports no providers once closed.
        assertTrue(engine.checkCapabilities().isEmpty())
        // disposeArtifact is a no-op that does not throw.
        engine.disposeArtifact(MediaArtifact(id = "x", mediaType = "audio/wav", owner = ArtifactOwner.Engine, lifetime = app.independo.inderun.contracts.ArtifactLifetime.UntilDisposed))
    }

    @Test
    fun concurrentCloseClosesOnce() = test {
        val provider = FakeStreamProvider("p1", listOf(Step.WaitForCancellation))
        val engine = engineOf(provider)
        val run = engine.stream(textRequest)
        val collected = async(Dispatchers.Default) { run.events.toList() }
        provider.started.await()

        listOf(
            async(Dispatchers.Default) { engine.close() },
            async(Dispatchers.Default) { engine.close() },
        ).awaitAll()
        engine.close()

        assertSingleCancelledTerminal(collected.await())
    }

    @Test
    fun closeRacingStreamStartEndsInEngineClosedOrOneCancelledTerminal() = test {
        repeat(20) {
            val engine = engineOf(FakeStreamProvider("p1", listOf(Step.WaitForCancellation)))
            val starting = async(Dispatchers.Default) { runCatching { engine.stream(textRequest) } }
            val closing = async(Dispatchers.Default) { engine.close() }
            val outcome = starting.await()
            closing.await()

            outcome.fold(
                onSuccess = { run -> assertSingleCancelledTerminal(run.events.toList()) },
                onFailure = { error ->
                    assertEquals("engine_closed", (error as IndeRunException).details?.get("code"))
                },
            )
            assertEngineClosed { engine.stream(textRequest) }
        }
    }

    @Test
    fun aStreamNeverCollectedDoesNotBlockCloseAndAnyLaterCollectionSeesOneCancelledTerminal() = test {
        val provider = FakeStreamProvider("p1", listOf(Step.Emit(app.independo.inderun.core.ProviderStreamEvent.Delta("a")), Step.WaitForCancellation))
        val engine = engineOf(provider)
        val run = engine.stream(textRequest)

        engine.close()

        assertSingleCancelledTerminal(run.events.toList())
    }

    @Test
    fun aCollectorPausedBetweenEventsSeesOneCancelledTerminalAfterClose() = test {
        val provider = FakeStreamProvider("p1", listOf(Step.Emit(app.independo.inderun.core.ProviderStreamEvent.Delta("a")), Step.WaitForCancellation))
        val engine = engineOf(provider)
        val run = engine.stream(textRequest)
        val firstSeen = CompletableDeferred<Unit>()
        val resume = CompletableDeferred<Unit>()
        val events = mutableListOf<StreamEvent>()
        val collector = launch(Dispatchers.Default) {
            run.events.collect { event ->
                events += event
                if (event.type == "content_delta" && !firstSeen.isCompleted) {
                    firstSeen.complete(Unit)
                    resume.await()
                }
            }
        }
        firstSeen.await()

        // The collector is paused inside its handler: close must neither hang on it nor lose the terminal.
        engine.close()
        resume.complete(Unit)
        collector.join()

        assertSingleCancelledTerminal(events)
    }

    @Test
    fun closeDisposesEngineOwnedArtifacts() = test {
        val world = NeuralWorld()
        val generated = world.engine.generateSpeech(GenerateSpeechOptions(SpeakOptions("Hallo", "de-DE", model = PROFILE)))
        val artifactId = generated.artifact.id
        assertNotNull(world.engine.readArtifact(ArtifactReadRequest(artifactId = artifactId)))

        world.engine.close()

        assertNull(world.engine.artifacts.bytes(artifactId))
    }

    @Test
    fun closeDoesNotCloseAnAppSuppliedRuntime() = test {
        val runtime = FixtureNeuralSpeechRuntime()
        val a = NeuralWorld(runtime)
        val b = NeuralWorld(runtime)

        a.engine.close()
        val spoken = b.engine.speak(SpeakOptions("Hallo", "de-DE", model = PROFILE), this).result.await()
        assertTrue(spoken.finishReason != FinishReason.CANCELLED)
        assertEquals(b.neural.id, spoken.provenance?.providerId)
        assertEquals(0, b.fallback.callCount)

        runtime.close()
        val after = b.engine.speak(SpeakOptions("Hallo", "de-DE", model = PROFILE), this).result.await()
        assertEquals("fallback", after.provenance?.providerId)
        assertEquals(1, b.fallback.callCount)
        // A closed runtime reports itself unavailable, so routing skips the neural provider.
        val rejection = after.provenance!!.routeRejections.first()
        assertEquals(b.neural.id, rejection.providerId)
        assertEquals(listOf(Code.CapabilityUnavailable), rejection.codes)
    }

    // region World

    private class NeuralWorld(runtime: FixtureNeuralSpeechRuntime = FixtureNeuralSpeechRuntime()) {
        val neural = NeuralSpeechProvider(MODEL_PACKAGE, runtime)
        val fallback = FakeStreamProvider(
            "fallback",
            script = listOf(
                Step.Emit(
                    app.independo.inderun.core.ProviderStreamEvent.Result(
                        TaskOutput(type = TaskOutputType.PLAYBACK, playback = app.independo.inderun.contracts.PlaybackOutput()),
                        FinishReason.STOP,
                    ),
                ),
            ),
            task = TaskKind.TEXT_TO_SPEECH,
        )
        val engine = IndeRun(
            ProviderRegistry().apply {
                register(neural)
                register(fallback)
            },
            conformanceHostServices().copy(audioOutput = FixtureAudioOutputService()),
            modelProfiles = ModelProfiles(mapOf(PROFILE to listOf(neural.id, "fallback"))),
        )
    }

    // endregion

    private companion object {
        const val PROFILE = "chain"

        /** `EventOutlet.CAPACITY`, the engine's event buffer. */
        const val ENGINE_BUFFER = 64

        val MODEL_PACKAGE = ModelPackage(
            id = "fixture-tts",
            version = "1",
            format = Format.Onnx,
            tasks = listOf("text_to_speech"),
            source = Source(sourceType = SourceType.AppManaged),
            speech = SpeechModelPackage(
                pipeline = "fixture",
                sampleRate = 24000,
                graphs = mapOf("acoustic" to "acoustic.onnx"),
                voices = listOf(SpeechModelVoice(id = "v_de", name = "German", locales = listOf("de-AT", "de-DE"))),
            ),
        )
    }
}
