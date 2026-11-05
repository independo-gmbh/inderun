package app.independo.inderun.providers.neuralspeech

import app.independo.inderun.contracts.CancelSemantics
import app.independo.inderun.contracts.Format
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.MediaArtifact
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.contracts.OutputDelivery
import app.independo.inderun.contracts.OutputDeliveryRequest
import app.independo.inderun.contracts.ProviderDescriptor
import app.independo.inderun.contracts.ProviderPrivacy
import app.independo.inderun.contracts.ProviderReadiness
import app.independo.inderun.contracts.ProviderSupports
import app.independo.inderun.contracts.ProviderTaskCapability
import app.independo.inderun.contracts.ProviderTaskInteraction
import app.independo.inderun.contracts.ProviderTaskOutput
import app.independo.inderun.contracts.ProviderTransport
import app.independo.inderun.contracts.ProviderType
import app.independo.inderun.contracts.ProviderVoice
import app.independo.inderun.contracts.Runtime
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.Source
import app.independo.inderun.contracts.SourceType
import app.independo.inderun.contracts.SpeechInput
import app.independo.inderun.contracts.SpeechModelPackage
import app.independo.inderun.contracts.SpeechModelVoice
import app.independo.inderun.contracts.TaskInputKind
import app.independo.inderun.contracts.TaskKind
import app.independo.inderun.contracts.TaskOutputType
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestConstraints
import app.independo.inderun.contracts.TaskRequestTask
import app.independo.inderun.contracts.VoiceGender
import app.independo.inderun.core.ArtifactSink
import app.independo.inderun.core.ArtifactSpec
import app.independo.inderun.core.ArtifactStore
import app.independo.inderun.core.ArtifactWriter
import app.independo.inderun.core.AudioOutputFormat
import app.independo.inderun.core.AudioOutputService
import app.independo.inderun.core.AudioOutputSession
import app.independo.inderun.core.ClockService
import app.independo.inderun.core.ConnectivityService
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderPrepareContext
import app.independo.inderun.core.ProviderStreamContext
import app.independo.inderun.core.ProviderStreamEvent
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.SecureStorageService
import app.independo.inderun.core.StreamCancellationToken
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** A recording audio output whose writes return at once, unless [writeDelayMs] or [holdDrain] say otherwise. */
private class RecordingAudioOutput(
    private val writeDelayMs: Long = 0,
    private val holdDrain: Boolean = false,
) : AudioOutputService {
    val sessions = mutableListOf<Session>()

    /** Completed once a session's `drain()` has started. */
    val drainStarted = CompletableDeferred<Unit>()

    inner class Session : AudioOutputSession {
        var writtenFrames = 0
        var stops = 0
        private val released = CompletableDeferred<Unit>()

        override suspend fun write(samples: ShortArray) {
            if (stops > 0) return
            if (writeDelayMs > 0) delay(writeDelayMs)
            writtenFrames += samples.size
        }

        override suspend fun drain() {
            drainStarted.complete(Unit)
            if (holdDrain) released.await()
        }

        override fun stop() {
            stops += 1
            released.complete(Unit)
        }

        override fun firstAudioMs(): Double? = if (writtenFrames > 0) 0.0 else null
    }

    override suspend fun open(format: AudioOutputFormat): AudioOutputSession = Session().also { sessions += it }
}

/** Produces every sentence's chunks at the wrong rate. */
private class WrongRateRuntime : NeuralSpeechRuntime {
    override suspend fun availability(modelPackage: ModelPackage) = NeuralSpeechAvailability(true)

    override suspend fun prepare(modelPackage: ModelPackage) = NeuralSpeechAvailability(true)

    override fun synthesize(input: NeuralSpeechSynthesisInput): Flow<PcmChunk> = flow {
        emit(PcmChunk(ShortArray(1600), sampleRate = 16000, isLast = true))
    }
}

