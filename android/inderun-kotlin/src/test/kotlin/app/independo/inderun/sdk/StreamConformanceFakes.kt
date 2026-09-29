package app.independo.inderun.sdk

import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.Output
import app.independo.inderun.contracts.PrivacyEnum
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestConstraints
import app.independo.inderun.contracts.TaskRequestTask
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TaskResultTelemetry
import app.independo.inderun.contracts.TelemetryEvent
import app.independo.inderun.core.ClockService
import app.independo.inderun.core.ConnectivityService
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.ProviderAdapter
import app.independo.inderun.core.ProviderDescriptor
import app.independo.inderun.core.ProviderDynamicCapabilities
import app.independo.inderun.core.ProviderStreamContext
import app.independo.inderun.core.ProviderStreamEvent
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.SecureStorageService
import app.independo.inderun.core.StreamingProviderAdapter
import app.independo.inderun.core.TelemetryService
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow

/**
 * Fakes shared by the Android Mode 2 suites: [IndeRunStreamConformanceTest], which
 * drives the cross-SDK catalog, and [IndeRunStreamTest], which keeps the ML Kit
 * end-to-end coverage that is specific to this platform.
 */

internal fun conformanceHostServices(online: Boolean = true): HostServices = HostServices(
    connectivity = object : ConnectivityService {
        override fun isOnline(): Boolean = online
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

internal fun conformanceRequest(
    requestId: String? = null,
    privacy: PrivacyEnum? = null,
) = TaskRequest(
    schemaVersion = SchemaVersion.V1_0,
    requestId = requestId,
    prompt = "Hello",
    task = TaskRequestTask(),
    constraints = privacy?.let { TaskRequestConstraints(privacy = it) },
)

internal class RecordingTelemetryService : TelemetryService {
    val events = mutableListOf<TelemetryEvent>()

    override fun emit(event: TelemetryEvent) {
        events += event
    }
}

internal sealed interface Step {
    data class Emit(val event: ProviderStreamEvent, val delayMs: Long = 0) : Step

    /**
     * Blocks until the run is cancelled, then records that the provider observed
     * its own cancellation. Preferred over a timed delay: it removes the race, and
     * it matches the Web and Swift fakes.
     */
    data object WaitForCancellation : Step
}

internal class FakeStreamProvider(
    private val id: String,
    private val script: List<Step> = emptyList(),
    private val throwAfterScript: Throwable? = null,
    private val throwImmediately: Throwable? = null,
    private val type: ProviderDescriptor.ProviderType = ProviderDescriptor.ProviderType.local,
    private val streamingAvailable: Boolean? = null,
    private val streamingUnavailableReason: String? = null,
    /** Completed once the flow is actually collected, so a test can cancel mid-attempt without racing. */
    private val entered: CompletableDeferred<Unit>? = null,
) : StreamingProviderAdapter {
    var callCount: Int = 0
        private set

    @Volatile
    var wasInterrupted: Boolean = false
        private set

    override fun describe(): ProviderDescriptor = streamDescriptor(id, streaming = true, type = type)

    override suspend fun capabilities(host: HostServices) = ProviderDynamicCapabilities(
        available = true,
        streamingAvailable = streamingAvailable,
        streamingUnavailableReason = streamingUnavailableReason,
    )

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
            entered?.complete(Unit)
            throwImmediately?.let { throw it }
            for (step in script) {
                when (step) {
                    is Step.WaitForCancellation -> {
                        try {
                            awaitCancellation()
                        } catch (cancellation: CancellationException) {
                            wasInterrupted = true
                            throw cancellation
                        }
                    }

                    is Step.Emit -> {
                        if (step.delayMs > 0) delay(step.delayMs)
                        if (context.cancellation.isCancelled) {
                            wasInterrupted = true
                            return@flow
                        }
                        emit(step.event)
                    }
                }
            }
            throwAfterScript?.let { throw it }
        }
    }
}

internal class FakeRunOnlyProvider(
    private val id: String,
    private val declaresStreaming: Boolean = false,
    private val type: ProviderDescriptor.ProviderType = ProviderDescriptor.ProviderType.local,
) : ProviderAdapter {
    var callCount: Int = 0
        private set

    override fun describe(): ProviderDescriptor = streamDescriptor(id, streaming = declaresStreaming, type = type)

    override suspend fun capabilities(host: HostServices) = ProviderDynamicCapabilities(available = true)

    override suspend fun run(request: TaskRequest, context: RunContext): TaskResult {
        callCount += 1
        return TaskResult(
            schemaVersion = SchemaVersion.V1_0,
            runId = context.runId,
            output = Output(text = "ran"),
            finishReason = FinishReason.STOP,
            telemetry = TaskResultTelemetry(providerUsed = id, totalMs = 0.0),
        )
    }
}

internal fun streamDescriptor(
    id: String,
    streaming: Boolean,
    type: ProviderDescriptor.ProviderType = ProviderDescriptor.ProviderType.local,
) = ProviderDescriptor(
    id = id,
    type = type,
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
