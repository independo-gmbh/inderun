package app.independo.inderun.sdk

import app.independo.inderun.contracts.CancelSemantics
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.OutputDelivery
import app.independo.inderun.contracts.OutputDeliveryRequest
import app.independo.inderun.contracts.Privacy
import app.independo.inderun.contracts.ProviderDescriptor
import app.independo.inderun.contracts.ProviderDynamicCapabilities
import app.independo.inderun.contracts.ProviderSupports
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
import app.independo.inderun.contracts.TelemetryEvent
import app.independo.inderun.core.ClockService
import app.independo.inderun.core.ConnectivityService
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.ProviderAdapter
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
    privacy: Privacy? = null,
) = TaskRequest(
    schemaVersion = SchemaVersion.V1_0,
    requestId = requestId,
    prompt = "Hello",
    task = TaskRequestTask(),
    constraints = privacy?.let { TaskRequestConstraints(privacy = it) },
)

/**
 * The request the `non_text_outputs` conformance cases stream: speech 'Hallo' in de-AT, played
 * back on the device.
 */
internal fun speechConformanceRequest(delivery: OutputDeliveryRequest = OutputDeliveryRequest(mode = OutputDelivery.Playback)) = TaskRequest(
    schemaVersion = SchemaVersion.V1_0,
    task = TaskRequestTask(TaskKind.TEXT_TO_SPEECH),
    speech = SpeechInput(text = "Hallo", locale = "de-AT"),
    delivery = delivery,
    constraints = TaskRequestConstraints(privacy = Privacy.LocalRequired),
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

    /**
     * Calls `context.commit()` and records what it returned. A commit step directly after
     * [WaitForCancellation] runs once the cancellation has been observed, which is how a
     * provider that asks to commit too late is modelled.
     */
    data object Commit : Step

    /**
     * Calls the commit [provider] kept from its own, earlier attempt -- a late callback from an
     * attempt the run has already left -- and records the result as that provider's.
     */
    data class CallKeptCommit(val provider: FakeStreamProvider) : Step
}

internal class FakeStreamProvider(
    private val id: String,
    private val script: List<Step> = emptyList(),
    private val throwAfterScript: Throwable? = null,
    private val throwImmediately: Throwable? = null,
    private val type: ProviderType = ProviderType.Local,
    private val streamingAvailable: Boolean? = null,
    private val streamingUnavailableReason: String? = null,
    /**
     * The task the fake declares. [TaskKind.TEXT_TO_SPEECH] adds a speech capability with
     * playback delivery, so the planner routes speech requests to it.
     */
    private val task: TaskKind = TaskKind.TEXT_TO_TEXT,
) : StreamingProviderAdapter {
    @Volatile
    private var keptContext: ProviderStreamContext? = null

    var callCount: Int = 0
        private set

    @Volatile
    var wasInterrupted: Boolean = false
        private set

    private val commits = mutableListOf<Boolean>()

    /** What each `context.commit()` call returned, in call order. */
    val commitResults: List<Boolean>
        get() = synchronized(commits) { commits.toList() }

    /** Completed once the flow is actually collected, so a test can cancel mid-attempt without racing. */
    val started = CompletableDeferred<Unit>()

    /** Completed when the provider has called `context.commit()` for the first time. */
    val committed = CompletableDeferred<Unit>()

    override fun describe(): ProviderDescriptor = streamDescriptor(id, streaming = true, type = type, task = task)

    /** Calls the `context.commit()` of this provider's latest attempt and records the result. */
    fun callKeptCommit() {
        keptContext?.let { commit(it) }
    }

    private fun commit(context: ProviderStreamContext) {
        val result = context.commit()
        synchronized(commits) { commits += result }
        committed.complete(Unit)
    }

    override suspend fun capabilities(host: HostServices) = ProviderDynamicCapabilities(
        available = true,
        streamingAvailable = streamingAvailable,
        streamingUnavailableReason = streamingUnavailableReason,
    )

    override suspend fun run(request: TaskRequest, context: RunContext): TaskResult = TaskResult(
        schemaVersion = SchemaVersion.V1_0,
        runId = context.runId,
        output = TaskOutput(type = TaskOutputType.TEXT, text = "unused"),
        finishReason = FinishReason.STOP,
        telemetry = TaskResultTelemetry(providerUsed = id, totalMs = 0.0),
    )

    override fun stream(request: TaskRequest, context: ProviderStreamContext): Flow<ProviderStreamEvent> {
        callCount += 1
        keptContext = context
        return flow {
            started.complete(Unit)
            throwImmediately?.let { throw it }
            for ((index, step) in script.withIndex()) {
                when (step) {
                    is Step.WaitForCancellation -> {
                        try {
                            awaitCancellation()
                        } catch (cancellation: CancellationException) {
                            wasInterrupted = true
                            script.drop(index + 1).filterIsInstance<Step.Commit>().forEach { commit(context) }
                            throw cancellation
                        }
                    }

                    is Step.Commit -> commit(context)

                    is Step.CallKeptCommit -> step.provider.callKeptCommit()

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
    private val type: ProviderType = ProviderType.Local,
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
            output = TaskOutput(type = TaskOutputType.TEXT, text = "ran"),
            finishReason = FinishReason.STOP,
            telemetry = TaskResultTelemetry(providerUsed = id, totalMs = 0.0),
        )
    }
}

internal fun streamDescriptor(
    id: String,
    streaming: Boolean,
    type: ProviderType = ProviderType.Local,
    task: TaskKind = TaskKind.TEXT_TO_TEXT,
) = ProviderDescriptor(
    id = id,
    type = type,
    transport = ProviderTransport.InProcess,
    supports = ProviderSupports(
        run = true,
        streaming = streaming,
        realtime = false,
        tools = false,
        reasoningEvents = false,
        structuredOutput = false,
        multimodal = false,
    ),
    cancel = CancelSemantics.Soft,
    tasks = listOf(task.rawValue),
    taskCapabilities = if (task == TaskKind.TEXT_TO_SPEECH) {
        listOf(
            ProviderTaskCapability(
                kind = task.rawValue,
                inputs = listOf(TaskInputKind.Text),
                interaction = ProviderTaskInteraction(run = true, stream = streaming),
                cancel = CancelSemantics.Soft,
                outputs = listOf(ProviderTaskOutput(delivery = OutputDelivery.Playback)),
                locales = listOf("de-AT"),
            ),
        )
    } else {
        null
    },
)