/** The fixture runtime, suspending for [delayMs] (sentence number from 1) before each sentence's first chunk. */
private class PacedRuntime(private val delayMs: (sentence: Int) -> Long) : NeuralSpeechRuntime {
    private val fixture = FixtureNeuralSpeechRuntime()
    private var calls = 0

    override suspend fun availability(modelPackage: ModelPackage) = fixture.availability(modelPackage)

    override suspend fun prepare(modelPackage: ModelPackage) = fixture.prepare(modelPackage)

    override fun synthesize(input: NeuralSpeechSynthesisInput): Flow<PcmChunk> {
        calls += 1
        val wait = delayMs(calls)
        return flow {
            delay(wait)
            emitAll(fixture.synthesize(input))
        }
    }
}

/** A runtime stuck in work that ignores cancellation, as a blocking inference call is, until [gate] completes. */
private class StuckRuntime(private val gate: CompletableDeferred<Unit>) : NeuralSpeechRuntime {
    private val fixture = FixtureNeuralSpeechRuntime()

    override suspend fun availability(modelPackage: ModelPackage) = fixture.availability(modelPackage)

    override suspend fun prepare(modelPackage: ModelPackage) = fixture.prepare(modelPackage)

    override fun synthesize(input: NeuralSpeechSynthesisInput): Flow<PcmChunk> = flow {
        withContext(NonCancellable) { gate.await() }
        emitAll(fixture.synthesize(input))
    }
}

/**
 * An audio output whose `write` blocks without honouring cancellation, as `AudioTrack.write(...,
 * WRITE_BLOCKING)` does, until the session is stopped.
 */
private class BlockingWriteAudioOutput : AudioOutputService {
    /** Completed once a `write` is blocked. */
    val writeBlocked = CompletableDeferred<Unit>()
    private val released = CompletableDeferred<Unit>()

    @Volatile
    var stops = 0
        private set

    /** Frees a blocked write without stopping, so a test that failed does not hang. */
    fun release() {
        released.complete(Unit)
    }

    override suspend fun open(format: AudioOutputFormat): AudioOutputSession = object : AudioOutputSession {
        override suspend fun write(samples: ShortArray) {
            writeBlocked.complete(Unit)
            withContext(NonCancellable) { released.await() }
        }

        override suspend fun drain() = Unit

        override fun stop() {
            stops += 1
            released.complete(Unit)
        }

        override fun firstAudioMs(): Double? = null
    }
}

/** Yields three chunks from one buffer it refills with 1, 2 and 3, as a runtime reusing scratch memory does. */
private class ScratchBufferRuntime : NeuralSpeechRuntime {
    override suspend fun availability(modelPackage: ModelPackage) = NeuralSpeechAvailability(true)

    override suspend fun prepare(modelPackage: ModelPackage) = NeuralSpeechAvailability(true)

    override fun synthesize(input: NeuralSpeechSynthesisInput): Flow<PcmChunk> = flow {
        val scratch = ShortArray(4)
        for (fill in 1..3) {
            scratch.fill(fill.toShort())
            emit(PcmChunk(scratch, sampleRate = 24000, isLast = fill == 3))
        }
    }
}

/** Wraps a sink, recording what its writers were handed; [onWrite] runs before each write. */
private class SpyArtifacts(private val inner: ArtifactSink, private val onWrite: () -> Unit = {}) : ArtifactSink {
    val written = mutableListOf<ByteArray>()
    var finishCalls = 0
    var aborts = 0

    override fun create(spec: ArtifactSpec): ArtifactWriter {
        val writer = inner.create(spec)
        return object : ArtifactWriter {
            override fun write(bytes: ByteArray) {
                onWrite()
                written += bytes.copyOf()
                writer.write(bytes)
            }

            override fun finish(): MediaArtifact {
                finishCalls += 1
                return writer.finish()
            }

            override fun abort() {
                aborts += 1
                writer.abort()
            }
        }
    }
}

