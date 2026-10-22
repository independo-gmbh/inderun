/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

/**
 * The response payload for a completed run() execution, for every task kind; output.type
 * tells the content representation apart (text, managed playback, retrievable artifact). A
 * full execution failure (validation, routing, or every attempted provider failing) is
 * surfaced by run() throwing an IndeRunError instead of returning a TaskResult;
 * finishReason and telemetry.errorClass are reserved for a provider reporting a non-fatal,
 * degraded outcome on an otherwise-successful result (finishReason 'error' is produced by
 * the Android ML Kit GenAI provider; telemetry.errorClass is not currently set by any
 * provider in this codebase).
 */
export type TaskResult = {
    /**
     * How generation ended: 'stop' (natural end), 'length' (hit maxOutputTokens), or
     * 'cancelled'. 'error' is reserved for a provider reporting a non-fatal issue on an
     * otherwise-returned result — the Android ML Kit GenAI provider produces it when Gemini
     * Nano reports a finish reason that is neither a natural stop nor the token limit. A full
     * execution failure is instead surfaced by run() throwing an IndeRunError.
     */
    finishReason: FinishReason;
    /**
     * The normalized output of the selected provider. See task-output.schema.json.
     */
    output: TaskOutput;
    /**
     * Normalized execution provenance: which target ran, its declared locality, the configured
     * and reported model, and how fallback and routing played out. See
     * execution-provenance.schema.json.
     */
    provenance?: ExecutionProvenance;
    /**
     * A unique, opaque identifier assigned by the engine for this specific execution attempt.
     */
    runId: string;
    /**
     * Contract schema version used to interpret the result payload.
     */
    schemaVersion: "1.0";
    /**
     * Required metadata providing an overview of the execution result and performance metrics.
     */
    telemetry: Telemetry;
    /**
     * Optional metadata regarding the quantity of tokens processed by the provider.
     */
    usage?: Usage;
    [property: string]: unknown;
}

/**
 * How generation ended: 'stop' (natural end), 'length' (hit maxOutputTokens), or
 * 'cancelled'. 'error' is reserved for a provider reporting a non-fatal issue on an
 * otherwise-returned result — the Android ML Kit GenAI provider produces it when Gemini
 * Nano reports a finish reason that is neither a natural stop nor the token limit. A full
 * execution failure is instead surfaced by run() throwing an IndeRunError.
 */
export type FinishReason = "stop" | "length" | "cancelled" | "error";

/**
 * The normalized output of the selected provider. See task-output.schema.json.
 *
 * The normalized output of a run, shared by TaskResult and the completed and cancelled
 * stream terminal outcomes (ADR 016). 'type' describes the content representation, not the
 * task: 'text' carries inline text, 'playback' reports a managed, audible effect that has
 * no retrievable bytes, and 'artifact' references retrievable media (ADR 017). A playback
 * output is never an artifact, and an artifact output never implies that anything was
 * played.
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
     * The request's delivery.destinationRef the bytes were written to. Set exactly when owner
     * is 'application'.
     */
    destinationRef?: string;
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
 * Normalized error class of a failed attempt.
 *
 * Present only if a provider reports a degraded outcome on an otherwise-successful result;
 * no provider in this codebase currently sets this. Distinct from run() throwing — a thrown
 * IndeRunError never produces a TaskResult at all.
 */
export type ErrorClass = "CapabilityMismatch" | "Offline" | "AuthError" | "RateLimited" | "Timeout" | "Unavailable" | "Internal";

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
 * Required metadata providing an overview of the execution result and performance metrics.
 */
export type Telemetry = {
    /**
     * Present only if a provider reports a degraded outcome on an otherwise-successful result;
     * no provider in this codebase currently sets this. Distinct from run() throwing — a thrown
     * IndeRunError never produces a TaskResult at all.
     */
    errorClass?: ErrorClass;
    /**
     * The identifier for the specific provider that handled the request (e.g.,
     * 'openai_compatible_cloud').
     */
    providerUsed: string;
    /**
     * The model identifier the provider reported in its own response, set by the provider when
     * its backend reports one. The engine carries it into provenance.reportedModel; it is never
     * inferred from configuration.
     */
    reportedModel?: string;
    /**
     * Measured execution duration in milliseconds, including route selection and result
     * processing.
     */
    totalMs: number;
    [property: string]: unknown;
}

/**
 * Optional metadata regarding the quantity of tokens processed by the provider.
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
