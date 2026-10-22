package app.independo.inderun.sdk

import app.independo.inderun.contracts.Cloud
import app.independo.inderun.contracts.ExecutionProvenance
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.Generation
import app.independo.inderun.contracts.Message
import app.independo.inderun.contracts.MessageRole
import app.independo.inderun.contracts.OptimizeFor
import app.independo.inderun.contracts.Outcome
import app.independo.inderun.contracts.Privacy
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.StreamEvent
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestConstraints
import app.independo.inderun.contracts.TaskRequestPreferences
import app.independo.inderun.contracts.TaskRequestTask
import app.independo.inderun.contracts.TaskRequestTelemetry
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TaskResultUsage
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ModelProfiles
import app.independo.inderun.core.createInternal
import app.independo.inderun.sdk.generated.IndeRunApi
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.transformWhile
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

// The primary text API: `generateText` and `streamText`.
//
// Both are translation only. Each call compiles to exactly one canonical `TaskRequest`
// (`TextGenerationOptions.toTaskRequest()`) and calls `run` or `stream` on the `IndeRunApi`
// it extends, so routing, fallback, cancellation, credentials, telemetry, and error
// normalization are the engine's and identical to a direct call. Mirrors the Web SDK's
// `facade/text.ts`; the shared vectors in `contracts/fixtures/facade/` hold the two to the
// same translation. See `docs/architecture/api-layering.md`.

/**
 * Compact execution policy. Reuses the canonical enum values, so moving a call between the
 * facade and `run` never changes what a constraint means.
 */
data class TextExecutionOptions(
    val privacy: Privacy? = null,
    val cloud: Cloud? = null,
    val timeoutMs: Long? = null,
    val optimizeFor: OptimizeFor? = null,
)

/**
 * Options for [generateText] and [streamText]: exactly one of [prompt] or [messages].
 *
 * @property model Model profile to route within, as configured on the engine. Null or `"auto"`
 *   routes across every registered target. Never a vendor model id.
 * @property system Instructions sent as a leading `system` message.
 * @property authContextRef Secure-storage slot for provider credentials. Never a raw secret.
 * @property requestId Fixes the run id, for correlation.
 */
data class TextGenerationOptions(
    val prompt: String? = null,
    val messages: List<Message>? = null,
    val model: String? = null,
    val system: String? = null,
    val maxOutputTokens: Long? = null,
    val temperature: Double? = null,
    val topP: Double? = null,
    val stop: List<String>? = null,
    val seed: Long? = null,
    val execution: TextExecutionOptions? = null,
    val authContextRef: String? = null,
    val telemetry: TaskRequestTelemetry? = null,
    val requestId: String? = null,
) {
    init {
        require((prompt == null) != (messages == null)) { "Provide exactly one of prompt or messages." }
    }

    /** The canonical [TaskRequest] a facade call compiles to. */
    fun toTaskRequest(): TaskRequest {
        val conversation = messages ?: prompt?.takeIf { system != null }?.let {
            listOf(Message(role = MessageRole.USER, content = it))
        }
        val hasGeneration = maxOutputTokens != null ||
            temperature != null ||
            topP != null ||
            stop != null ||
            seed != null
        val hasConstraints = execution?.let { it.privacy != null || it.cloud != null || it.timeoutMs != null } == true

        return TaskRequest(
            schemaVersion = SchemaVersion.V1_0,
            task = TaskRequestTask(),
            prompt = prompt.takeIf { system == null && messages == null },
            messages = system?.let { listOf(Message(role = MessageRole.SYSTEM, content = it)) + conversation.orEmpty() }
                ?: conversation,
            modelProfile = model.takeUnless { it == ModelProfiles.AUTO },
            generation = if (hasGeneration) {
                Generation(
                    maxOutputTokens = maxOutputTokens,
                    seed = seed,
                    stop = stop,
                    temperature = temperature,
                    topP = topP,
                )
            } else {
                null
            },
            constraints = if (hasConstraints) {
                TaskRequestConstraints(
                    cloud = execution?.cloud,
                    privacy = execution?.privacy,
                    timeoutMs = execution?.timeoutMs,
                )
            } else {
                null
            },
            preferences = execution?.optimizeFor?.let { TaskRequestPreferences(optimizeFor = it) },
            telemetry = telemetry,
            authContextRef = authContextRef,
            requestId = requestId,
        )
    }
}

