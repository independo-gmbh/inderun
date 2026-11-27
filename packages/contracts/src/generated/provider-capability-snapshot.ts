/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

/**
 * One registered provider's identity, static declaration and live capability check, as
 * returned by checkCapabilities(). A read-only snapshot: producing it executes no task and
 * has no side effects.
 */
export type ProviderCapabilitySnapshot = {
    /**
     * The provider's live capability check at the time of the call.
     */
    capabilities: ProviderDynamicCapabilities;
    /**
     * The provider's static capability declaration.
     */
    descriptor: ProviderDescriptor;
    /**
     * Identifier of the provider; equal to descriptor.id.
     */
    providerId: string;
    [property: string]: unknown;
}

/**
 * The provider's live capability check at the time of the call.
 *
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

/**
 * The provider's static capability declaration.
 *
 * A provider's static capability declaration: identity, placement, transport, supported
 * interaction modes and tasks, cancellation guarantee, resource limits and privacy posture.
 * It does not change while the provider is registered. The route planner,
 * checkCapabilities() and execution provenance all read this one shape.
 */
export type ProviderDescriptor = {
    /**
     * Cancellation guarantee: 'hard' stops processing including remote work, 'soft' stops
     * reading locally while remote work may continue, 'none' means cancellation is unsupported.
     * Independently of this value, the engine delivers no event after a cancel.
     */
    cancel: CancelSemantics;
    /**
     * Unique identifier of the provider instance (a target), e.g. 'apple_foundation_models' or
     * 'openai_compatible_cloud:gpt-5-mini'. Model profiles list targets by this id.
     */
    id: string;
    /**
     * Optional input and output resource limits.
     */
    limits?: ProviderLimits;
    /**
     * The model this provider instance is bound to, when it can name one. Cloud providers
     * report the model id they send; platform-managed models report an opaque platform alias
     * rather than a guessed weight name. Absent means the provider cannot name its model.
     */
    model?: string;
    /**
     * Data-egress posture, used to enforce local and cloud routing rules. Absent means a local
     * or edge provider is treated as keeping data on the device and a cloud provider as sending
     * it off.
     */
    privacy?: ProviderPrivacy;
    /**
     * How a streaming provider delivers incremental output: individual tokens, larger chunks,
     * or whole snapshots. Absent for providers that do not stream.
     */
    streamingStyle?: StreamingStyle;
    /**
     * Interaction modes and features the provider statically declares.
     */
    supports: ProviderSupports;
    /**
     * What the provider can do for each task: accepted inputs, interaction modes, output
     * deliveries and formats, cancellation, locales and privacy. When present it is
     * authoritative for routing and must list every task the provider serves. When absent (a
     * legacy descriptor), routing infers exactly one entry — 'text_to_text' with text input,
     * inline output, run/stream from supports and cancel from cancel — if tasks contains
     * 'text_to_text', and nothing for any other task: a legacy descriptor is never treated as
     * capable of a non-text task.
     */
    taskCapabilities?: ProviderTaskCapability[];
    /**
     * Task kinds the provider supports, e.g. 'text_to_text'. When taskCapabilities is present
     * it must describe the same kinds and is what routing reads; without it, routing infers
     * capabilities for 'text_to_text' alone (see taskCapabilities).
     */
    tasks: string[];
    /**
     * How the engine reaches the provider: in-process runtime, operating-system service,
     * buffered HTTP, server-sent events, or a realtime connection.
     */
    transport: ProviderTransport;
    /**
     * Execution placement: 'local' (on the device), 'edge', or 'cloud'.
     */
    type: ProviderType;
    [property: string]: unknown;
}

/**
 * Cancellation guarantee: 'hard' stops processing including remote work, 'soft' stops
 * reading locally while remote work may continue, 'none' means cancellation is unsupported.
 * Independently of this value, the engine delivers no event after a cancel.
 *
 * Cancellation guarantee for this task. It may differ from the provider-level cancel, e.g.
 * when stopping playback is immediate but a synthesis request cannot be aborted.
 */
export type CancelSemantics = "hard" | "soft" | "none";

/**
 * Optional input and output resource limits.
 */
export type ProviderLimits = {
    /**
     * Longest accepted or produced audio, in seconds.
     */
    maxAudioSeconds?: number;
    /**
     * Largest accepted image, in bytes.
     */
    maxImageBytes?: number;
    /**
     * Largest accepted input, in tokens.
     */
    maxInputTokens?: number;
    /**
     * Largest output the provider produces, in tokens.
     */
    maxOutputTokens?: number;
    [property: string]: unknown;
}

/**
 * Data-egress posture, used to enforce local and cloud routing rules. Absent means a local
 * or edge provider is treated as keeping data on the device and a cloud provider as sending
 * it off.
 *
 * Data-egress posture for this task when it differs from the provider-level privacy, e.g. a
 * provider whose speech synthesis uses a network service. Absent inherits
 * descriptor.privacy.
 */
export type ProviderPrivacy = {
    /**
     * Whether request content leaves the device.
     */
    dataLeavesDevice: boolean;
    /**
     * Geographic regions where a cloud provider processes data.
     */
    regions?: string[];
    [property: string]: unknown;
}

/**
 * How a streaming provider delivers incremental output: individual tokens, larger chunks,
 * or whole snapshots. Absent for providers that do not stream.
 */
export type StreamingStyle = "tokens" | "chunks" | "snapshots";

/**
 * Interaction modes and features the provider statically declares.
 */
