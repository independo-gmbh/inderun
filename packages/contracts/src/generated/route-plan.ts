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
    order:      number;
    providerId: string;
    /**
     * The voice this candidate must use if it is attempted, chosen by the planner from the
     * provider's dynamic voice inventory. It is the best voice that satisfies the request's
     * locale, required voice traits and privacy — under local-required privacy always one that
     * keeps data on the device — ranked by preferred gender, then exact locale region, then
     * on-device before network. The adapter must use a voice with exactly these traits. Absent
     * when the request names no locale or voice, or the provider does not list its voices; the
     * adapter then chooses itself under the same rules.
     */
    voice?: ProviderVoice;
    [property: string]: unknown;
}

/**
 * The voice this candidate must use if it is attempted, chosen by the planner from the
 * provider's dynamic voice inventory. It is the best voice that satisfies the request's
 * locale, required voice traits and privacy — under local-required privacy always one that
 * keeps data on the device — ranked by preferred gender, then exact locale region, then
 * on-device before network. The adapter must use a voice with exactly these traits. Absent
 * when the request names no locale or voice, or the provider does not list its voices; the
 * adapter then chooses itself under the same rules.
 *
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
     * voice the request requires.
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
 * voice the request requires.
 */
export type Code = "task_not_supported" | "run_not_supported" | "streaming_not_supported" | "streaming_unavailable" | "privacy_constraint" | "cloud_constraint" | "offline" | "capability_unavailable" | "not_in_model_profile" | "input_not_supported" | "output_delivery_not_supported" | "output_format_not_supported" | "locale_not_supported" | "voice_not_available";