/** The data section of a canonical WAV, as samples. */
private fun wavSamples(bytes: ByteArray): List<Int> = (44 until bytes.size step 2).map { at ->
    ((bytes[at + 1].toInt() shl 8) or (bytes[at].toInt() and 0xFF)).toShort().toInt()
}

/** A runtime whose availability check throws. */
private class ThrowingAvailabilityRuntime : NeuralSpeechRuntime {
    private val fixture = FixtureNeuralSpeechRuntime()

    override suspend fun availability(modelPackage: ModelPackage): NeuralSpeechAvailability = throw IllegalStateException("onnxruntime is missing")

    override suspend fun prepare(modelPackage: ModelPackage) = fixture.prepare(modelPackage)

    override fun synthesize(input: NeuralSpeechSynthesisInput): Flow<PcmChunk> = fixture.synthesize(input)
}

class NeuralSpeechProviderTest {
    private val voices = listOf(
        SpeechModelVoice(id = "v_de", name = "Fixture German", locales = listOf("de-DE", "de-AT"), gender = VoiceGender.Female),
        SpeechModelVoice(id = "v_at", name = "Fixture Austrian", locales = listOf("de-AT")),
        SpeechModelVoice(id = "v_en", name = "Fixture English", locales = listOf("en-US"), gender = VoiceGender.Male),
    )

    private val pkg = ModelPackage(
        id = "fixture-tts",
        version = "1",
        format = Format.Onnx,
        tasks = listOf("text_to_speech"),
        source = Source(sourceType = SourceType.AppManaged),
        speech = SpeechModelPackage(
            pipeline = "fixture",
            sampleRate = 24000,
            graphs = mapOf("acoustic" to "acoustic.onnx"),
            voices = voices,
        ),
    )

    private fun request(
        delivery: OutputDelivery = OutputDelivery.Playback,
        text: String = "Hallo Welt.",
        timeoutMs: Long? = null,
    ) = TaskRequest(
        schemaVersion = SchemaVersion.V1_0,
        task = TaskRequestTask(kind = TaskKind.TEXT_TO_SPEECH),
        constraints = timeoutMs?.let { TaskRequestConstraints(timeoutMs = it) },
        speech = SpeechInput(locale = "de-AT", text = text),
        delivery = OutputDeliveryRequest(mode = delivery),
    )

    private fun host(audioOutput: AudioOutputService? = null) = HostServices(
        connectivity = object : ConnectivityService {
            override fun isOnline() = true
        },
        secureStorage = object : SecureStorageService {
            override fun get(authContextRef: String): String? = null

            override fun put(authContextRef: String, value: String) = Unit

            override fun remove(authContextRef: String) = Unit
        },
        clock = object : ClockService {
            override fun elapsedRealtimeMillis() = 1_000L
        },
        audioOutput = audioOutput,
    )

    /** A context whose `commit()` counts its calls. */
    private class Commits {
        var count = 0
        val handler: () -> Boolean = {
            count += 1
            true
        }
    }

    private fun runContext(audioOutput: AudioOutputService? = null, commits: Commits = Commits(), voice: ProviderVoice? = null) = RunContext(
        "run_1",
        host(audioOutput),
        voice = voice,
        commitHandler = commits.handler,
    )

    private fun prepareContext() = ProviderPrepareContext(runId = "prep_1", hostServices = host(), task = "text_to_speech")

    private fun provider(
        options: FixtureNeuralSpeechRuntimeOptions = FixtureNeuralSpeechRuntimeOptions(),
        modelPackage: ModelPackage = pkg,
        id: String? = null,
        timeoutMs: Long? = null,
    ): Pair<NeuralSpeechProvider, FixtureNeuralSpeechRuntime> {
        val runtime = FixtureNeuralSpeechRuntime(options)
        return NeuralSpeechProvider(modelPackage, runtime, id = id, timeoutMs = timeoutMs) to runtime
    }

