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
 * A kind of input medium a task consumes.
 */
export type TaskInputKind = "text" | "image" | "audio";

/**
 * Interaction modes the provider supports for this task.
 */
export type ProviderTaskInteraction = {
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
