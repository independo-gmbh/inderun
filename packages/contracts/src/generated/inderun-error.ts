/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

/**
 * The error shape thrown by run() (wrapped in an IndeRunException) when execution fails —
 * via validation, routing (no eligible provider), or every attempted provider failing.
 * Never returned as part of a successful TaskResult.
 */
export type IndeRunError = {
    /**
     * Optional structured diagnostic details. It must not contain raw secrets.
     */
    details?: { [key: string]: unknown };
    /**
     * Normalized error taxonomy, shared with TaskResult.telemetry.errorClass:
     * CapabilityMismatch (request needs something no eligible provider supports),
     * Offline/Unavailable (provider unreachable or not ready), AuthError (credential/auth
     * failure), RateLimited (provider throttled the request), Timeout (provider exceeded its
     * execution budget), Internal (unexpected engine-side failure).
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
     * Opaque run identifier associated with the failed execution, if available.
     */
    runId?: string;
    /**
     * Contract schema version used to interpret the error payload.
     */
    schemaVersion: "1.0";
    [property: string]: unknown;
}

/**
 * Normalized error taxonomy, shared with TaskResult.telemetry.errorClass:
 * CapabilityMismatch (request needs something no eligible provider supports),
 * Offline/Unavailable (provider unreachable or not ready), AuthError (credential/auth
 * failure), RateLimited (provider throttled the request), Timeout (provider exceeded its
 * execution budget), Internal (unexpected engine-side failure).
 */
export type ErrorClass = "CapabilityMismatch" | "Offline" | "AuthError" | "RateLimited" | "Timeout" | "Unavailable" | "Internal";