    private suspend fun refusal(block: suspend () -> Unit): IndeRunException {
        try {
            block()
        } catch (error: IndeRunException) {
            return error
        }
        fail("expected an IndeRunException")
        error("unreachable")
    }

    // --- descriptor and capabilities ---------------------------------------------------------

    @Test
    fun describesAHardCancelInProcessSpeechProvider() {
        val (provider) = provider()

        assertEquals("local.onnx.speech.android:fixture-tts", provider.id)
        assertEquals(
            ProviderDescriptor(
                id = "local.onnx.speech.android:fixture-tts",
                type = ProviderType.Local,
                model = "fixture-tts",
                transport = ProviderTransport.InProcess,
                supports = ProviderSupports(
                    run = true,
                    streaming = true,
                    realtime = false,
                    tools = false,
                    reasoningEvents = false,
                    structuredOutput = false,
                    multimodal = false,
                ),
                cancel = CancelSemantics.Hard,
                tasks = listOf("text_to_speech"),
                taskCapabilities = listOf(
                    ProviderTaskCapability(
                        kind = "text_to_speech",
                        inputs = listOf(TaskInputKind.Text),
                        interaction = ProviderTaskInteraction(prepare = true, run = true, stream = true),
                        cancel = CancelSemantics.Hard,
                        outputs = listOf(
                            ProviderTaskOutput(delivery = OutputDelivery.Playback),
                            ProviderTaskOutput(delivery = OutputDelivery.Artifact, mediaTypes = listOf("audio/wav")),
                        ),
                        locales = listOf("de-DE", "de-AT", "en-US"),
                        privacy = ProviderPrivacy(dataLeavesDevice = false),
                    ),
                ),
                privacy = ProviderPrivacy(dataLeavesDevice = false),
            ),
            provider.describe(),
        )
    }

    @Test
    fun takesAnExplicitId() {
        val (provider) = provider(id = "speech")

        assertEquals("speech", provider.id)
        assertEquals("speech", provider.describe().id)
    }

    @Test
    fun capabilityCheckNeverLoadsTheModelAndReportsItCold() = runTest {
        val (provider, runtime) = provider()
        provider.capabilities(host())
        val capabilities = provider.capabilities(host())

        assertEquals(0, runtime.prepareCalls)
        assertTrue(capabilities.available)
        val task = capabilities.taskCapabilities!!.single()
        assertEquals(ProviderReadiness.Cold, task.readiness)
        assertEquals(
            listOf(
                ProviderVoice(
                    id = "v_de",
                    name = "Fixture German",
                    locale = "de-DE",
                    locales = listOf("de-DE", "de-AT"),
                    gender = VoiceGender.Female,
                    networkRequired = false,
                ),
                ProviderVoice(id = "v_at", name = "Fixture Austrian", locale = "de-AT", locales = listOf("de-AT"), networkRequired = false),
                ProviderVoice(
                    id = "v_en",
                    name = "Fixture English",
                    locale = "en-US",
                    locales = listOf("en-US"),
                    gender = VoiceGender.Male,
                    networkRequired = false,
                ),
            ),
            task.voices,
        )
    }

