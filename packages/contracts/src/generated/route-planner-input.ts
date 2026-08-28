/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

/**
 * Pure data input contract for deterministic shared-core route planning.
 */
export type RoutePlannerInput = {
    /**
     * Hard routing constraints evaluated before provider selection.
     */
    constraints: Constraints;
    /**
     * Interaction mode the caller is requesting. Absent means 'run' (Mode 1), so planner inputs
     * produced before this field existed keep their exact Mode-1 semantics. The mode filters
     * eligible providers; it never changes candidate ordering.
     */
    interactionMode?: InteractionMode;
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
 * Interaction mode the caller is requesting. Absent means 'run' (Mode 1), so planner inputs
 * produced before this field existed keep their exact Mode-1 semantics. The mode filters
 * eligible providers; it never changes candidate ordering.
 */
export type InteractionMode = "run" | "stream";

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
    /**
     * Whether cancellation is honored right now in this host environment. Absent inherits the
     * static descriptor.cancel value (any value other than 'none' means available).
     */
    cancellationAvailable?: boolean;
    reason?:                string;
    /**
     * Whether the provider can stream right now in this host environment. Absent inherits the
     * static descriptor.supports.streaming value.
     */
    streamingAvailable?: boolean;
    /**
     * Human-readable explanation used when streamingAvailable is false. Absent lets the planner
     * synthesize a default message.
     */
    streamingUnavailableReason?: string;
    [property: string]: unknown;
}

export type Descriptor = {
    /**
     * Cancellation guarantee the provider offers. Carried for route explanations and telemetry;
     * the planner does not filter on it.
     */
    cancel?: Cancel;
    id:      string;
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
 * Cancellation guarantee the provider offers. Carried for route explanations and telemetry;
 * the planner does not filter on it.
 */
export type Cancel = "hard" | "soft" | "none";

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
    /**
     * Whether the provider statically declares Mode-2 streaming. Absent is treated as false: a
     * descriptor that predates this field cannot be assumed to stream.
     */
    streaming?: boolean;
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
