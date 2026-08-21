/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

/**
 * How a Mode 2 stream run ended. Completion, error, and cancellation are mutually exclusive
 * terminal outcomes, enforced here as a closed set of three oneOf branches discriminated by
 * 'outcome' (unlike StreamEvent.type, this set is not open-ended: the three-way terminal
 * outcome is a fixed architectural guarantee, not something new outcome kinds get added
 * to). Exactly one StreamTerminalOutcome is produced per run, and no further StreamEvent is
 * delivered after it (see docs/architecture/architecture.md, 'Cancellation And Fallback').
 * This shape is also embedded by value as the payload of the terminal StreamEvent
 * (stream-event.schema.json) so it can additionally be exposed standalone, e.g. as a
 * completion future/promise a stream handle resolves independently of consuming the full
 * event sequence; the two copies must stay structurally identical. Note on
 * additionalProperties: per this repo's forward-compatible convention every branch permits
 * unknown extra fields, so mutual exclusivity is enforced via the required 'outcome'
 * discriminator plus each branch's own required peer field (finalText/error/partialText)
 * being present, not by forbidding a payload from also carrying an unrelated stray field
 * from another branch's vocabulary.
 */
export type StreamTerminalOutcome = {
    /**
     * The full, cumulative text produced by the run. Equivalent in role to
     * TaskResult.output.text for Mode 1.
     */
    finalText?: string;
    /**
     * The stream completed normally: every provider-generated event was delivered before this
     * outcome was produced.
     *
     * The stream ended in failure: validation, routing (no eligible provider), or every
     * attempted provider failing.
     *
     * The stream was cancelled. No further StreamEvent is delivered after this outcome, and no
     * further fallback attempt is made, per the engine's cancellation guarantee.
     */
    outcome: Outcome;
    /**
     * The stream run this outcome terminates, matching StreamRunHandle.runId and every
     * StreamEvent.runId for the run.
     */
    runId: string;
    /**
     * Contract schema version used to interpret this outcome payload.
     */
    schemaVersion: "1.0";
    /**
     * Required metadata providing an overview of the execution result and performance metrics.
     * Same shape as TaskResult.telemetry.
     */
    telemetry?: Telemetry;
    /**
     * Optional metadata regarding the quantity of tokens processed by the provider. Same shape
     * as TaskResult.usage.
     */
    usage?: Usage;
    /**
     * The normalized error for this failure. Structurally identical to IndeRunError
     * (contracts/schemas/inderun-error.schema.json), duplicated by value here rather than by
     * $ref, matching this repo's schema convention of no cross-file references. Keep both
     * shapes in sync; a cross-check test asserts a shared fixture validates against both
     * schemas.
     */
    error?: Error;
    /**
     * Whatever cumulative text had already been delivered via content_delta/content_snapshot
     * StreamEvents before the cancellation point. May be empty if cancellation occurred before
     * any content was produced.
     */
    partialText?: string;
    /**
     * Optional human-readable reason the run was cancelled (e.g. caller-initiated abort). Not a
     * machine-taxonomy field; use errorClass on the 'error' outcome branch for failure
     * classification.
     */
    reason?: string;
    [property: string]: unknown;
}

/**
 * The normalized error for this failure. Structurally identical to IndeRunError
 * (contracts/schemas/inderun-error.schema.json), duplicated by value here rather than by
 * $ref, matching this repo's schema convention of no cross-file references. Keep both
 * shapes in sync; a cross-check test asserts a shared fixture validates against both
 * schemas.
 */
export type Error = {
    /**
     * Optional structured diagnostic details. It must not contain raw secrets.
     */
    details?: { [key: string]: unknown };
    /**
     * Normalized error taxonomy, identical to IndeRunError.errorClass: CapabilityMismatch
     * (request needs something no eligible provider supports), Offline/Unavailable (provider
     * unreachable or not ready), AuthError (credential/auth failure), RateLimited (provider
     * throttled the request), Timeout (provider exceeded its execution budget), Internal
     * (unexpected engine-side failure).
     */
    errorClass: ErrorClass;
    /**
     * Human-readable error message suitable for logs and developer diagnostics.
     */
    message: string;
    /**
     * Identifier of the provider associated with the failure, if execution reached a provider.
     */
    providerId?: string;
    /**
     * Whether retrying the same request may succeed.
     */
    retryable?: boolean;
    /**
     * Optional suggested delay before retrying, in milliseconds.
     */
    retryAfterMs?: number;
    /**
     * Contract schema version used to interpret the error payload.
     */
    schemaVersion: "1.0";
    [property: string]: unknown;
}

/**
 * Normalized error taxonomy, identical to IndeRunError.errorClass: CapabilityMismatch
 * (request needs something no eligible provider supports), Offline/Unavailable (provider
 * unreachable or not ready), AuthError (credential/auth failure), RateLimited (provider
 * throttled the request), Timeout (provider exceeded its execution budget), Internal
 * (unexpected engine-side failure).
 */
export type ErrorClass = "CapabilityMismatch" | "Offline" | "AuthError" | "RateLimited" | "Timeout" | "Unavailable" | "Internal";

export type Outcome = "completed" | "error" | "cancelled";

/**
 * Required metadata providing an overview of the execution result and performance metrics.
 * Same shape as TaskResult.telemetry.
 */
export type Telemetry = {
    /**
     * The identifier for the specific provider that handled the request (e.g.,
     * 'openai_compatible_cloud').
     */
    providerUsed: string;
    /**
     * Measured execution duration in milliseconds, including route selection and result
     * processing.
     */
    totalMs: number;
    [property: string]: unknown;
}

/**
 * Optional metadata regarding the quantity of tokens processed by the provider. Same shape
 * as TaskResult.usage.
 */
export type Usage = {
    /**
     * Number of input tokens consumed, as reported by the provider.
     */
    inputTokens?: number;
    /**
     * Number of output tokens generated, as reported by the provider.
     */
    outputTokens?: number;
    /**
     * Aggregated token count for this request, as reported by the provider.
     */
    totalTokens?: number;
    [property: string]: unknown;
}