    @Test
    fun refusesAMalformedPackageAPackageWithoutSpeechAnUnsupportedSourceTypeAnUnsupportedPlatformAndWhatTheRuntimeRefuses() = runTest {
        val voice = voices.first()
        val cases = listOf(
            Triple(pkg.copy(speech = pkg.speech!!.copy(voices = listOf(voice, voice))), null, "model package malformed:"),
            Triple(ModelPackage(id = "text-only", format = Format.Onnx, tasks = listOf("text_to_text")), null, "unsupported task:"),
            Triple(pkg.copy(source = Source(sourceType = SourceType.Registry, ref = "fixture/tts")), null, "model source unavailable:"),
            Triple(pkg.copy(runtime = Runtime(platforms = listOf("ios", "web"))), null, "platform unsupported:"),
            Triple(pkg.copy(speech = pkg.speech!!.copy(channels = 2)), null, "unsupported channels: 2"),
            Triple(
                pkg,
                FixtureNeuralSpeechRuntimeOptions(availability = NeuralSpeechAvailability(false, "unsupported pipeline: kokoro")),
                "unsupported pipeline: kokoro",
            ),
        )

        for ((modelPackage, options, reason) in cases) {
            val (provider) = provider(options ?: FixtureNeuralSpeechRuntimeOptions(), modelPackage)
            val capabilities = provider.capabilities(host())

            assertEquals(reason, false, capabilities.available)
            if (options == null) {
                assertTrue("${capabilities.reason} starts with $reason", capabilities.reason!!.startsWith(reason))
            } else {
                assertEquals(reason, capabilities.reason)
            }
        }
    }

    @Test
    fun acceptsAFilesystemSourceAndAPackageThatListsAndroid() = runTest {
        val modelPackage = pkg.copy(
            source = Source(sourceType = SourceType.Filesystem, ref = "/data/models/tts"),
            runtime = Runtime(platforms = listOf("ios", "android")),
        )
        val (provider) = provider(modelPackage = modelPackage)

        assertTrue(provider.capabilities(host()).available)
    }

    @Test
    fun remembersALoadFailure() = runTest {
        val (provider, runtime) = provider(
            FixtureNeuralSpeechRuntimeOptions(prepareResult = NeuralSpeechAvailability(false, "graph missing")),
        )

        val error = refusal { provider.prepare(prepareContext()).collect() }

        assertEquals(IndeRunErrorClass.CapabilityMismatch, error.errorClass)
        val capabilities = provider.capabilities(host())
        assertEquals(false, capabilities.available)
        assertEquals("graph missing", capabilities.reason)
        assertEquals(1, runtime.prepareCalls)
    }

    @Test
    fun reportsReadinessAbsentOncePrepared() = runTest {
        val (provider, runtime) = provider()

        provider.prepare(prepareContext()).collect()
        val capabilities = provider.capabilities(host())

        assertEquals(1, runtime.prepareCalls)
        assertTrue(capabilities.available)
        val task = capabilities.taskCapabilities!!.single()
        assertNull(task.readiness)
        assertEquals(3, task.voices?.size)
    }

    // --- refusals before commit --------------------------------------------------------------

    @Test
    fun refusesAnInlineDeliveryAndANonSpeechRequestBeforeCommit() = runTest {
        val (provider, runtime) = provider()
        val audio = RecordingAudioOutput()
        val commits = Commits()

        val inline = refusal { provider.run(request(delivery = OutputDelivery.Inline), runContext(audio, commits)) }
        val text = refusal {
            provider.run(
                TaskRequest(schemaVersion = SchemaVersion.V1_0, task = TaskRequestTask(kind = TaskKind.TEXT_TO_TEXT), prompt = "Hello"),
                runContext(audio, commits),
            )
        }

        assertEquals(IndeRunErrorClass.CapabilityMismatch, inline.errorClass)
        assertEquals(IndeRunErrorClass.CapabilityMismatch, text.errorClass)
        assertEquals(0, commits.count)
        assertEquals(0, audio.sessions.size)
        assertEquals(0, runtime.synthesized.size)
    }

    @Test
    fun refusesAChunkAtAnotherSampleRateBeforeCommit() = runTest {
        val provider = NeuralSpeechProvider(pkg, WrongRateRuntime())
        val audio = RecordingAudioOutput()
        val commits = Commits()

        val error = refusal { provider.run(request(), runContext(audio, commits)) }

        assertEquals(IndeRunErrorClass.Internal, error.errorClass)
        assertEquals(0, commits.count)
        assertEquals(0, audio.sessions.single().writtenFrames)
        assertEquals(1, audio.sessions.single().stops)
    }

