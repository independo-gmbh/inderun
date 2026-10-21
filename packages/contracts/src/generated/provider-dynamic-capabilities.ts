/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

/**
 * A provider's live capability check, evaluated on the current host when routing or when
 * checkCapabilities() is called. Unlike the descriptor it can change between calls.
 */
export type ProviderDynamicCapabilities = {
    /**
     * Whether the provider is available and functional on this host right now.
     */
    available: boolean;
    /**
     * Whether cancellation is honored on this host right now. Absent inherits the static
     * descriptor.cancel value: any value other than 'none' means available. Never null.
     */
    cancellationAvailable?: boolean;
    /**
     * Why the provider is unavailable, when available is false.
     */
    reason?: string;
    /**
     * Whether the provider can stream (Mode 2) on this host right now. Absent inherits the
     * static descriptor.supports.streaming value; only set it when the host takes streaming
     * away from a provider that otherwise declares it. Never null.
     */
    streamingAvailable?: boolean;
    /**
     * Why streaming is unavailable, when streamingAvailable is false. Absent lets the route
     * planner synthesize a default message.
     */
    streamingUnavailableReason?: string;
    /**
     * Per-task overrides of the provider-level check, for tasks whose availability differs on
     * this host, e.g. a voice that is not installed. Every field of an entry is optional and
     * absent inherits the provider-level value; a false at either level wins.
     */
    taskCapabilities?: ProviderTaskAvailability[];
    [property: string]: unknown;
}

/**
 * The live check for one task kind.
 */
export type ProviderTaskAvailability = {
    /**
     * Whether the task can run on this host right now. Absent inherits the provider-level
     * available. Never null.
     */
    available?: boolean;
    /**
     * Whether cancellation is honored for this task right now. Absent inherits. Never null.
     */
    cancellationAvailable?: boolean;
    /**
     * The task kind this entry describes.
     */
    kind: string;
    /**
     * BCP 47 locales available for this task right now. Absent means the provider cannot
     * enumerate them.
     */
    locales?: string[];
    /**
     * Why the task is unavailable, when available is false.
     */
    reason?: string;
    /**
     * Whether the task can stream on this host right now. Absent inherits. Never null.
     */
    streamingAvailable?: boolean;
    /**
     * Why streaming is unavailable for this task, when streamingAvailable is false.
     */
    streamingUnavailableReason?: string;
    /**
     * Voices available for this task right now. Absent means the provider cannot enumerate
     * them; a request that requires a voice then never routes to it.
     */
    voices?: ProviderVoice[];
    [property: string]: unknown;
}

/**
 * Provider-neutral traits of one available voice. Carries no provider voice identifier.
 */
export type ProviderVoice = {
    gender?: VoiceGender;
    /**
     * BCP 47 locale the voice speaks.
     */
    locale: string;
    /**
     * Whether using the voice sends data off the device. Absent inherits the task's privacy
     * posture.
     */
    networkRequired?: boolean;
    [property: string]: unknown;
}

/**
 * Perceived gender of a voice, as the platform reports it.
 */
export type VoiceGender = "female" | "male" | "neutral";
