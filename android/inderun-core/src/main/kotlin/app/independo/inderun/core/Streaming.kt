package app.independo.inderun.core

import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.ProviderVoice
import app.independo.inderun.contracts.StreamEvent
import app.independo.inderun.contracts.StreamRunHandle
import app.independo.inderun.contracts.TaskOutput
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskResultUsage
import kotlinx.coroutines.flow.Flow

/**
 * Caller-driven cancellation signal for a Mode 2 stream, shared between the
 * engine and the provider adapter driving the run.
 *
 * This is the Kotlin analogue of the Web SDK's `AbortSignal`. Coroutine
 * cancellation alone is not sufficient: a provider is free to produce its events
 * from a scope it created itself, which does not inherit cancellation from the
 * collector. An explicit token gives every provider a signal it can observe
 * regardless of how it is structured, and gives the three SDKs one shared
 * cancellation model.
 *
 * Cancelling is idempotent: only the first call records a reason and fires the
 * registered handlers.
 */
class StreamCancellationToken {
    private val lock = Any()
    private var cancelled = false
    private var cancellationReason: String? = null
    private var handlers = mutableListOf<() -> Unit>()

    /** Whether cancellation has been requested. */
    val isCancelled: Boolean
        get() = synchronized(lock) { cancelled }

    /** The reason passed to the first `cancel` call, when one was given. */
    val reason: String?
        get() = synchronized(lock) { cancellationReason }

    /**
     * Registers a handler invoked on cancellation. Fires immediately, on the
     * calling thread, if cancellation already happened.
     */
    fun onCancel(handler: () -> Unit) {
        val fireNow = synchronized(lock) {
            if (cancelled) {
                true
            } else {
                handlers.add(handler)
                false
            }
        }
        if (fireNow) handler()
    }

    /** Requests cancellation. Subsequent calls are no-ops. */
    fun cancel(reason: String? = null) {
        val pending = synchronized(lock) {
            if (cancelled) return
            cancelled = true
            cancellationReason = reason
            val snapshot = handlers
            handlers = mutableListOf()
            snapshot
        }
        pending.forEach { it() }
    }
}

/**
 * Execution context passed to [StreamingProviderAdapter.stream]. Extends
 * [RunContext] with the caller-driven cancellation signal; the engine owns the
 * token, so providers never construct their own.
 */
data class ProviderStreamContext(
    val runId: String,
    val hostServices: HostServices,
    /**
     * Signals caller-driven cancellation of this stream. Providers declaring
     * `cancel = hard` should tear down their connection immediately; `soft`
     * providers may stop relaying without interrupting underlying work; `none`
     * providers may ignore it. The engine enforces the caller-visible
     * cancellation guarantee regardless of what the provider does.
     */
    val cancellation: StreamCancellationToken,
    /**
     * The voice the route plan bound this provider to for a speech task; see
     * [RunContext.voice]. The engine has re-checked it against the request's privacy policy
     * immediately before the attempt.
     */
    val voice: ProviderVoice? = null,
    /**
     * What [commit] does. The engine supplies it; a context built outside an engine -- a
     * provider's own unit test -- always commits.
     */
    private val commitHandler: () -> Boolean = { true },
) {
    /**
     * Commits the run to this provider. Call it immediately before the attempt's first
     * externally observable effect -- for managed playback, no later than the first moment
     * sound may reach the user. After commit, a failure ends the run with a terminal error
     * instead of falling back to another provider, because a second provider would repeat
     * what the user may already have heard.
     *
     * Returns `false` when the run can no longer commit (it was cancelled or has already
     * ended) and when this attempt is over, e.g. a late callback after the engine fell back to
     * another provider; the provider must then not start the effect and should end the attempt.
     * Idempotent: calling it again after a successful commit returns `true`.
     *
     * Text streams need not call it: they commit implicitly on their first content event,
     * and every stream commits at the latest when it hands over its result.
     */
    fun commit(): Boolean = commitHandler()
}

/**
 * A raw, provider-shaped streaming event.
 *
 * Intentionally distinct from the canonical [StreamEvent] contract: providers
 * emit provider-shaped deltas here and the engine's Event Gate normalizes them,
 * keeping provider-specific mechanics from leaking through the public API.
 */
sealed interface ProviderStreamEvent {
    /** An incremental text increment since the previous content event. */
    data class Delta(val text: String) : ProviderStreamEvent

    /** The full cumulative text produced so far, replacing what came before. */
    data class Snapshot(val text: String) : ProviderStreamEvent

    /**
     * Terminal success. [finishReason] and [usage] are reported when the provider
     * exposes them; [reportedModel] is the model id the provider's backend named for
     * this run, never one inferred from configuration.
     */
    data class Done(
        val finalText: String,
        val finishReason: FinishReason? = null,
        val usage: TaskResultUsage? = null,
        val reportedModel: String? = null,
    ) : ProviderStreamEvent

    /**
     * The run's normalized output, for tasks whose output is not streamed text (playback
     * completion, a media artifact). Ends the stream like [Done]; handing it over commits the
     * run if the provider has not already called [ProviderStreamContext.commit]. Text
     * providers keep using [Done].
     */
    data class Result(
        val output: TaskOutput,
        val finishReason: FinishReason? = null,
        val reportedModel: String? = null,
    ) : ProviderStreamEvent

    /** Terminal failure. Handled identically to the flow throwing. */
    data class Failure(val error: Throwable) : ProviderStreamEvent
}

/**
 * A [ProviderAdapter] that additionally supports Mode 2 streaming.
 *
 * Streaming support is a separate interface rather than an optional member so
 * that "declares streaming and actually implements it" is a type check the
 * router can make before planning a route, mirroring the Web SDK's
 * `typeof provider.stream === "function"` test.
 */
interface StreamingProviderAdapter : ProviderAdapter {
    /**
     * Executes a Mode 2 (streaming) task. The returned flow must end with a
     * [ProviderStreamEvent.Done], [ProviderStreamEvent.Result] or
     * [ProviderStreamEvent.Failure] event, or by throwing; ending without one is
     * treated as a provider fault.
     */
    fun stream(request: TaskRequest, context: ProviderStreamContext): Flow<ProviderStreamEvent>
}

/**
 * What `IndeRun.stream()` returns: the run's identity, its canonical event
 * sequence, and a cancel hook.
 *
 * [events] terminates in exactly one terminal [StreamEvent]. It is cold but
 * single-use — the run is driven once, not restarted per collector — and
 * collecting it a second time throws rather than silently re-running the
 * provider. [cancel] is idempotent: repeated or concurrent calls produce exactly
 * one `cancelled` terminal outcome.
 */
class StreamRun(
    val handle: StreamRunHandle,
    val events: Flow<StreamEvent>,
    private val onCancel: (String?) -> Unit,
) {
    /** Cancels the run. Idempotent. */
    fun cancel(reason: String? = null) = onCancel(reason)
}