    // --- timeout -----------------------------------------------------------------------------

    @Test
    fun reportsARuntimeWhoseAvailabilityCheckThrowsAsUnavailable() = runTest {
        val provider = NeuralSpeechProvider(pkg, ThrowingAvailabilityRuntime())

        val capabilities = provider.capabilities(host())

        assertEquals(false, capabilities.available)
        assertEquals("runtime availability failed: onnxruntime is missing", capabilities.reason)
    }

    @Test
    fun timesOutBeforeCommitWhenTheFirstChunkIsSlowerThanTimeoutMs() = runTest {
        val (provider) = provider(FixtureNeuralSpeechRuntimeOptions(delayMs = 50), timeoutMs = 20)
        val audio = RecordingAudioOutput()
        val commits = Commits()

        val error = refusal { provider.run(request(), runContext(audio, commits)) }

        assertEquals(IndeRunErrorClass.Timeout, error.errorClass)
        assertEquals(0, commits.count)
        assertEquals(0, audio.sessions.single().writtenFrames)
        assertTrue(audio.sessions.single().stops > 0)
    }

    @Test
    fun doesNotTimeOutASlowSentenceAfterCommit() = runTest {
        val provider = NeuralSpeechProvider(pkg, PacedRuntime { sentence -> if (sentence == 2) 60 else 0 })
        val audio = RecordingAudioOutput()
        val commits = Commits()

        val result = provider.run(request(text = "Hallo Welt. Wie geht es dir?", timeoutMs = 20), runContext(audio, commits))

        assertEquals(TaskOutputType.PLAYBACK, result.output.type)
        assertEquals(1, commits.count)
        // 27 characters across the two sentences: 1350 ms.
        assertEquals(32400, audio.sessions.single().writtenFrames)
    }

    @Test
    fun boundsAnArtifactsWholeSynthesisWithTimeoutMs() = runTest {
        // Each sentence alone fits the budget; both together do not.
        val provider = NeuralSpeechProvider(pkg, PacedRuntime { 40 })
        val commits = Commits()

        val error = refusal {
            provider.run(
                request(delivery = OutputDelivery.Artifact, text = "Hallo Welt. Wie geht es dir?", timeoutMs = 60),
                runContext(audioOutput = null, commits = commits),
            )
        }

        assertEquals(IndeRunErrorClass.Timeout, error.errorClass)
        assertEquals(0, commits.count)
    }

    @Test
    fun timesOutWithoutWaitingForARuntimeThatIgnoresCancellation() = runTest {
        val gate = CompletableDeferred<Unit>()
        val provider = NeuralSpeechProvider(pkg, StuckRuntime(gate), timeoutMs = 20)
        val audio = RecordingAudioOutput()
        val commits = Commits()
        // Frees the runtime long after the budget, so a provider that waits for it fails below
        // instead of hanging the test.
        backgroundScope.launch {
            delay(5_000)
            gate.complete(Unit)
        }

        val error = withTimeout(1_000) { refusal { provider.run(request(), runContext(audio, commits)) } }

        assertEquals(IndeRunErrorClass.Timeout, error.errorClass)
        assertTrue("the runtime is still stuck", !gate.isCompleted)
        assertEquals(0, commits.count)
        assertTrue(audio.sessions.single().stops > 0)
    }

    @Test
    fun treatsATimeoutMsOfZeroOrLessAsUnbounded() = runTest {
        val (provider) = provider(FixtureNeuralSpeechRuntimeOptions(delayMs = 5), timeoutMs = 0)
        val commits = Commits()

        val result = provider.run(request(), runContext(RecordingAudioOutput(), commits))

        assertEquals(TaskOutputType.PLAYBACK, result.output.type)
        assertEquals(1, commits.count)
    }

