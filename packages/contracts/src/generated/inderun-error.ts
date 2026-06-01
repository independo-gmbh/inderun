/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

/**
 * Normalized Milestone-1 error contract.
 */
export type IndeRunError = {
    /**
     * Optional structured diagnostic details. It must not contain raw secrets.
     */
    details?: { [key: string]: unknown };
    /**
     * Normalized error taxonomy class.
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
 * Normalized error taxonomy class.
 */
export type ErrorClass = "CapabilityMismatch" | "Offline" | "AuthError" | "RateLimited" | "Timeout" | "Unavailable" | "Internal";
