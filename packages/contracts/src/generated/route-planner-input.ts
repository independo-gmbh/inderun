/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

/**
 * Pure data input contract for deterministic shared-core Mode-1 route planning.
 */
export type RoutePlannerInput = {
    /**
     * Hard routing constraints evaluated before provider selection.
     */
    constraints: Constraints;
    /**
     * Soft route ordering preferences applied after hard filtering.
     */
    preferences: Preferences;
    /**
     * Static descriptors plus dynamic capability snapshots for planning.
     */
    providers: Provider[];
    /**
     * Minimal task descriptor for provider task matching.
     */
    task: Task;
    [property: string]: unknown;
}

/**
 * Hard routing constraints evaluated before provider selection.
 */
export type Constraints = {
    /**
     * Cloud execution constraint.
     */
    cloud?: Cloud;
    /**
     * Current connectivity snapshot used for cloud route planning.
     */
    networkOnline?: boolean;
    /**
     * Privacy requirement or preference for execution placement.
     */
    privacy?: PrivacyEnum;
    [property: string]: unknown;
}

/**
 * Cloud execution constraint.
 */
export type Cloud = "forbidden" | "allowed" | "required";

/**
 * Privacy requirement or preference for execution placement.
 */
export type PrivacyEnum = "local_required" | "local_preferred" | "cloud_allowed" | "cloud_required";

/**
 * Soft route ordering preferences applied after hard filtering.
 */
export type Preferences = {
    /**
     * Primary optimization goal when multiple providers remain eligible.
     */
    optimizeFor?: OptimizeFor;
    [property: string]: unknown;
}

/**
 * Primary optimization goal when multiple providers remain eligible.
 */
export type OptimizeFor = "privacy" | "latency" | "cost" | "balanced";

export type Provider = {
    capabilities: Capabilities;
    descriptor:   Descriptor;
    [property: string]: unknown;
}

export type Capabilities = {
    available: boolean;
    reason?:   string;
    [property: string]: unknown;
}

export type Descriptor = {
    id: string;
    /**
     * Descriptor privacy metadata used to enforce local/cloud routing rules.
     */
    privacy?: PrivacyObject;
    supports: Supports;
    tasks:    string[];
    type:     Type;
    [property: string]: unknown;
}

/**
 * Descriptor privacy metadata used to enforce local/cloud routing rules.
 */
export type PrivacyObject = {
    dataLeavesDevice: boolean;
    regions?:         string[];
    [property: string]: unknown;
}

export type Supports = {
    run: boolean;
    [property: string]: unknown;
}

export type Type = "local" | "edge" | "cloud";

/**
 * Minimal task descriptor for provider task matching.
 */
export type Task = {
    kind: string;
    [property: string]: unknown;
}
