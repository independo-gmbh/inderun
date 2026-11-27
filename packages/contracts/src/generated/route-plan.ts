/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

/**
 * Deterministic shared-core Mode-1 route planning result.
 */
export type RoutePlan = {
    /**
     * Eligible candidates in deterministic order.
     */
    candidates: Candidate[];
    /**
     * Human-readable selection or failure explanation suitable for telemetry/debugging.
     */
    explanation: Explanation;
    /**
     * Normalized routing failure class when no provider is selected.
     */
    failureCode?: FailureCode;
    /**
     * Fallback provider IDs ordered after the primary selection.
     */
    fallbackProviderIds: string[];
    /**
     * Providers filtered out during planning together with machine-readable reasons.
     */
    rejectedProviders: RejectedProvider[];
    /**
     * Chosen primary provider ID, if any.
     */
    selectedProviderId?: string;
    [property: string]: unknown;
}

export type Candidate = {
    /**
     * What this candidate must do with each requested speech control (ADR 025), in request
     * order, evaluated on the bound voice (or on the task's control states when the provider
     * lists no voices). Every 'required' control has decision 'apply'. Absent when the request
     * names no controls.
     */
    controls?:  ControlApplicationPlan[];
    order:      number;
    providerId: string;
    /**
     * The voice this candidate must use if it is attempted, chosen by the planner from the
     * provider's dynamic voice inventory. It is the best voice that satisfies the request's
     * locale, required voice traits and privacy — under local-required privacy always one that
     * keeps data on the device — ranked by preferred id, then preferred gender, then exact
     * locale region, then on-device before network. The adapter must use the voice with this
     * id, or one with exactly these traits when the voice has no id. Absent when the request
     * names no locale or voice, or the provider does not list its voices; the adapter then
     * chooses itself under the same rules.
     */
    voice?: ProviderVoice;
    [property: string]: unknown;
}

export type ControlApplicationPlan = {
    /**
     * 'apply': the provider must apply the value. 'omit': the provider must leave the control
     * at its normal behaviour and report it as not applied with this reason.
     */
    decision:    ControlDecision;
    id:          SpeechControlId;
    reason?:     ControlOmissionReason;
    requirement: RequirementLevel;
    /**
     * The requested value.
     */
    value: number;
    [property: string]: unknown;
}

/**
 * 'apply': the provider must apply the value. 'omit': the provider must leave the control
 * at its normal behaviour and report it as not applied with this reason.
 */
export type ControlDecision = "apply" | "omit";

/**
 * A shared speech control (ADR 025): 'speech.speakingRate' (relative pace, 1.0 normal),
 * 'speech.pitch' (relative baseline pitch, 1.0 normal), 'playback.volume' (attenuation of
 * one utterance, 0 to 1). Closed: a provider-owned control is a later, namespaced addition.
 */
export type SpeechControlId = "speech.speakingRate" | "speech.pitch" | "playback.volume";

/**
 * Why a preferred control is omitted: 'unsupported' (not declared for this delivery, or the
 * bound voice disables it), 'out_of_range' (outside the known range), 'range_unknown'
 * (available, but no range is known), 'availability_unknown' (no state says it works).
 */
export type ControlOmissionReason = "unsupported" | "out_of_range" | "range_unknown" | "availability_unknown";

/**
 * 'required' takes part in routing; 'preferred' does not.
 */
export type RequirementLevel = "required" | "preferred";

/**
 * The voice this candidate must use if it is attempted, chosen by the planner from the
 * provider's dynamic voice inventory. It is the best voice that satisfies the request's
 * locale, required voice traits and privacy — under local-required privacy always one that
 * keeps data on the device — ranked by preferred id, then preferred gender, then exact
 * locale region, then on-device before network. The adapter must use the voice with this
 * id, or one with exactly these traits when the voice has no id. Absent when the request
 * names no locale or voice, or the provider does not list its voices; the adapter then
 * chooses itself under the same rules.
 *
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
 * Perceived gender of a voice, as the platform reports it.
 */
export type VoiceGender = "female" | "male" | "neutral";

/**
 * How ready the voice is to speak. Absent means 'ready'.
 *
 * How ready something is to run (ADR 019). 'ready': it runs now at full speed. 'cold': it
 * runs now, but its first run is slow. 'not_prepared': it cannot run until prepare() has
 * run. 'preparing': it is being prepared now and cannot run yet.
 */
export type ProviderReadiness = "ready" | "cold" | "not_prepared" | "preparing";

/**
 * Human-readable selection or failure explanation suitable for telemetry/debugging.
 */
export type Explanation = {
    selectedProviderId?: string;
    summary:             string;
    [property: string]: unknown;
}

/**
 * Normalized routing failure class when no provider is selected.
 */
export type FailureCode = "capability_mismatch" | "offline" | "unavailable";

export type RejectedProvider = {
    providerId: string;
    reasons:    Reason[];
    [property: string]: unknown;
}

export type Reason = {
    /**
     * Normalized rejection reason. 'streaming_not_supported' means the descriptor does not
     * statically declare Mode-2 streaming; 'streaming_unavailable' means it declares streaming
     * but the dynamic capability snapshot reports it cannot stream in the current host
     * environment. 'not_in_model_profile' means the request named a model profile that does not
     * list this provider. 'input_not_supported', 'output_delivery_not_supported',
     * 'output_format_not_supported', 'locale_not_supported' and 'voice_not_available' mean the
     * provider's task capability lacks an input kind, output delivery, media type, locale or
     * voice the request requires. 'prepare_not_supported' means the task capability declares no
     * prepare(). 'not_ready' means the provider, task or required voice exists but is not
     * prepared yet, so prepare() can make it available. 'speech_control_unsupported' means no
     * voice the provider could bind supports a required speech control for the requested
     * delivery; 'speech_control_out_of_range' means one supports it, but not the requested
     * value (ADR 025).
     */
    code:    Code;
    message: string;
    [property: string]: unknown;
}

/**
 * Normalized rejection reason. 'streaming_not_supported' means the descriptor does not
 * statically declare Mode-2 streaming; 'streaming_unavailable' means it declares streaming
 * but the dynamic capability snapshot reports it cannot stream in the current host
 * environment. 'not_in_model_profile' means the request named a model profile that does not
 * list this provider. 'input_not_supported', 'output_delivery_not_supported',
 * 'output_format_not_supported', 'locale_not_supported' and 'voice_not_available' mean the
 * provider's task capability lacks an input kind, output delivery, media type, locale or
 * voice the request requires. 'prepare_not_supported' means the task capability declares no
 * prepare(). 'not_ready' means the provider, task or required voice exists but is not
 * prepared yet, so prepare() can make it available. 'speech_control_unsupported' means no
 * voice the provider could bind supports a required speech control for the requested
 * delivery; 'speech_control_out_of_range' means one supports it, but not the requested
 * value (ADR 025).
 */
export type Code = "task_not_supported" | "run_not_supported" | "streaming_not_supported" | "streaming_unavailable" | "privacy_constraint" | "cloud_constraint" | "offline" | "capability_unavailable" | "not_in_model_profile" | "input_not_supported" | "output_delivery_not_supported" | "output_format_not_supported" | "locale_not_supported" | "voice_not_available" | "prepare_not_supported" | "not_ready" | "speech_control_unsupported" | "speech_control_out_of_range";
