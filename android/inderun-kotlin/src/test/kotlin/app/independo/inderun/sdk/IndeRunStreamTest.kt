package app.independo.inderun.sdk

import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.Outcome
import app.independo.inderun.contracts.Output
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.StreamEvent
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestTask
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TaskResultTelemetry
import app.independo.inderun.contracts.TaskResultUsage
import app.independo.inderun.core.ClockService
import app.independo.inderun.core.ConnectivityService
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderAdapter
import app.independo.inderun.core.ProviderDescriptor
import app.independo.inderun.core.ProviderDynamicCapabilities
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.core.ProviderStreamContext
import app.independo.inderun.core.ProviderStreamEvent
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.SecureStorageService
import app.independo.inderun.core.StreamingProviderAdapter
import app.independo.inderun.core.createRateLimited
import app.independo.inderun.core.createUnavailable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Mirrors the Web SDK's engine.stream suite and the Swift StreamOrchestrationTests
 * scenario for scenario, so the three orchestrators are held to the same
 * behavior rather than to three independently invented ones.
 */
@RunWith(RobolectricTestRunner::class)
class IndeRunStreamTest {
    private fun hostServices(): HostServices = HostServices(
        connectivity = object : ConnectivityService {
            override fun isOnline(): Boolean = true
        },
        secureStorage = object : SecureStorageService {
            override fun get(authContextRef: String): String? = null
            override fun put(authContextRef: String, value: String) = Unit
            override fun remove(authContextRef: String) = Unit
        },
        clock = object : ClockService {
            private var current = 0L
            override fun elapsedRealtimeMillis(): Long = current.also { current += 10 }
        },
    )

    private fun request(requestId: String? = null) = TaskRequest(
        schemaVersion = SchemaVersion.V1_0,
        requestId = requestId,
        prompt = "Hello",
        task = TaskRequestTask(),
    )

    @Test
    fun deliversContentDeltasAndACompletedTerminal() = runTest {
        val registry = ProviderRegistry().apply {
            register(
                FakeStreamProvider(
                    "p1",
                    listOf(
                        Step(ProviderStreamEvent.Delta("Hello")),
                        Step(ProviderStreamEvent.Delta(" world")),
                        Step(ProviderStreamEvent.Done("Hello world")),
                    ),
                ),
            )
        }

        val run = IndeRun(registry, hostServices()).stream(request())
        val events = run.events.toList()

        assertEquals(listOf("content_delta", "content_delta", "terminal"), events.map { it.type })
        assertEquals(listOf(0L, 1L, 2L), events.map { it.sequence })
        assertEquals(Outcome.Completed, events.last().payload?.outcome)
        assertEquals("Hello world", events.last().payload?.finalText)
    }

    @Test
    fun carriesFinishReasonAndUsageOnCompletion() = runTest {
        val registry = ProviderRegistry().apply {
            register(
                FakeStreamProvider(
                    "p1",
                    listOf(
                        Step(ProviderStreamEvent.Delta("trunc")),
                        Step(
                            ProviderStreamEvent.Done(
                                finalText = "trunc",
                                finishReason = FinishReason.LENGTH,
                                usage = TaskResultUsage(inputTokens = 2, outputTokens = 1, totalTokens = 3),
                            ),
                        ),
                    ),
                ),
            )
        }

        val events = IndeRun(registry, hostServices()).stream(request()).events.toList()

        assertEquals(FinishReason.LENGTH, events.last().payload?.finishReason)
        assertEquals(3L, events.last().payload?.usage?.totalTokens)
    }

    @Test
    fun omitsFinishReasonWhenTheProviderDoesNotReportOne() = runTest {
        val registry = ProviderRegistry().apply {
            register(FakeStreamProvider("p1", listOf(Step(ProviderStreamEvent.Done("ok")))))
        }

        val events = IndeRun(registry, hostServices()).stream(request()).events.toList()

        assertNull(events.last().payload?.finishReason)
    }

    @Test
    fun refusesWhenNoRegisteredProviderCanStream() = runTest {
        val registry = ProviderRegistry().apply { register(FakeRunOnlyProvider("p_run_only")) }

        val error = runCatching { IndeRun(registry, hostServices()).stream(request("req-42")) }
            .exceptionOrNull() as? IndeRunException

        assertEquals(IndeRunErrorClass.CapabilityMismatch, error?.errorClass)
        assertEquals("req-42", error?.runId)
    }

