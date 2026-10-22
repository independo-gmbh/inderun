/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

/**
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
