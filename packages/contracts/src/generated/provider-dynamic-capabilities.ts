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
     * The live state of each declared speech control for this task (ADR 025), at most one entry
     * per id and delivery. A voice's own controlStates override these for that voice. A control
     * and delivery with no entry are in the unknown state.
     */
    controlStates?: SpeechControlState[];
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
     * How ready the task is to run. Absent means 'ready'. With available false, 'not_prepared'
     * or 'preparing' means 'not yet' rather than 'not on this device'; this entry then decides
     * even when the provider-level available is false.
     */
    readiness?: ProviderReadiness;
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
     * Every voice available for this task right now, one entry per voice. Absent means the
     * provider cannot enumerate them; a request that requires a voice then never routes to it.
     */
    voices?: ProviderVoice[];
    [property: string]: unknown;
}

/**
 * Whether one speech control works right now on one output delivery, and with which values
 * (ADR 025). Entries are keyed by id and delivery: a list holds at most one entry per pair,
 * and a provider whose playback and artifact paths differ states each. Absent available
 * means unknown, and unknown is never support: a control satisfies a request only with
 * available true and, for a number, a known range that contains the value. On a voice,
 * every field present overrides the task's entry with the same id and delivery for that
 * voice. playback.volume only ever has a 'playback' entry.
 */
export type SpeechControlState = {
    /**
     * Whether the control works. Absent means unknown. Never null.
     */
    available?: boolean;
    delivery:   ControlDelivery;
    id:         SpeechControlId;
    /**
     * The values a number control accepts, in the shared control's units. On a voice it
     * replaces the task's range.
     */
    range?: SpeechControlRange;
    /**
     * Why the control does not work, when available is false.
     */
    reason?: string;
    [property: string]: unknown;
}

/**
 * The output delivery a speech control or control state applies to: 'playback' or
 * 'artifact'. Text output ('inline') has no speech controls.
 */
export type ControlDelivery = "playback" | "artifact";

/**
 * A shared speech control (ADR 025): 'speech.speakingRate' (relative pace, 1.0 normal),
 * 'speech.pitch' (relative baseline pitch, 1.0 normal), 'playback.volume' (attenuation of
 * one utterance, 0 to 1). Closed: a provider-owned control is a later, namespaced addition.
 */
export type SpeechControlId = "speech.speakingRate" | "speech.pitch" | "playback.volume";

/**
 * The values a number control accepts, in the shared control's units. On a voice it
 * replaces the task's range.
 */
export type SpeechControlRange = {
    /**
     * The value the provider uses when the request names none.
     */
    default?: number;
    /**
     * Largest accepted value, inclusive.
     */
    max: number;
    /**
     * Smallest accepted value, inclusive.
     */
    min: number;
    /**
     * An increment for a settings slider. A hint, not a quantization rule.
     */
    step?: number;
    [property: string]: unknown;
}

/**
 * How ready the task is to run. Absent means 'ready'. With available false, 'not_prepared'
 * or 'preparing' means 'not yet' rather than 'not on this device'; this entry then decides
 * even when the provider-level available is false.
 *
 * How ready something is to run (ADR 019). 'ready': it runs now at full speed. 'cold': it
 * runs now, but its first run is slow. 'not_prepared': it cannot run until prepare() has
 * run. 'preparing': it is being prepared now and cannot run yet.
 *
 * How ready the voice is to speak. Absent means 'ready'.
 */
export type ProviderReadiness = "ready" | "cold" | "not_prepared" | "preparing";

/**
 * One available voice: its provider-neutral traits, and an id and name for an application
 * that lets someone choose it.
 */
export type ProviderVoice = {
    /**
     * Sparse overrides of the task's controlStates for this voice (ADR 025), matched by id and
     * delivery. A pair with no entry inherits the task's state for that pair; available false
     * disables the control for this voice on that delivery; a range replaces the task's range
     * for that delivery.
     */
    controlStates?: SpeechControlState[];
    gender?:        VoiceGender;
    /**
     * Identifies this voice within its provider, for use as speech.voice.id with
     * speech.voice.providerId. Opaque: stable on this device while the voice stays installed,
     * and meaningful nowhere else. Absent when the provider cannot address single voices.
     */
    id?: string;
    /**
     * BCP 47 locale the voice speaks.
     */
    locale: string;
    /**
     * Every BCP 47 tag the voice speaks; may repeat `locale`. A request's locale matches
     * `locale` or any entry here.
     */
    locales?: string[];
    /**
     * Label for showing the voice to a person, as the platform reports it. Not unique and not
     * localized; never compare it.
     */
    name?: string;
    /**
     * Whether using the voice sends data off the device. Absent inherits the task's privacy
     * posture.
     */
    networkRequired?: boolean;
    /**
     * How ready the voice is to speak. Absent means 'ready'.
     */
    readiness?: ProviderReadiness;
    [property: string]: unknown;
}

/**
 * Perceived gender of a voice, as the platform reports it.
 */
export type VoiceGender = "female" | "male" | "neutral";
