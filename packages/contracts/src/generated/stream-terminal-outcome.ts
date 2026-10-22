/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

/**
 * How a Mode 2 stream run ended. Completion, error, and cancellation are mutually exclusive
 * terminal outcomes, enforced here as a closed set of three oneOf branches discriminated by
 * 'outcome' (unlike StreamEvent.type, this set is not open-ended: the three-way terminal
 * outcome is a fixed architectural guarantee, not something new outcome kinds get added to;
 * the payload of each branch may grow additively). Exactly one StreamTerminalOutcome is
 * produced per run, and no further StreamEvent is delivered after it (see
 * docs/architecture/architecture.md, 'Cancellation And Fallback'). This shape is also
 * embedded by value as the payload of the terminal StreamEvent (stream-event.schema.json)
 * so it can additionally be exposed standalone, e.g. as a completion future/promise a
 * stream handle resolves independently of consuming the full event sequence; the two copies
 * must stay structurally identical. Note on additionalProperties: per this repo's
 * forward-compatible convention every branch permits unknown extra fields, so mutual
 * exclusivity is enforced via the required 'outcome' discriminator plus each branch's own
 * required peer field being present (finalText or output / error / partialText or output),
 * not by forbidding a payload from also carrying an unrelated stray field from another
 * branch's vocabulary.
 */