/** What [generateText] returns; [taskResult] is the canonical result. */
data class GeneratedText(
    val text: String,
    val finishReason: FinishReason,
    val usage: TaskResultUsage?,
    val runId: String,
    val provenance: ExecutionProvenance?,
    val taskResult: TaskResult,
)

/**
 * How a [streamText] run ended, when it did not fail. [text] is the partial text and
 * [finishReason] is [FinishReason.CANCELLED] when the run was cancelled.
 */
data class StreamedText(
    val text: String,
    val finishReason: FinishReason?,
    val usage: TaskResultUsage?,
    val runId: String,
    val provenance: ExecutionProvenance?,
)

/**
 * Thrown by [TextStream.textStream] when the provider replaces text it already delivered with
 * text that does not extend it, which an append-only text view cannot represent.
 */
class TextStreamRetractedException(val runId: String) : IllegalStateException("Run $runId replaced text it had already delivered; collect fullStream to render retractions.")

/**
 * What [streamText] returns. The run is read once, in the scope given to [streamText], into a
 * replay buffer, so [textStream], [fullStream], and [result] can each be consumed in any order
 * without stalling the others.
 */
class TextStream internal constructor(
    val runId: String,
    private val replay: EventReplay,
    /**
     * The run's ending: completes on completion or cancellation, fails with the run's
     * [IndeRunException] on failure.
     */
    val result: Deferred<StreamedText>,
    private val onCancel: (String?) -> Unit,
) {
    /** The canonical [StreamEvent] sequence, terminal included. Each collection replays from the start. */
    val fullStream: Flow<StreamEvent> get() = replay.flow()

    /**
     * Text increments, in order. Completes when the run completes or is cancelled; throws the
     * run's [IndeRunException] when it fails, and [TextStreamRetractedException] when delivered
     * text is replaced.
     */
    val textStream: Flow<String> get() = flow {
        var text = ""
        replay.flow().collect { event ->
            when (event.type) {
                "content_delta" -> {
                    val delta = event.payload?.text.orEmpty()
                    text += delta
                    emit(delta)
                }
                "content_snapshot" -> {
                    val snapshot = event.payload?.text.orEmpty()
                    if (!snapshot.startsWith(text)) throw TextStreamRetractedException(runId)
                    val suffix = snapshot.substring(text.length)
                    text = snapshot
                    if (suffix.isNotEmpty()) emit(suffix)
                }
                "terminal" -> settle(event, runId)
            }
        }
    }

    /** Cancels the run. Idempotent. */
    fun cancel(reason: String? = null) = onCancel(reason)
}

/**
 * Generates text in one call: `run` over the canonical request. Not cancellable, for the same
 * reason `run` is not; use [streamText] when cancellation matters.
 *
 * @throws IndeRunException exactly as `run` does.
 */
suspend fun IndeRunApi.generateText(options: TextGenerationOptions): GeneratedText {
    val result = run(options.toTaskRequest())
    return GeneratedText(
        // A text run always produces text; `TaskOutput.text` is optional only because the same
        // type describes playback and artifacts (ADR 016).
        text = result.output.text.orEmpty(),
        finishReason = result.finishReason,
        usage = result.usage,
        runId = result.runId,
        provenance = result.provenance,
        taskResult = result,
    )
}

/**
 * Streams text: `stream` over the canonical request. The run starts immediately and is read in
 * [scope]; cancelling [scope] stops reading it, so use a scope that outlives the consumers.
 *
 * @throws IndeRunException exactly as `stream` does: validation and routing refusals, before
 *   there is a run.
 */