    @Test
    fun refusesAProviderThatDeclaresStreamingWithoutImplementingIt() = runTest {
        val registry = ProviderRegistry().apply {
            register(FakeRunOnlyProvider("p_declared", declaresStreaming = true))
        }

        val error = runCatching { IndeRun(registry, hostServices()).stream(request()) }
            .exceptionOrNull() as? IndeRunException

        assertEquals(IndeRunErrorClass.CapabilityMismatch, error?.errorClass)
    }

    @Test
    fun fallsBackBeforeAnyContentIsDelivered() = runTest {
        val failing = FakeStreamProvider("p1_failing", emptyList(), throwAfterScript = createUnavailable("boom"))
        val healthy = FakeStreamProvider(
            "p2_healthy",
            listOf(Step(ProviderStreamEvent.Delta("second")), Step(ProviderStreamEvent.Done("second"))),
        )
        val registry = ProviderRegistry().apply {
            register(failing)
            register(healthy)
        }

        val events = IndeRun(registry, hostServices()).stream(request()).events.toList()

        assertEquals(Outcome.Completed, events.last().payload?.outcome)
        assertEquals("second", events.last().payload?.finalText)
        assertEquals(1, failing.callCount)
        assertEquals(1, healthy.callCount)
    }

    @Test
    fun doesNotFallBackOnceContentHasBeenDelivered() = runTest {
        val committing = FakeStreamProvider(
            "p1_committing",
            listOf(Step(ProviderStreamEvent.Delta("partial"))),
            throwAfterScript = createUnavailable("died mid-stream"),
        )
        val other = FakeStreamProvider("p2_other", listOf(Step(ProviderStreamEvent.Done("unused"))))
        val registry = ProviderRegistry().apply {
            register(committing)
            register(other)
        }

        val events = IndeRun(registry, hostServices()).stream(request()).events.toList()

        assertEquals(listOf("content_delta", "terminal"), events.map { it.type })
        assertEquals(Outcome.Error, events.last().payload?.outcome)
        assertEquals("partial", events.last().payload?.partialText)
        // Splicing a second provider's text onto the first provider's partial
        // output would be undetectable to the caller, so it must not happen.
        assertEquals(0, other.callCount)
    }

    @Test
    fun producesExactlyOneCancelledTerminalAndStopsDeltas() = runTest {
        val registry = ProviderRegistry().apply {
            register(
                FakeStreamProvider(
                    "p1",
                    listOf(
                        Step(ProviderStreamEvent.Delta("one")),
                        Step(ProviderStreamEvent.Delta("two"), delayMs = 50),
                        Step(ProviderStreamEvent.Done("one two")),
                    ),
                ),
            )
        }

        val run = IndeRun(registry, hostServices()).stream(request())
        val events = mutableListOf<StreamEvent>()
        run.events.collect { event ->
            events += event
            if (event.type == "content_delta") {
                run.cancel("user stopped")
                // Repeated and concurrent cancels must stay idempotent.
                run.cancel("ignored")
            }
        }

        assertEquals(1, events.count { it.type == "terminal" })
        assertEquals(Outcome.Cancelled, events.last().payload?.outcome)
        assertEquals("one", events.last().payload?.partialText)
        assertEquals("user stopped", events.last().payload?.reason)
    }

    @Test
    fun cancellationBeforeTheFirstAttemptForeclosesEveryProvider() = runTest {
        val provider = FakeStreamProvider("p1", listOf(Step(ProviderStreamEvent.Done("never"))))
        val registry = ProviderRegistry().apply { register(provider) }

        val run = IndeRun(registry, hostServices()).stream(request())
        run.cancel("immediate")
        val events = run.events.toList()

        assertEquals(Outcome.Cancelled, events.last().payload?.outcome)
        assertEquals("", events.last().payload?.partialText)
        assertEquals(0, provider.callCount)
    }

    @Test
    fun reportsAnErrorWhenEveryProviderFailsBeforeCommitting() = runTest {
        val registry = ProviderRegistry().apply {
            register(FakeStreamProvider("p1", emptyList(), throwAfterScript = createUnavailable("boom")))
            register(FakeStreamProvider("p2", emptyList(), throwAfterScript = createUnavailable("boom")))
        }

        val events = IndeRun(registry, hostServices()).stream(request()).events.toList()

        assertEquals(1, events.size)
        assertEquals(Outcome.Error, events.last().payload?.outcome)
        assertEquals(IndeRunErrorClass.Unavailable, events.last().payload?.error?.errorClass)
    }