export type StreamTerminalOutcome = {
    /**
     * The full, cumulative text produced by a text run. Equivalent in role to
     * TaskResult.output.text for Mode 1. A text run sets it; a non-text run carries output
     * instead.
     */
    finalText?: string;
    /**
     * How generation ended, mirroring TaskResult.finishReason for Mode 1: 'stop' (natural end),
     * 'length' (hit maxOutputTokens), 'error' (provider reported a non-fatal issue on an
     * otherwise completed run). 'cancelled' is included so this enum stays identical to
     * TaskResult.finishReason, but it is unreachable here: cancellation is its own terminal
     * outcome branch. Optional: providers that do not report a finish reason omit it.
     */
    finishReason?: FinishReason;
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
     * The normalized output of the run, the same shape run() returns in TaskResult.output. Set
     * for every non-text run; a text run may set it alongside finalText. See
     * task-output.schema.json.
     *
     * The normalized output of a cancelled non-text run up to the cancellation point, e.g. how
     * long playback lasted before it was stopped. See task-output.schema.json.
     */
    output?: TaskOutput;
    /**
     * Normalized execution provenance: which target ran, its declared locality, the configured
     * and reported model, and how fallback and routing played out. See
     * execution-provenance.schema.json.
     */
    provenance?: ExecutionProvenance;
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
     * Whatever cumulative text a text run had already delivered before it failed after
     * committing to its provider. Absent when nothing was delivered.
     *
     * Whatever cumulative text a text run had already delivered via
     * content_delta/content_snapshot StreamEvents before the cancellation point. May be empty
     * if cancellation occurred before any content was produced. A non-text run carries output
     * instead.
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
     * Normalized execution provenance: which target ran, its declared locality, the configured
     * and reported model, and how fallback and routing played out. See
     * execution-provenance.schema.json.
     */
    provenance?: ExecutionProvenance;
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
 *
 * Normalized error class of a failed attempt.
 */
export type ErrorClass = "CapabilityMismatch" | "Offline" | "AuthError" | "RateLimited" | "Timeout" | "Unavailable" | "Internal";

/**
 * Normalized execution provenance: which target ran, its declared locality, the configured
 * and reported model, and how fallback and routing played out. See
 * execution-provenance.schema.json.
 *
 * Provider-neutral record of how an execution was carried out: the target the outcome is
 * attributed to, its declared locality, the configured and provider-reported model, every
 * attempt, and why other candidates were rejected. Carried on TaskResult, on every
 * StreamTerminalOutcome branch, and on IndeRunError. It reports what the engine observed
 * and what providers declared or reported; it never infers a model or locality a provider
 * did not state, and it never contains request content, credentials, or provider payloads.
 */
export type ExecutionProvenance = {
    /**
     * How many providers were attempted. 0 when the request failed validation or routing, or
     * was cancelled before any attempt started.
     */
    attemptCount: number;
    /**
     * Every attempted provider, in attempt order, with how its attempt ended.
     */
    attempts: ExecutionProvenanceAttempt[];
    /**
     * The model providerId is bound to, as its descriptor declares it. Absent when the provider
     * cannot name its model or no provider is attributed.
     */
    configuredModel?: string;
    /**
     * Whether more than one provider was attempted (attemptCount > 1).
     */
    fallbackOccurred: boolean;
    /**
     * Where providerId declares it executes: 'on_device' for a local provider, 'edge', or
     * 'cloud'. A declaration by the provider's descriptor, not a measurement. 'unknown' when
     * providerId is absent.
     */
    locality: Locality;
    /**
     * The model profile the request routed within; 'auto' when the request named none.
     */
    modelProfile: string;
    /**
     * The target the outcome is attributed to: the provider that produced the result, the
     * provider a stream had committed to when it ended, or the provider that was running when
     * it was cancelled. Absent when no provider was reached or when every attempted provider
     * failed before one was committed to.
     */
    providerId?: string;
    /**
     * The model identifier the provider reported in its own response. Absent means the provider
     * did not report one; it is never inferred from configuration.
     */
    reportedModel?: string;
    /**
     * Providers the route planner rejected before any attempt, with the normalized RoutePlan
     * reason codes. Codes only: no provider-supplied messages.
     */
    routeRejections: ExecutionProvenanceRouteRejection[];
    /**
     * Contract schema version used to interpret this provenance record.
     */
    schemaVersion: "1.0";
    [property: string]: unknown;
}

export type ExecutionProvenanceAttempt = {
    /**
     * Whether the run committed to this provider during the attempt: its first content was
     * delivered, it signalled the first possible audible effect, or it handed over an artifact.
     * After commit a failure ends the run instead of falling back. Absent means the attempt did
     * not commit.
     */
    committed?: boolean;
    /**
     * Normalized error class of a failed attempt.
     */
    errorClass?: ErrorClass;
    /**
     * 'succeeded' (produced the result or was committed to and completed), 'failed', or
     * 'cancelled'.
     */
    outcome:    AttemptOutcome;
    providerId: string;
    [property: string]: unknown;
}

/**
 * 'succeeded' (produced the result or was committed to and completed), 'failed', or
 * 'cancelled'.
 */
export type AttemptOutcome = "succeeded" | "failed" | "cancelled";

/**
 * Where providerId declares it executes: 'on_device' for a local provider, 'edge', or
 * 'cloud'. A declaration by the provider's descriptor, not a measurement. 'unknown' when
 * providerId is absent.
 */
export type Locality = "on_device" | "edge" | "cloud" | "unknown";

export type ExecutionProvenanceRouteRejection = {
    codes:      Code[];
    providerId: string;
    [property: string]: unknown;
}

export type Code = "task_not_supported" | "run_not_supported" | "streaming_not_supported" | "streaming_unavailable" | "privacy_constraint" | "cloud_constraint" | "offline" | "capability_unavailable" | "not_in_model_profile" | "input_not_supported" | "output_delivery_not_supported" | "output_format_not_supported" | "locale_not_supported" | "voice_not_available";

/**
 * How generation ended, mirroring TaskResult.finishReason for Mode 1: 'stop' (natural end),
 * 'length' (hit maxOutputTokens), 'error' (provider reported a non-fatal issue on an
 * otherwise completed run). 'cancelled' is included so this enum stays identical to
 * TaskResult.finishReason, but it is unreachable here: cancellation is its own terminal
 * outcome branch. Optional: providers that do not report a finish reason omit it.
 */
export type FinishReason = "stop" | "length" | "cancelled" | "error";

export type Outcome = "completed" | "error" | "cancelled";

/**
 * The normalized output of the run, the same shape run() returns in TaskResult.output. Set
 * for every non-text run; a text run may set it alongside finalText. See
 * task-output.schema.json.
 *
 * The normalized output of a run, shared by TaskResult and the completed and cancelled
 * stream terminal outcomes (ADR 016). 'type' describes the content representation, not the
 * task: 'text' carries inline text, 'playback' reports a managed, audible effect that has
 * no retrievable bytes, and 'artifact' references retrievable media (ADR 017). A playback
 * output is never an artifact, and an artifact output never implies that anything was
 * played.
 *
 * The normalized output of a cancelled non-text run up to the cancellation point, e.g. how
 * long playback lasted before it was stopped. See task-output.schema.json.
 */
export type TaskOutput = {
    /**
     * The retrievable media the run produced. Required when type is 'artifact'.
     */
    artifact?: MediaArtifact;
    /**
     * Completion of managed playback. Required when type is 'playback'. Carries no media.
     */
    playback?: PlaybackOutput;
    /**
     * The locale and voice traits a text-to-speech run actually used, so an unmet preference is
     * visible without being an error.
     */
    speech?: SpeechOutput;
    /**
     * The text the run produced. Required when type is 'text'.
     */
    text?: string;
    /**
     * The content representation: 'text', 'playback' or 'artifact'.
     */
    type: TaskOutputType;
    [property: string]: unknown;
}

/**
 * The retrievable media the run produced. Required when type is 'artifact'.
 *
 * A reference to retrievable media a run produced (ADR 017). It carries no bytes and no
 * location: an engine-owned artifact is read through the engine by id, and an
 * application-owned one was written to an application destination. Media-neutral: audio,
 * images and video share this shape and differ only in mediaType.
 */
export type MediaArtifact = {
    /**
     * Size of the media in bytes. Always set for an artifact the engine materialized.
     */
    byteLength?: number;
    /**
     * Duration of time-based media in milliseconds, where the producer knows it.
     */
    durationMs?: number;
    /**
     * Opaque, engine-issued identifier. Never a path, URL or provider identifier.
     */
    id: string;
    /**
     * How long the engine keeps the bytes. 'until_disposed': until the application disposes the
     * artifact or the process ends; the artifact outlives the run that produced it.
     */
    lifetime: "until_disposed";
    /**
     * IANA media type of the bytes, e.g. 'audio/wav'. Encoding parameters ride on the media
     * type (e.g. 'audio/L16;rate=22050').
     */
    mediaType: string;
    /**
     * 'engine': the engine holds the bytes and the application reads them by id until it
     * disposes the artifact. 'application': the bytes were written to the application
     * destination named by destinationRef and the engine holds nothing.
     */
    owner: ArtifactOwner;
    [property: string]: unknown;
}

/**
 * How long the engine keeps the bytes. 'until_disposed': until the application disposes the
 * artifact or the process ends; the artifact outlives the run that produced it.
 */

/**
 * 'engine': the engine holds the bytes and the application reads them by id until it
 * disposes the artifact. 'application': the bytes were written to the application
 * destination named by destinationRef and the engine holds nothing.
 */
export type ArtifactOwner = "engine" | "application";

/**
 * Completion of managed playback. Required when type is 'playback'. Carries no media.
 */
export type PlaybackOutput = {
    /**
     * How long audible playback lasted, in milliseconds. For a cancelled run, how long it
     * played before it was stopped.
     */
    durationMs?: number;
    [property: string]: unknown;
}

/**
 * The locale and voice traits a text-to-speech run actually used, so an unmet preference is
 * visible without being an error.
 */
export type SpeechOutput = {
    /**
     * BCP 47 tag of the locale that was spoken.
     */
    locale: string;
    /**
     * Provider-neutral traits of the voice that spoke. Carries no provider voice identifier.
     */
    voice?: SpeechOutputVoice;
    [property: string]: unknown;
}

/**
 * Provider-neutral traits of the voice that spoke. Carries no provider voice identifier.
 */
export type SpeechOutputVoice = {
    gender?: VoiceGender;
    [property: string]: unknown;
}

/**
 * Perceived gender of a voice, as the platform reports it.
 */
export type VoiceGender = "female" | "male" | "neutral";

/**
 * The content representation: 'text', 'playback' or 'artifact'.
 */
export type TaskOutputType = "text" | "playback" | "artifact";

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