    @Test
    fun doesNotCountPlaybackBackpressureAgainstTheTimeout() = runTest {
        // Each write takes 50 ms and the runtime answers at once: only the runtime's time counts.
        val (provider) = provider(timeoutMs = 20)
        val audio = RecordingAudioOutput(writeDelayMs = 50)

        val result = provider.run(request(), runContext(audio))

        assertEquals(TaskOutputType.PLAYBACK, result.output.type)
        assertEquals(13200, audio.sessions.single().writtenFrames)
    }

    // --- after commit ------------------------------------------------------------------------

    @Test
    fun playsEverySentenceAndReportsWhatSpoke() = runTest {
        val (provider, runtime) = provider()
        val audio = RecordingAudioOutput()
        val commits = Commits()

        val result = provider.run(request(text = "Hallo Welt. Wie geht es dir?"), runContext(audio, commits))

        assertEquals(1, commits.count)
        assertEquals(listOf("Hallo Welt.", "Wie geht es dir?"), runtime.synthesized.map { it.text })
        assertEquals(listOf("de-AT", "de-AT"), runtime.synthesized.map { it.locale })
        assertEquals(listOf("v_de", "v_de"), runtime.synthesized.map { it.voiceId })
        val session = audio.sessions.single()
        // 27 characters across the two sentences: 1350 ms.
        assertEquals(32400, session.writtenFrames)
        assertEquals(1, session.stops)
        val timing = result.output.playback?.timing!!
        assertEquals(1350.0, timing.durationMs!!, 1e-9)
        assertTrue(timing.firstChunkMs!! >= 0)
        assertTrue(timing.firstAudioMs!! >= 0)
        assertEquals("de-AT", result.output.speech?.locale)
        assertEquals("v_de", result.output.speech?.voice?.id)
        assertEquals("Fixture German", result.output.speech?.voice?.name)
    }

    @Test
    fun refusesABoundVoiceThePackageLacksBeforeCommit() = runTest {
        val (provider) = provider()
        val audio = RecordingAudioOutput()
        val commits = Commits()

        val error = refusal {
            provider.run(request(), runContext(audio, commits, voice = ProviderVoice(id = "ghost", locale = "de-AT")))
        }

        assertEquals(IndeRunErrorClass.CapabilityMismatch, error.errorClass)
        assertEquals("voice_not_available", error.details?.get("code"))
        assertEquals(0, commits.count)
        assertEquals(0, audio.sessions.size)
    }

    @Test
    fun throwsARuntimeFailureAfterCommitAndStopsTheSession() = runTest {
        val (provider) = provider(FixtureNeuralSpeechRuntimeOptions(failAfterChunks = 2))
        val audio = RecordingAudioOutput()
        val commits = Commits()

        val error = refusal { provider.run(request(), runContext(audio, commits)) }

        assertEquals(IndeRunErrorClass.Internal, error.errorClass)
        assertEquals("fixture synthesis failed", error.message)
        assertEquals(1, commits.count)
        assertEquals(4800, audio.sessions.single().writtenFrames)
        assertEquals(1, audio.sessions.single().stops)
    }

    @Test
    fun stopsTheSessionWhenCancelledWhileTheAudioDrains() = runTest {
        val (provider) = provider()
        val audio = RecordingAudioOutput(holdDrain = true)
        val commits = Commits()
        val context = ProviderStreamContext(
            runId = "run_1",
            hostServices = host(audio),
            cancellation = StreamCancellationToken(),
            commitHandler = commits.handler,
        )
        val events = mutableListOf<ProviderStreamEvent>()

        val job = launch { provider.stream(request(), context).collect { events += it } }
        withTimeout(5_000) { audio.drainStarted.await() }
        job.cancel()
        job.join()

        assertEquals(1, commits.count)
        assertTrue(audio.sessions.single().stops > 0)
        assertEquals(emptyList<ProviderStreamEvent>(), events)
    }

    // --- artifact ----------------------------------------------------------------------------

