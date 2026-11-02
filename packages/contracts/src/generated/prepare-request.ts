/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

/**
 * Optional scope for IndeRunApi.prepare (ADR 019). Every field is optional: an empty
 * request covers every registered provider and task. It carries no user content.
 */
export type PrepareRequest = {
    /**
     * Lets this call start a platform's own download, whatever autoDownload says at
     * registration. Call it from a user's decision. Absent follows autoDownload.
     */
    allowDownload?: boolean;
    /**
     * BCP 47 tag of the language to prepare. Absent lets a speech provider use the device's own
     * language.
     */
    locale?: string;
    /**
     * How locale compares: 'language' (default) or 'exact'.
     */
    localeMatch?: LocaleMatch;
    /**
     * The privacy policy of the runs this precedes.
     */
    privacy?: Privacy;
    /**
     * Fixes the run id, for correlation.
     */
    requestId?: string;
    /**
     * Task kinds to prepare. Absent means every task a registered provider can prepare.
     */
    tasks?: string[];
    /**
     * A voice to prepare, as for a speech request.
     */
    voice?: PrepareVoice;
    [property: string]: unknown;
}

/**
 * How locale compares: 'language' (default) or 'exact'.
 */
export type LocaleMatch = "exact" | "language";

/**
 * The privacy policy of the runs this precedes.
 */
export type Privacy = "local_required" | "local_preferred" | "cloud_allowed" | "cloud_required";

/**
 * A voice to prepare, as for a speech request.
 */
export type PrepareVoice = {
    gender?: VoiceGender;
    /**
     * A voice id read from listVoices().
     */
    id?: string;
    /**
     * The provider that listed id.
     */
    providerId?: string;
    [property: string]: unknown;
}

/**
 * Perceived gender of a voice, as the platform reports it.
 */
export type VoiceGender = "female" | "male" | "neutral";
