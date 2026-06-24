/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

/**
 * Deterministic shared-core Mode-1 route planning result.
 */
export type RoutePlan = {
    /**
     * Eligible candidates in deterministic order.
     */
    candidates: Candidate[];
    /**
     * Human-readable selection or failure explanation suitable for telemetry/debugging.
     */
    explanation: Explanation;
    /**
     * Normalized routing failure class when no provider is selected.
     */
    failureCode?: FailureCode;
    /**
     * Fallback provider IDs ordered after the primary selection.
     */
    fallbackProviderIds: string[];
    /**
     * Providers filtered out during planning together with machine-readable reasons.
     */
    rejectedProviders: RejectedProvider[];
    /**
     * Chosen primary provider ID, if any.
     */
    selectedProviderId?: string;
    [property: string]: unknown;
}

export type Candidate = {
    order:      number;
    providerId: string;
    [property: string]: unknown;
}

/**
 * Human-readable selection or failure explanation suitable for telemetry/debugging.
 */
export type Explanation = {
    selectedProviderId?: string;
    summary:             string;
    [property: string]: unknown;
}

/**
 * Normalized routing failure class when no provider is selected.
 */
export type FailureCode = "capability_mismatch" | "offline" | "unavailable";

export type RejectedProvider = {
    providerId: string;
    reasons:    Reason[];
    [property: string]: unknown;
}

export type Reason = {
    code:    Code;
    message: string;
    [property: string]: unknown;
}

export type Code = "task_not_supported" | "run_not_supported" | "privacy_constraint" | "cloud_constraint" | "offline" | "capability_unavailable";