    @Test
    fun writesAWavArtifactWithoutAnAudioOutput() = runTest {
        val (provider) = provider()
        val commits = Commits()

        val result = provider.run(request(delivery = OutputDelivery.Artifact), runContext(audioOutput = null, commits = commits))

        assertEquals(TaskOutputType.ARTIFACT, result.output.type)
        assertEquals("audio/wav", result.output.artifact?.mediaType)
        assertEquals(44L + 2 * 13200, result.output.artifact?.byteLength)
        assertEquals("v_de", result.output.speech?.voice?.id)
    }

    @Test
    fun refusesPlaybackWithoutAnAudioOutputBeforeCommit() = runTest {
        val (provider, runtime) = provider()
        val commits = Commits()

        val error = refusal { provider.run(request(), runContext(audioOutput = null, commits = commits)) }

        assertEquals(IndeRunErrorClass.CapabilityMismatch, error.errorClass)
        assertEquals("audio_output_unavailable", error.details?.get("code"))
        assertEquals(0, commits.count)
        assertEquals(0, runtime.synthesized.size)
    }

    // --- review fixes ------------------------------------------------------------------------

    @Test
    fun countsFirstAudioMsFromTheInstantBeforeOpenWasCalled() = runTest {
        val (provider) = provider()
        // The recording session reports 0 once written to.
        val audio = RecordingAudioOutput()
        val slowOpen = object : AudioOutputService {
            override suspend fun open(format: AudioOutputFormat): AudioOutputSession {
                // Wall time: the provider reads System.nanoTime(), which virtual time does not move.
                Thread.sleep(200)
                return audio.open(format)
            }
        }

        val result = provider.run(request(), runContext(slowOpen))

        // The session measures from the start of its own open(), so the slow open is counted once,
        // by the session; counting from when open() returned would add it a second time.
        val firstAudioMs = result.output.playback?.timing?.firstAudioMs!!
        assertTrue("firstAudioMs $firstAudioMs counts the open twice", firstAudioMs < 200)
    }

    @Test
    fun stopsTheSessionWhenCancelledWhileAWriteIsBlocked() = runTest {
        val (provider) = provider()
        val audio = BlockingWriteAudioOutput()

        val job = launch { provider.run(request(), runContext(audio)) }
        withTimeout(5_000) { audio.writeBlocked.await() }
        job.cancel()
        try {
            withTimeout(1_000) { job.join() }
        } finally {
            audio.release()
        }

        assertTrue(job.isCancelled)
        assertTrue(audio.stops > 0)
    }

    @Test
    fun copiesEachChunkWhenBufferingAnArtifactSoARuntimeMayReuseItsBuffer() = runTest {
        val provider = NeuralSpeechProvider(pkg, ScratchBufferRuntime())
        val artifacts = SpyArtifacts(ArtifactSink.standalone())

        val result = provider.run(request(delivery = OutputDelivery.Artifact), runContext().copy(artifacts = artifacts))

        assertEquals(TaskOutputType.ARTIFACT, result.output.type)
        assertEquals(listOf(1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3), wavSamples(artifacts.written.single()))
    }

    @Test
    fun boundsAnArtifactWithTimeoutMsUpToFinish() = runTest {
        val (provider) = provider(timeoutMs = 500)
        val commits = Commits()
        // Synthesis is instant, well inside the budget even on a loaded runner; writing the WAV takes
        // the run past its deadline, in wall time the provider's System.nanoTime() sees.
        val artifacts = SpyArtifacts(ArtifactStore().attempt(commits.handler)) { Thread.sleep(600) }
        val context = RunContext("run_1", host(), artifacts = artifacts, commitHandler = commits.handler)

        val error = refusal { provider.run(request(delivery = OutputDelivery.Artifact), context) }

        assertEquals(IndeRunErrorClass.Timeout, error.errorClass)
        assertEquals(0, artifacts.finishCalls)
        assertEquals(1, artifacts.aborts)
        assertEquals(0, commits.count)
    }
}
