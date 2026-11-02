package app.independo.inderun.sdk

import app.independo.inderun.contracts.CancelSemantics
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.OutputDelivery
import app.independo.inderun.contracts.OutputDeliveryRequest
import app.independo.inderun.contracts.PreparationStatus
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
import app.independo.inderun.contracts.SpeechInput
import app.independo.inderun.contracts.TaskInputKind
import app.independo.inderun.contracts.TaskKind
import app.independo.inderun.contracts.TaskOutput
import app.independo.inderun.contracts.TaskOutputType
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestConstraints
import app.independo.inderun.contracts.TaskRequestTask
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TaskResultTelemetry
import app.independo.inderun.core.ClockService
import app.independo.inderun.core.ConnectivityService
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.PreparableProviderAdapter
import app.independo.inderun.core.PreparationProgress
import app.independo.inderun.core.ProviderPrepareContext
import app.independo.inderun.core.ProviderRegistrationOptions
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.SecureStorageService
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class PrepareTest {
    private class FakeProvider(
        private val id: String,
        private var readiness: ProviderReadiness,
        private val kind: String = "text_to_text",
        private val work: suspend () -> Unit = {},
    ) : PreparableProviderAdapter {
        var prepares = 0
        var runs = 0

        override fun describe() = ProviderDescriptor(
            id = id,
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
            cancel = CancelSemantics.None,
            tasks = listOf(kind),
            taskCapabilities = listOf(
                ProviderTaskCapability(
                    kind = kind,
                    inputs = listOf(TaskInputKind.Text),
                    interaction = ProviderTaskInteraction(prepare = true, run = true, stream = false),
                    cancel = CancelSemantics.None,
                    outputs = listOf(ProviderTaskOutput(delivery = OutputDelivery.Inline), ProviderTaskOutput(delivery = OutputDelivery.Playback)),
                ),
            ),
        )

        override suspend fun capabilities(host: HostServices) = ProviderDynamicCapabilities(
            available = readiness == ProviderReadiness.Ready || readiness == ProviderReadiness.Cold,
            taskCapabilities = listOf(ProviderTaskAvailability(kind = kind, readiness = readiness)),
        )

        override suspend fun run(request: TaskRequest, context: RunContext): TaskResult {
            runs += 1
            return TaskResult(
                finishReason = FinishReason.STOP,
                output = TaskOutput(type = TaskOutputType.TEXT, text = "ok"),
                runId = context.runId,
                schemaVersion = request.schemaVersion,
                telemetry = TaskResultTelemetry(providerUsed = id, totalMs = 0.0),
            )
        }

        override fun prepare(context: ProviderPrepareContext): Flow<PreparationProgress> = flow {
            prepares += 1
            emit(PreparationProgress(0.5))
            work()
            readiness = ProviderReadiness.Ready
        }
    }

    private val host = HostServices(
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
    )

    private val text = TaskRequest(
        prompt = "Hi",
        schemaVersion = SchemaVersion.V1_0,
        task = TaskRequestTask(kind = TaskKind.TEXT_TO_TEXT),
    )

    private fun engine(vararg providers: FakeProvider, autoDownload: Boolean = false): IndeRun {
        val registry = ProviderRegistry()
        providers.forEach { registry.register(it, ProviderRegistrationOptions(autoDownload)) }
        return IndeRun(registry, host)
    }

    @Test
    fun runsOnceOnTheFirstCallWhenTheApplicationNeverCalledIt() = runTest {
        val provider = FakeProvider("a", ProviderReadiness.Preparing)
        val inderun = engine(provider)

        inderun.run(text)
        inderun.run(text)

        assertEquals(1, provider.prepares)
        assertEquals(2, provider.runs)
    }

    @Test
    fun isSkippedOnTheFirstCallAfterAnExplicitPrepare() = runTest {
        val provider = FakeProvider("a", ProviderReadiness.Cold)
        val inderun = engine(provider)

        inderun.prepare(this).result.await()
        inderun.run(text)

        assertEquals(1, provider.prepares)
    }

    @Test
    fun sharesOnePreparationBetweenConcurrentFirstCalls() = runTest {
        val gate = CompletableDeferred<Unit>()
        val provider = FakeProvider("a", ProviderReadiness.Preparing) { gate.await() }
        val inderun = engine(provider)

        val first = async { inderun.run(text) }
        val second = async { inderun.run(text) }
        testScheduler.runCurrent()
        gate.complete(Unit)
        first.await()
        second.await()

        assertEquals(1, provider.prepares)
    }

    @Test
    fun leavesAColdProviderAloneOnTheFirstCall() = runTest {
        val provider = FakeProvider("a", ProviderReadiness.Cold)

        engine(provider).run(text)

        assertEquals(0, provider.prepares)
        assertEquals(1, provider.runs)
    }

    @Test
    fun neverStartsADownloadWithoutPermission() = runTest {
        val provider = FakeProvider("a", ProviderReadiness.NotPrepared)
        val inderun = engine(provider)

        val result = inderun.prepare(this).result.await()

        assertEquals(0, provider.prepares)
        assertEquals(PreparationStatus.Skipped, result.items.single().status)
    }

    @Test
    fun downloadsOnTheFirstCallUnderAutoDownloadThenRuns() = runTest {
        val provider = FakeProvider("a", ProviderReadiness.NotPrepared)

        engine(provider, autoDownload = true).run(text)

        assertEquals(1, provider.prepares)
        assertEquals(1, provider.runs)
    }

    @Test
    fun letsOneCallAllowADownload() = runTest {
        val provider = FakeProvider("a", ProviderReadiness.NotPrepared)

        engine(provider).prepare(this, PrepareRequest(allowDownload = true)).result.await()

        assertEquals(1, provider.prepares)
    }

    @Test
    fun givesUpWaitingAtTheBoundSoRoutingCanFallBack() = runTest {
        val stuck = FakeProvider("a", ProviderReadiness.NotPrepared) { awaitCancellation() }
        val fallback = FakeProvider("b", ProviderReadiness.Ready)

        val result = engine(stuck, fallback, autoDownload = true)
            .run(text.copy(constraints = TaskRequestConstraints(timeoutMs = 10)))

        assertEquals("b", result.telemetry.providerUsed)
    }

    @Test
    fun keepsGoingWhenOneProviderFails() = runTest {
        val broken = FakeProvider("a", ProviderReadiness.Cold) { error("no") }
        val healthy = FakeProvider("b", ProviderReadiness.Cold)

        val result = engine(broken, healthy).prepare(this).result.await()

        assertEquals(
            setOf(PreparationStatus.Failed, PreparationStatus.Prepared),
            result.items.map { it.status }.toSet(),
        )
    }

    @Test
    fun cancelsWithOneTerminalOutcome() = runTest {
        val provider = FakeProvider("a", ProviderReadiness.Preparing) { awaitCancellation() }
        val preparation = engine(provider).prepare(this)
        testScheduler.runCurrent()

        preparation.cancel("left the screen")
        preparation.cancel("again")

        assertEquals(true, preparation.result.await().cancelled)
    }

    @Test
    fun sharesAFailureWithACallerThatWaitedForTheSamePreparation() = runTest {
        val gate = CompletableDeferred<Unit>()
        val provider = FakeProvider("a", ProviderReadiness.Cold) {
            gate.await()
            error("no")
        }
        val inderun = engine(provider)

        val first = inderun.prepare(this)
        val second = inderun.prepare(this)
        testScheduler.runCurrent()
        gate.complete(Unit)

        assertEquals(PreparationStatus.Failed, first.result.await().items.single().status)
        assertEquals(PreparationStatus.Failed, second.result.await().items.single().status)
        assertEquals(1, provider.prepares)
    }

    @Test
    fun aSkippedPreparationDoesNotCountAsDoneForAFirstRunThatMayDownload() = runTest {
        val provider = FakeProvider("a", ProviderReadiness.NotPrepared)
        val inderun = engine(provider, autoDownload = true)

        inderun.prepare(this, PrepareRequest(allowDownload = false)).result.await()
        inderun.run(text)

        assertEquals(1, provider.prepares)
        assertEquals(1, provider.runs)
    }

    @Test
    fun aFailedPreparationDoesNotCountAsDone() = runTest {
        var attempts = 0
        val provider = FakeProvider("a", ProviderReadiness.Preparing) {
            attempts += 1
            check(attempts > 1)
        }
        val inderun = engine(provider)

        inderun.prepare(this).result.await()
        inderun.run(text)

        assertEquals(2, provider.prepares)
    }

    @Test
    fun aBlockedFirstRunOfOneTaskDoesNotHoldAnotherTask() = runTest {
        val speech = FakeProvider("speech", ProviderReadiness.Preparing, kind = "text_to_speech") { awaitCancellation() }
        val writer = FakeProvider("writer", ProviderReadiness.Preparing)
        val inderun = engine(speech, writer)
        val blocked = async {
            runCatching {
                inderun.run(
                    TaskRequest(
                        schemaVersion = SchemaVersion.V1_0,
                        speech = SpeechInput(locale = "de-DE", text = "Hallo"),
                        delivery = OutputDeliveryRequest(mode = OutputDelivery.Playback),
                        task = TaskRequestTask(kind = TaskKind.TEXT_TO_SPEECH),
                        constraints = TaskRequestConstraints(timeoutMs = 60_000),
                    ),
                )
            }
        }
        testScheduler.runCurrent()

        val result = inderun.run(text)

        assertEquals("writer", result.telemetry.providerUsed)
        blocked.cancel()
    }
}