    @Test
    fun treatsAStreamThatEndsWithoutATerminalEventAsAProviderFault() = runTest {
        val registry = ProviderRegistry().apply {
            register(FakeStreamProvider("p1", listOf(Step(ProviderStreamEvent.Delta("a")))))
        }

        val events = IndeRun(registry, hostServices()).stream(request()).events.toList()

        assertEquals(Outcome.Error, events.last().payload?.outcome)
        assertEquals("a", events.last().payload?.partialText)
    }

    @Test
    fun aProviderReportedFailureEventBehavesLikeAThrow() = runTest {
        val registry = ProviderRegistry().apply {
            register(
                FakeStreamProvider(
                    "p1",
                    listOf(Step(ProviderStreamEvent.Failure(createRateLimited("slow down")))),
                ),
            )
            register(FakeStreamProvider("p2", listOf(Step(ProviderStreamEvent.Done("recovered")))))
        }

        val events = IndeRun(registry, hostServices()).stream(request()).events.toList()

        assertEquals(Outcome.Completed, events.last().payload?.outcome)
        assertEquals("recovered", events.last().payload?.finalText)
    }

    @Test
    fun runAndStreamMayResolveToDifferentProviderChains() = runTest {
        val registry = ProviderRegistry().apply {
            register(FakeRunOnlyProvider("a_run_only"))
            register(FakeStreamProvider("b_streaming", listOf(Step(ProviderStreamEvent.Done("streamed")))))
        }
        val indeRun = IndeRun(registry, hostServices())

        assertEquals("a_run_only", indeRun.run(request()).telemetry.providerUsed)
        assertEquals("b_streaming", indeRun.stream(request()).handle.providerId)
    }

    @Test
    fun eventsAreSingleUse() = runTest {
        val registry = ProviderRegistry().apply {
            register(FakeStreamProvider("p1", listOf(Step(ProviderStreamEvent.Done("once")))))
        }

        val run = IndeRun(registry, hostServices()).stream(request())
        run.events.toList()

        assertTrue(runCatching { run.events.toList() }.exceptionOrNull() is IllegalStateException)
    }
}

private data class Step(val event: ProviderStreamEvent, val delayMs: Long = 0)

private class FakeStreamProvider(
    private val id: String,
    private val script: List<Step>,
    private val throwAfterScript: Throwable? = null,
) : StreamingProviderAdapter {
    var callCount: Int = 0
        private set

    override fun describe(): ProviderDescriptor = streamDescriptor(id, streaming = true)

    override suspend fun capabilities(host: HostServices) = ProviderDynamicCapabilities(available = true)

    override suspend fun run(request: TaskRequest, context: RunContext): TaskResult = TaskResult(
        schemaVersion = SchemaVersion.V1_0,
        runId = context.runId,
        output = Output(text = "unused"),
        finishReason = FinishReason.STOP,
        telemetry = TaskResultTelemetry(providerUsed = id, totalMs = 0.0),
    )

    override fun stream(request: TaskRequest, context: ProviderStreamContext): Flow<ProviderStreamEvent> {
        callCount += 1
        return flow {
            for (step in script) {
                if (step.delayMs > 0) delay(step.delayMs)
                if (context.cancellation.isCancelled) return@flow
                emit(step.event)
            }
            throwAfterScript?.let { throw it }
        }
    }
}

private class FakeRunOnlyProvider(
    private val id: String,
    private val declaresStreaming: Boolean = false,
) : ProviderAdapter {
    override fun describe(): ProviderDescriptor = streamDescriptor(id, streaming = declaresStreaming)

    override suspend fun capabilities(host: HostServices) = ProviderDynamicCapabilities(available = true)

    override suspend fun run(request: TaskRequest, context: RunContext): TaskResult = TaskResult(
        schemaVersion = SchemaVersion.V1_0,
        runId = context.runId,
        output = Output(text = "ran"),
        finishReason = FinishReason.STOP,
        telemetry = TaskResultTelemetry(providerUsed = id, totalMs = 0.0),
    )
}

private fun streamDescriptor(id: String, streaming: Boolean) = ProviderDescriptor(
    id = id,
    type = ProviderDescriptor.ProviderType.local,
    transport = ProviderDescriptor.TransportType.in_process,
    supports = ProviderDescriptor.SupportsCapabilities(
        run = true,
        streaming = streaming,
        realtime = false,
        tools = false,
        reasoningEvents = false,
        structuredOutput = false,
        multimodal = false,
    ),
    cancel = ProviderDescriptor.CancelSemantics.soft,
    tasks = listOf("text_to_text"),
)