export type ProviderSupports = {
    /**
     * Whether the provider accepts non-text inputs such as images or audio.
     */
    multimodal: boolean;
    /**
     * Whether the provider supports Mode 3 realtime sessions. Reserved; no engine implements
     * Mode 3 yet.
     */
    realtime: boolean;
    /**
     * Whether the provider emits reasoning events alongside content.
     */
    reasoningEvents: boolean;
    /**
     * Whether the provider supports Mode 1 run (request/response).
     */
    run: boolean;
    /**
     * Whether the provider supports Mode 2 stream. A provider that declares it must also
     * implement the streaming adapter; the engines report it as unavailable otherwise.
     */
    streaming: boolean;
    /**
     * Whether the provider supports structured output constrained by a JSON schema.
     */
    structuredOutput: boolean;
    /**
     * Whether the provider supports tool calling.
     */
    tools: boolean;
    [property: string]: unknown;
}

/**
 * The provider's static capabilities for one task kind.
 */
export type ProviderTaskCapability = {
    /**
     * Cancellation guarantee for this task. It may differ from the provider-level cancel, e.g.
     * when stopping playback is immediate but a synthesis request cannot be aborted.
     */
    cancel: CancelSemantics;
    /**
     * Speech controls the provider implements for this task (ADR 025), one entry per id. Absent
     * or empty means none. Whether a control works on this host, and its range, is in the
     * dynamic check's controlStates; a declaration alone never satisfies a request.
     */
    controls?: SpeechControlDeclaration[];
    /**
     * Input media kinds the provider accepts for this task.
     */
    inputs: [TaskInputKind, ...TaskInputKind[]];
    /**
     * Interaction modes the provider supports for this task.
     */
    interaction: ProviderTaskInteraction;
    /**
     * The task kind this entry describes, e.g. 'text_to_speech'.
     */
    kind: string;
    /**
     * BCP 47 locales the provider can serve for this task, when it knows them statically.
     * Absent means unknown; the dynamic check may report them instead.
     */
    locales?: string[];
    /**
     * How results of this task can be delivered. A provider lists only what it really produces:
     * a provider that can only play audio lists 'playback' and never 'artifact'.
     */
    outputs: [ProviderTaskOutput, ...ProviderTaskOutput[]];
    /**
     * Data-egress posture for this task when it differs from the provider-level privacy, e.g. a
     * provider whose speech synthesis uses a network service. Absent inherits
     * descriptor.privacy.
     */
    privacy?: ProviderPrivacy;
    [property: string]: unknown;
}

/**
 * One speech control a provider implements: what kind of value it takes, which part of the
 * run it affects, how long a value lasts, and the deliveries it applies to. The shared ids
 * fix kind and phase: speech.speakingRate and speech.pitch are 'number' and 'synthesis',
 * playback.volume is 'number' and 'playback'. A task lists each id at most once.
 */
export type SpeechControlDeclaration = {
    /**
     * The output deliveries this control applies to. A synthesis control lists each delivery
     * whose path applies it; a playback-phase control lists only 'playback'.
     */
    deliveries: [ControlDelivery, ...ControlDelivery[]];
    id:         SpeechControlId;
    /**
     * 'utterance': set per request. 'provider_instance': fixed when the provider was built,
     * documented here and never satisfying a request.
     */
    lifetime: SpeechControlLifetime;
    /**
     * 'synthesis': shapes the audio itself. 'playback': shapes only how a playback run is
     * heard, so it lists only the playback delivery.
     */
    phase: SpeechControlPhase;
    /**
     * The kind of value the control takes. Every shared control is a 'number'; 'choice' and
     * 'boolean' are reserved for later controls.
     */
    valueKind: SpeechControlValueKind;
    [property: string]: unknown;
}

/**
 * 'utterance': set per request. 'provider_instance': fixed when the provider was built,
 * documented here and never satisfying a request.
 */
export type SpeechControlLifetime = "utterance" | "provider_instance";

/**
 * 'synthesis': shapes the audio itself. 'playback': shapes only how a playback run is
 * heard, so it lists only the playback delivery.
 */
export type SpeechControlPhase = "synthesis" | "playback";

/**
 * The kind of value the control takes. Every shared control is a 'number'; 'choice' and
 * 'boolean' are reserved for later controls.
 */
export type SpeechControlValueKind = "number" | "choice" | "boolean";

/**
 * A kind of input medium a task consumes.
 */
export type TaskInputKind = "text" | "image" | "audio";

/**
 * Interaction modes the provider supports for this task.
 */
export type ProviderTaskInteraction = {
    /**
     * Whether the provider implements prepare() for this task (ADR 019). Absent means false.
     */
    prepare?: boolean;
    /**
     * Whether the provider supports Mode 1 run for this task.
     */
    run: boolean;
    /**
     * Whether the provider supports Mode 2 stream for this task.
     */
    stream: boolean;
    [property: string]: unknown;
}

/**
 * One way the provider can deliver a task's result.
 */
export type ProviderTaskOutput = {
    delivery: OutputDelivery;
    /**
     * Media types the provider can produce with this delivery, e.g. 'audio/wav'. Absent means
     * the provider does not declare them; a request that requires specific media types never
     * routes to such an output.
     */
    mediaTypes?: string[];
    [property: string]: unknown;
}

/**
 * How a task's result reaches the application: 'inline' content in the result (text),
 * 'playback' as a managed, audible effect on the device with no retrievable bytes, or
 * 'artifact' as retrievable media.
 */
export type OutputDelivery = "inline" | "playback" | "artifact";

/**
 * How the engine reaches the provider: in-process runtime, operating-system service,
 * buffered HTTP, server-sent events, or a realtime connection.
 */
export type ProviderTransport = "in_process" | "system_service" | "http" | "sse" | "realtime";

/**
 * Execution placement: 'local' (on the device), 'edge', or 'cloud'.
 */
export type ProviderType = "local" | "edge" | "cloud";
