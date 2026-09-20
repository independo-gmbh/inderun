package app.independo.inderun.core

import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.Outcome
import app.independo.inderun.contracts.Payload
import app.independo.inderun.contracts.PayloadError
import app.independo.inderun.contracts.PayloadTelemetry
import app.independo.inderun.contracts.PayloadUsage
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.StreamEvent
import app.independo.inderun.contracts.StreamTerminalOutcome
import app.independo.inderun.contracts.StreamTerminalOutcomeError
import app.independo.inderun.contracts.StreamTerminalOutcomeTelemetry
import app.independo.inderun.contracts.StreamTerminalOutcomeUsage

/**
 * Per-run gatekeeper for Mode 2 streaming. Enforces the two structural
 * guarantees the streaming orchestrator depends on: exactly one terminal
 * outcome is ever produced for a run, and no event is admitted after it.
 *
 * Unlike the Web SDK's gate, which relies on JavaScript's run-to-completion
 * semantics, this one is explicitly synchronized: a provider's producing
 * coroutine and a caller's `cancel()` genuinely run on different threads here,
 * and first-writer-wins termination is only meaningful if the check-and-set is
 * atomic.
 */
class EventGate(private val runId: String) {
    private val lock = Any()
    private var sequence = 0L
    private var terminated = false
    private var terminalOutcome: StreamTerminalOutcome? = null

    /**
     * Admits a non-terminal event, assigning the next monotonic sequence number.
     * Returns `null` — suppressing the event — once the run has terminated.
     */
    fun admit(timestamp: Double, type: String, payload: Payload?): StreamEvent? = synchronized(lock) {
        if (terminated) return null
        StreamEvent(
            payload = payload,
            runId = runId,
            schemaVersion = SchemaVersion.V1_0,
            sequence = sequence++,
            timestamp = timestamp,
            type = type,
        )
    }

    /**
     * Terminates the run. First writer wins: only the first call produces a
     * terminal event and records the outcome. Every later call — a duplicate
     * provider `Done`, a late error after cancellation, concurrent `cancel()`
     * calls — is a silent no-op, which is what makes repeated cancellation safe.
     */
    fun terminate(outcome: StreamTerminalOutcome, timestamp: Double): StreamEvent? = synchronized(lock) {
        if (terminated) return null
        terminated = true
        terminalOutcome = outcome
        StreamEvent(
            payload = outcome.toPayload(),
            runId = runId,
            schemaVersion = SchemaVersion.V1_0,
            sequence = sequence++,
            timestamp = timestamp,
            type = "terminal",
        )
    }

    val isTerminated: Boolean
        get() = synchronized(lock) { terminated }

    val outcome: StreamTerminalOutcome?
        get() = synchronized(lock) { terminalOutcome }
}

/** Payload for a `content_delta` / `content_snapshot` event. */
fun contentPayload(text: String): Payload = Payload(text = text)

/**
 * The terminal event's payload is required by contract to stay structurally
 * identical to the standalone [StreamTerminalOutcome], so it is copied field for
 * field rather than reconstructed at each call site.
 */
fun StreamTerminalOutcome.toPayload(): Payload = Payload(
    finalText = finalText,
    finishReason = finishReason,
    outcome = outcome,
    runId = runId,
    schemaVersion = schemaVersion,
    telemetry = telemetry?.let { PayloadTelemetry(providerUsed = it.providerUsed, totalMs = it.totalMs) },
    usage = usage?.let {
        PayloadUsage(
            inputTokens = it.inputTokens,
            outputTokens = it.outputTokens,
            totalTokens = it.totalTokens,
        )
    },
    error = error?.let {
        PayloadError(
            details = it.details,
            errorClass = it.errorClass,
            message = it.message,
            providerId = it.providerId,
            retryable = it.retryable,
            retryAfterMs = it.retryAfterMs,
            schemaVersion = it.schemaVersion,
        )
    },
    partialText = partialText,
    reason = reason,
)

/** The `completed` outcome: the provider delivered every event it was going to. */
fun completedOutcome(
    runId: String,
    finalText: String,
    finishReason: FinishReason?,
    usage: StreamTerminalOutcomeUsage?,
    telemetry: StreamTerminalOutcomeTelemetry,
): StreamTerminalOutcome = StreamTerminalOutcome(
    finalText = finalText,
    finishReason = finishReason,
    outcome = Outcome.Completed,
    runId = runId,
    schemaVersion = SchemaVersion.V1_0,
    telemetry = telemetry,
    usage = usage,
)

/** The `error` outcome: validation, routing, or every attempted provider failing. */
fun errorOutcome(
    runId: String,
    error: StreamTerminalOutcomeError,
    partialText: String,
): StreamTerminalOutcome = StreamTerminalOutcome(
    outcome = Outcome.Error,
    runId = runId,
    schemaVersion = SchemaVersion.V1_0,
    error = error,
    partialText = partialText,
)

/** The `cancelled` outcome, carrying whatever content was delivered first. */
fun cancelledOutcome(
    runId: String,
    partialText: String,
    reason: String?,
): StreamTerminalOutcome = StreamTerminalOutcome(
    outcome = Outcome.Cancelled,
    runId = runId,
    schemaVersion = SchemaVersion.V1_0,
    partialText = partialText,
    reason = reason,
)
