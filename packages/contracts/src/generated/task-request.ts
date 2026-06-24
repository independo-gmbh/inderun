/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

/**
 * The standard request payload for initiating a text-to-text execution task within the
 * IndeRun framework.
 */
export type TaskRequest = {
    /**
     * A unique identifier used to retrieve credentials from a secure local storage. Raw
     * sensitive keys (API keys, etc.) should NEVER be placed directly in the request payload.
     */
    authContextRef?: string;
    /**
     * Request-level routing constraints used by the planner.
     */
    constraints?: Constraints;
    /**
     * Optional configuration for fine-tuning how the AI model generates its response.
     */
    generation?: Generation;
    /**
     * A list of interaction messages for multi-turn conversation or chat-style execution.
     */
    messages?: Message[];
    /**
     * Soft routing preferences used for deterministic provider ordering.
     */
    preferences?: Preferences;
    /**
     * A simple, single-turn text prompt used to trigger a response from the AI model.
     */
    prompt?: string;
    /**
     * Optional identifier for tracking or correlating this specific execution attempt.
     */
    requestId?: string;
    /**
     * Contract schema version used to interpret the request payload.
     */
    schemaVersion: "1.0";
    /**
     * A descriptor specifying the type of work to be performed. For text-to-text, the kind must
     * be 'text_to_text'.
     */
    task: Task;
    /**
     * Execution preferences for tracking usage and performance metrics.
     */
    telemetry?: Telemetry;
    [property: string]: unknown;
}

/**
 * Request-level routing constraints used by the planner.
 */
export type Constraints = {
    /**
     * Cloud execution constraint.
     */
    cloud?: Cloud;
    /**
     * Privacy requirement or preference for execution placement.
     */
    privacy?: Privacy;
    /**
     * Optional routing timeout budget in milliseconds.
     */
    timeoutMs?: number;
    [property: string]: unknown;
}

/**
 * Cloud execution constraint.
 */
export type Cloud = "forbidden" | "allowed" | "required";

/**
 * Privacy requirement or preference for execution placement.
 */
export type Privacy = "local_required" | "local_preferred" | "cloud_allowed" | "cloud_required";

/**
 * Optional configuration for fine-tuning how the AI model generates its response.
 */
export type Generation = {
    /**
     * The maximum number of tokens to generate in a single response.
     */
    maxOutputTokens?: number;
    /**
     * A fixed seed for deterministic generation (where supported by the underlying provider).
     */
    seed?: number;
    /**
     * Sequence tokens that should terminate the generation process.
     */
    stop?: string[];
    /**
     * Controls the randomness of the output. Range: 0 (most deterministic) to 2 (highest
     * variance).
     */
    temperature?: number;
    /**
     * Nucleus sampling parameter for controlling diversity vs focus in the output.
     */
    topP?: number;
    [property: string]: unknown;
}

/**
 * An individual message in a conversation.
 */
export type Message = {
    /**
     * The actual text content of the message.
     */
    content: string;
    /**
     * The role of the author (e.g., 'user', 'assistant').
     */
    role: Role;
    [property: string]: unknown;
}

/**
 * The role of the author (e.g., 'user', 'assistant').
 */
export type Role = "system" | "user" | "assistant";

/**
 * Soft routing preferences used for deterministic provider ordering.
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

/**
 * A descriptor specifying the type of work to be performed. For text-to-text, the kind must
 * be 'text_to_text'.
 */
export type Task = {
    /**
     * The standard task category. Currently supports 'text_to_text' for prompt-based
     * interactions.
     */
    kind: "text_to_text";
    [property: string]: unknown;
}

/**
 * Execution preferences for tracking usage and performance metrics.
 */
export type Telemetry = {
    /**
     * Whether the user consents to telemetry collection for this specific request.
     */
    consent?: boolean;
    /**
     * The granularity of the collected metrics (off, minimal, or debug).
     */
    level?: Level;
    /**
     * Optional key-value pairs for correlating telemetry data with specific features or users.
     */
    tags?: { [key: string]: string };
    [property: string]: unknown;
}

/**
 * The granularity of the collected metrics (off, minimal, or debug).
 */
export type Level = "off" | "minimal" | "debug";
