/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

/**
 * The normalized output of a run, shared by TaskResult and the completed and cancelled
 * stream terminal outcomes (ADR 016). 'type' describes the content representation, not the
 * task: 'text' carries inline text, 'playback' reports a managed, audible effect that has
 * no retrievable bytes, and 'artifact' references retrievable media (ADR 017). A playback
 * output is never an artifact, and an artifact output never implies that anything was
 * played.
 */
export type TaskOutput = {
    /**
     * The retrievable media the run produced. Required when type is 'artifact'.
     */
    artifact?: MediaArtifact;
    /**
     * Completion of managed playback. Required when type is 'playback'. Carries no media.
     */
    playback?: PlaybackOutput;
    /**
     * The locale and voice traits a text-to-speech run actually used, so an unmet preference is
     * visible without being an error.
     */
    speech?: SpeechOutput;
    /**
     * The text the run produced. Required when type is 'text'.
     */
    text?: string;
    /**
     * The content representation: 'text', 'playback' or 'artifact'.
     */
    type: TaskOutputType;
    [property: string]: unknown;
}

/**
 * The retrievable media the run produced. Required when type is 'artifact'.
 *
 * A reference to retrievable media a run produced (ADR 017). It carries no bytes and no
 * location: an engine-owned artifact is read through the engine by id, and an
 * application-owned one was written to an application destination. Media-neutral: audio,
 * images and video share this shape and differ only in mediaType.
 */
export type MediaArtifact = {
    /**
     * Size of the media in bytes. Always set for an artifact the engine materialized.
     */
    byteLength?: number;
    /**
     * The request's delivery.destinationRef the bytes were written to. Set exactly when owner
     * is 'application'.
     */
    destinationRef?: string;
    /**
     * Duration of time-based media in milliseconds, where the producer knows it.
     */
    durationMs?: number;
    /**
     * Opaque, engine-issued identifier. Never a path, URL or provider identifier.
     */
    id: string;
    /**
     * How long the engine keeps the bytes. 'until_disposed': until the application disposes the
     * artifact or the process ends; the artifact outlives the run that produced it.
     */
    lifetime: "until_disposed";
    /**
     * IANA media type of the bytes, e.g. 'audio/wav'. Encoding parameters ride on the media
     * type (e.g. 'audio/L16;rate=22050').
     */
    mediaType: string;
    /**
     * 'engine': the engine holds the bytes and the application reads them by id until it
     * disposes the artifact. 'application': the bytes were written to the application
     * destination named by destinationRef and the engine holds nothing.
     */
    owner: ArtifactOwner;
    [property: string]: unknown;
}

/**
 * How long the engine keeps the bytes. 'until_disposed': until the application disposes the
 * artifact or the process ends; the artifact outlives the run that produced it.
 */

/**
 * 'engine': the engine holds the bytes and the application reads them by id until it
 * disposes the artifact. 'application': the bytes were written to the application
 * destination named by destinationRef and the engine holds nothing.
 */
export type ArtifactOwner = "engine" | "application";

/**
 * Completion of managed playback. Required when type is 'playback'. Carries no media.
 */
export type PlaybackOutput = {
    /**
     * How long audible playback lasted, in milliseconds. For a cancelled run, how long it
     * played before it was stopped.
     */
    durationMs?: number;
    [property: string]: unknown;
}

/**
 * The locale and voice traits a text-to-speech run actually used, so an unmet preference is
 * visible without being an error.
 */
export type SpeechOutput = {
    /**
     * BCP 47 tag of the locale that was spoken.
     */
    locale: string;
    /**
     * Provider-neutral traits of the voice that spoke. Carries no provider voice identifier.
     */
    voice?: SpeechOutputVoice;
    [property: string]: unknown;
}

/**
 * Provider-neutral traits of the voice that spoke. Carries no provider voice identifier.
 */
export type SpeechOutputVoice = {
    gender?: VoiceGender;
    [property: string]: unknown;
}

/**
 * Perceived gender of a voice, as the platform reports it.
 */
export type VoiceGender = "female" | "male" | "neutral";

/**
 * The content representation: 'text', 'playback' or 'artifact'.
 */
export type TaskOutputType = "text" | "playback" | "artifact";
