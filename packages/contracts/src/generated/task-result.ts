/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

/**
 * Milestone-1 text-to-text result contract for Mode 1 run().
 */
export type TaskResult = {
    /**
     * Normalized reason why generation ended.
     */
    finishReason: FinishReason;
    /**
     * Normalized text output returned by the selected provider.
     */
    output: Output;
    /**
     * Opaque run identifier assigned or normalized by the engine.
     */
    runId: string;
    /**
     * Contract schema version used to interpret the result payload.
     */
    schemaVersion: "1.0";
    /**
     * Required minimal telemetry summary attached to every result.
     */
    telemetry: Telemetry;
    /**
     * Optional normalized token usage information reported by the provider.
     */
    usage?: Usage;
    [property: string]: unknown;
}

/**
 * Normalized reason why generation ended.
 */
export type FinishReason = "stop" | "length" | "cancelled" | "error";

/**
 * Normalized text output returned by the selected provider.
 */
export type Output = {
    /**
     * Generated text returned to the caller.
     */
    text: string;
    /**
     * Output payload kind for milestone text-to-text execution.
     */
    type: "text";
    [property: string]: unknown;
}

/**
 * Required minimal telemetry summary attached to every result.
 */
export type Telemetry = {
    /**
     * Optional normalized error class if the result represents a provider-level error outcome.
     */
    errorClass?: ErrorClass;
    /**
     * Identifier of the provider selected for the completed attempt.
     */
    providerUsed: string;
    /**
     * Total measured execution duration in milliseconds.
     */
    totalMs: number;
    [property: string]: unknown;
}

/**
 * Optional normalized error class if the result represents a provider-level error outcome.
 */
export type ErrorClass = "CapabilityMismatch" | "Offline" | "AuthError" | "RateLimited" | "Timeout" | "Unavailable" | "Internal";

/**
 * Optional normalized token usage information reported by the provider.
 */
export type Usage = {
    /**
     * Number of input tokens consumed, when reported by the provider.
     */
    inputTokens?: number;
    /**
     * Number of output tokens generated, when reported by the provider.
     */
    outputTokens?: number;
    /**
     * Total token count, when reported by the provider.
     */
    totalTokens?: number;
    [property: string]: unknown;
}
