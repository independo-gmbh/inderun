/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

/**
 * Milestone-1 text-to-text request contract for Mode 1 run().
 */
export type TaskRequest = {
    /**
     * Reference to a secure credential slot. Raw credentials must not be placed in the request.
     */
    authContextRef?: string;
    /**
     * Optional provider-neutral generation hints.
     */
    generation?: Generation;
    /**
     * Conversation-style text input for chat-like text-to-text execution.
     */
    messages?: Message[];
    /**
     * Execution policy constraints used by the router.
     */
    policy: Policy;
    /**
     * Single text prompt input for simple text-to-text execution.
     */
    prompt?: string;
    /**
     * Optional caller-provided idempotency/debug identifier for this request.
     */
    requestId?: string;
    /**
     * Contract schema version used to interpret the request payload.
     */
    schemaVersion: "1.0";
    /**
     * Task descriptor used by routing and provider capability matching.
     */
    task: Task;
    /**
     * Caller telemetry preferences for this request.
     */
    telemetry?: Telemetry;
    [property: string]: unknown;
}

/**
 * Optional provider-neutral generation hints.
 */
export type Generation = {
    /**
     * Optional upper bound for generated output tokens.
     */
    maxOutputTokens?: number;
    /**
     * Optional deterministic generation seed when supported by the provider.
     */
    seed?: number;
    /**
     * Optional stop sequences that should end generation when matched.
     */
    stop?: string[];
    /**
     * Optional randomness hint where 0 is most deterministic and 2 is highest supported
     * variance.
     */
    temperature?: number;
    /**
     * Optional nucleus sampling probability hint.
     */
    topP?: number;
    [property: string]: unknown;
}

/**
 * One message in the conversation input.
 */
export type Message = {
    /**
     * Text content for this message.
     */
    content: string;
    /**
     * Role of the message author.
     */
    role: Role;
    [property: string]: unknown;
}

/**
 * Role of the message author.
 */
export type Role = "system" | "user" | "assistant";

/**
 * Execution policy constraints used by the router.
 */
export type Policy = {
    /**
     * Required execution target for milestone routing.
     */
    execution: Execution;
    [property: string]: unknown;
}

/**
 * Required execution target for milestone routing.
 */
export type Execution = "on_device" | "cloud";

/**
 * Task descriptor used by routing and provider capability matching.
 */
export type Task = {
    /**
     * Milestone-1 task kind for text input to text output.
     */
    kind: "text_to_text";
    [property: string]: unknown;
}

/**
 * Caller telemetry preferences for this request.
 */
export type Telemetry = {
    /**
     * Whether the caller consents to telemetry collection for this request.
     */
    consent?: boolean;
    /**
     * Requested telemetry detail level.
     */
    level?: Level;
    /**
     * Optional caller-provided non-secret labels for telemetry correlation.
     */
    tags?: { [key: string]: string };
    [property: string]: unknown;
}

/**
 * Requested telemetry detail level.
 */
export type Level = "off" | "minimal" | "debug";