suspend fun IndeRunApi.streamText(options: TextGenerationOptions, scope: CoroutineScope): TextStream {
    val run = stream(options.toTaskRequest())
    val runId = run.handle.runId
    val replay = EventReplay()
    val result = CompletableDeferred<StreamedText>()
    scope.launch {
        try {
            // The terminal event is the last one a run delivers, so it settles everything; a
            // source that stays open after it (a bridge subscription, say) must not hold the
            // result back.
            run.events.transformWhile { event ->
                emit(event)
                event.type != "terminal"
            }.collect { replay.push(it) }
            replay.finish(null)
        } catch (cancelled: CancellationException) {
            replay.finish(cancelled)
            result.completeExceptionally(cancelled)
            throw cancelled
        } catch (error: Throwable) {
            // Already reported through both channels. Rethrowing would fail this child and,
            // in an ordinary scope, reach the uncaught-exception handler even when the caller
            // awaits `result`.
            replay.finish(error)
            result.completeExceptionally(error)
            return@launch
        }
        val terminal = replay.terminal()
        if (terminal == null) {
            result.completeExceptionally(createInternal("Run $runId ended without a terminal event.", runId = runId))
        } else {
            runCatching { settle(terminal, runId) }
                .onSuccess { result.complete(it) }
                .onFailure { result.completeExceptionally(it) }
        }
    }
    return TextStream(runId, replay, result) { reason -> run.cancel(reason) }
}

private fun settle(terminal: StreamEvent, runId: String): StreamedText {
    val payload = terminal.payload
    val usage = payload?.usage?.let {
        TaskResultUsage(inputTokens = it.inputTokens, outputTokens = it.outputTokens, totalTokens = it.totalTokens)
    }
    return when (payload?.outcome) {
        Outcome.Completed -> StreamedText(
            text = (payload.finalText ?: payload.output?.text).orEmpty(),
            finishReason = payload.finishReason,
            usage = usage,
            runId = runId,
            provenance = payload.provenance,
        )
        Outcome.Cancelled -> StreamedText(
            text = (payload.partialText ?: payload.output?.text).orEmpty(),
            finishReason = FinishReason.CANCELLED,
            usage = null,
            runId = runId,
            provenance = payload.provenance,
        )
        Outcome.Error -> {
            val error = payload.error
            throw IndeRunException(
                errorClass = error?.errorClass ?: app.independo.inderun.contracts.IndeRunErrorClass.Internal,
                message = error?.message ?: "Run $runId failed.",
                runId = runId,
                providerId = error?.providerId,
                retryable = error?.retryable,
                retryAfterMs = error?.retryAfterMs,
                details = error?.details,
                provenance = payload.provenance,
            )
        }
        null -> throw createInternal("Run $runId ended with a malformed terminal event.", runId = runId)
    }
}

/** Holds every event read from the single-use run so any number of collectors can replay it. */
internal class EventReplay {
    private val lock = Any()
    private val events = mutableListOf<StreamEvent>()
    private var finished = false
    private var failure: Throwable? = null
    private val version = MutableStateFlow(0L)

    fun push(event: StreamEvent) {
        synchronized(lock) { events += event }
        version.update { it + 1 }
    }

    fun finish(error: Throwable?) {
        synchronized(lock) {
            failure = error
            finished = true
        }
        version.update { it + 1 }
    }

    fun terminal(): StreamEvent? = synchronized(lock) { events.firstOrNull { it.type == "terminal" } }

    fun flow(): Flow<StreamEvent> = flow {
        var index = 0
        while (true) {
            val seen = version.value
            // Only the unread tail: copying the whole history on every wake-up is quadratic.
            val (unread, done, error) = synchronized(lock) {
                Triple(events.subList(index, events.size).toList(), finished, failure)
            }
            unread.forEach { emit(it) }
            index += unread.size
            if (done) {
                error?.let { throw it }
                return@flow
            }
            version.first { it != seen }
        }
    }
}
