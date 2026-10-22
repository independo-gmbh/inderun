/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

/**
 * The request payload for a run() or stream() execution. The common envelope
 * (schemaVersion, requestId, task, modelProfile, constraints, preferences, telemetry,
 * authContextRef) is task-agnostic; each task kind owns its payload (ADR 016).
 * text_to_text: at least one of `prompt` (single-turn) or `messages` (multi-turn) must be
 * present — both may be present together, though callers should typically supply just one —
 * and `speech`/`delivery` are forbidden. text_to_speech: `speech` and `delivery` are
 * required and `prompt`, `messages` and `generation` are forbidden.
 * `constraints`/`preferences` steer routing but never select a provider directly.
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
     * How the result of a non-text task must reach the application (ADR 016). Required for
     * non-text tasks and forbidden for text_to_text, whose output is implicitly inline. A
     * provider never substitutes playback for an artifact or the reverse.
     */
    delivery?: OutputDeliveryRequest;
    /**
     * Optional configuration for fine-tuning how the AI model generates its response.
     */
    generation?: Generation;
    /**
     * A list of interaction messages for multi-turn conversation or chat-style execution.
     */
    messages?: [Message, ...Message[]];
    /**
     * Name of the model profile to route within, as configured on the engine. Absent or 'auto'
     * means every registered target, ranked by constraints and preferences alone. A profile is
     * an application-defined, ordered allow-list of targets (provider instances bound to one
     * model each); raw model or provider identifiers are never accepted here. An unknown
     * profile name fails request validation.
     */
    modelProfile?: string;
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
     * The text_to_speech payload. Required for text_to_speech and forbidden for every other
     * kind.
     */
    speech?: SpeechInput;
    /**
     * A descriptor specifying the type of work to be performed. The kind selects which payload
     * the request must carry.
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
     * Optional timeout budget in milliseconds, passed to the planner and to providers. It
     * bounds the time until the run commits to a provider -- its first content, its first
     * possible audible effect, or its artifact handoff -- not the duration of audio it plays.
     * The engines add no timers of their own.
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
 * How the result of a non-text task must reach the application (ADR 016). Required for
 * non-text tasks and forbidden for text_to_text, whose output is implicitly inline. A
 * provider never substitutes playback for an artifact or the reverse.
 */
export type OutputDeliveryRequest = {
    /**
     * Only valid with 'artifact' delivery: the acceptable media types, always a hard
     * requirement. Absent means the provider chooses and the artifact reports what it produced.
     */
    mediaTypes?: [string, ...string[]];
    mode:        OutputDelivery;
    [property: string]: unknown;
}

/**
 * How a task's result reaches the application: 'inline' content in the result (text),
 * 'playback' as a managed, audible effect on the device with no retrievable bytes, or
 * 'artifact' as retrievable media.
 */
export type OutputDelivery = "inline" | "playback" | "artifact";

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
 * The text_to_speech payload. Required for text_to_speech and forbidden for every other
 * kind.
 */
export type SpeechInput = {
    /**
     * BCP 47 tag of the language to speak, e.g. 'de-AT'.
     */
    locale: string;
    /**
     * 'language' (default): the primary language subtag is a hard requirement and the region is
     * a preference. 'exact': the full tag is a hard requirement.
     */
    localeMatch?: LocaleMatch;
    /**
     * Plain text to speak. Markup such as SSML is out of scope.
     */
    text: string;
    /**
     * Provider-neutral voice traits. A 'preferred' voice (default) shapes which voice speaks
     * and is never a reason to fail; a 'required' one takes part in routing and is never
     * relaxed silently. Carries no provider voice identifier.
     */
    voice?: SpeechVoice;
    [property: string]: unknown;
}

/**
 * 'language' (default): the primary language subtag is a hard requirement and the region is
 * a preference. 'exact': the full tag is a hard requirement.
 */
export type LocaleMatch = "exact" | "language";

/**
 * Provider-neutral voice traits. A 'preferred' voice (default) shapes which voice speaks
 * and is never a reason to fail; a 'required' one takes part in routing and is never
 * relaxed silently. Carries no provider voice identifier.
 */
export type SpeechVoice = {
    gender?: VoiceGender;
    /**
     * 'preferred' (default) or 'required'. A required voice must name at least one trait.
     */
    requirement?: RequirementLevel;
    [property: string]: unknown;
}

/**
 * Perceived gender of a voice, as the platform reports it.
 */
export type VoiceGender = "female" | "male" | "neutral";

/**
 * 'preferred' (default) or 'required'. A required voice must name at least one trait.
 */
export type RequirementLevel = "required" | "preferred";

/**
 * A descriptor specifying the type of work to be performed. The kind selects which payload
 * the request must carry.
 */
export type Task = {
    /**
     * The operation: 'text_to_text' (prompt-based text generation) or 'text_to_speech' (speech
     * synthesis from text). A consumer built against an older revision rejects a kind it does
     * not know through validation.
     */
    kind: TaskKind;
    [property: string]: unknown;
}

/**
 * The operation: 'text_to_text' (prompt-based text generation) or 'text_to_speech' (speech
 * synthesis from text). A consumer built against an older revision rejects a kind it does
 * not know through validation.
 */
export type TaskKind = "text_to_text" | "text_to_speech";

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
