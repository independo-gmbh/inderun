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
     * Required execution target for the route plan.
     */
    executionTarget: ExecutionTarget;
    /**
     * Current connectivity snapshot used for cloud route planning.
     */
    networkOnline: boolean;
    [property: string]: unknown;
}

/**
 * Required execution target for the route plan.
 */
export type ExecutionTarget = "on_device" | "cloud";

/**
 * Soft route ordering preferences applied after hard filtering.
 */
export type Preferences = {
    /**
     * Provider IDs ordered from highest to lowest preference.
     */
    preferredProviderIds: string[];
    [property: string]: unknown;
}

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
    id:       string;
    supports: Supports;
    tasks:    string[];
    type:     Type;
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
