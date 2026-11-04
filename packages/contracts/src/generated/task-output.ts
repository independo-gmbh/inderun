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
     * What a prepare() run did, one item per provider and task. Required when type is
     * 'prepared'. One failed item does not fail the run.
     */
    preparation?: PreparationItem[];
    /**
     * The locale and voice a text-to-speech run actually used, so an unmet preference is
     * visible without being an error.
     */
    speech?: SpeechOutput;
    /**
     * The text the run produced. Required when type is 'text'.
     */
    text?: string;
    /**
     * The content representation: 'text', 'playback' or 'artifact'. 'prepared' ends a prepare()
     * run, carries no content, and lists each item in 'preparation'.
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
     * What the provider measured about the playback. Absent when it measured nothing.
     * 'firstAudioMs' and 'firstChunkMs' count from the same origin: the moment the provider's
     * run() or stream() started handling the request, so their difference is the provider's
     * output latency. The span includes everything the provider does after it starts handling
     * the request (queue wait, voice lookup, a cold model load) and excludes routing.
     */
    timing?: PlaybackTiming;
    [property: string]: unknown;
}

/**
 * What the provider measured about the playback. Absent when it measured nothing.
 * 'firstAudioMs' and 'firstChunkMs' count from the same origin: the moment the provider's
 * run() or stream() started handling the request, so their difference is the provider's
 * output latency. The span includes everything the provider does after it starts handling
 * the request (queue wait, voice lookup, a cold model load) and excludes routing.
 */
export type PlaybackTiming = {
    /**
     * How long audible playback lasted, in milliseconds. For a cancelled run, how long it
     * played before it was stopped, when the provider reports it.
     */
    durationMs?: number;
    /**
     * Milliseconds from the provider receiving the request until the platform's first
     * audible-output callback (for a system voice, its first word callback) or the first audio
     * frame leaving the output. Absent when nothing reports it.
     */
    firstAudioMs?: number;
    /**
     * Milliseconds from the provider receiving the request until its first playable PCM chunk
     * existed. Absent when the provider does not synthesize PCM itself.
     */
    firstChunkMs?: number;
    [property: string]: unknown;
}

export type PreparationItem = {
    /**
     * The provider this item belongs to.
     */
    providerId: string;
    /**
     * Why the item was skipped or failed.
     */
    reason?: string;
    /**
     * 'prepared': this run made it ready. 'already_ready': nothing was needed. 'skipped': it
     * needs a download that neither autoDownload nor allowDownload permits. 'failed': see
     * reason.
     */
    status: PreparationStatus;
    /**
     * The task kind this item belongs to.
     */
    task: string;
    /**
     * The voice this item prepared, when one was bound.
     */
    voiceId?: string;
    [property: string]: unknown;
}

/**
 * 'prepared': this run made it ready. 'already_ready': nothing was needed. 'skipped': it
 * needs a download that neither autoDownload nor allowDownload permits. 'failed': see
 * reason.
 */
export type PreparationStatus = "prepared" | "already_ready" | "skipped" | "failed";

/**
 * The locale and voice a text-to-speech run actually used, so an unmet preference is
 * visible without being an error.
 */
export type SpeechOutput = {
    /**
     * BCP 47 tag of the locale that was spoken.
     */
    locale: string;
    /**
     * The voice that spoke, as the catalog lists it.
     */
    voice?: SpeechOutputVoice;
    [property: string]: unknown;
}

/**
 * The voice that spoke, as the catalog lists it.
 */
export type SpeechOutputVoice = {
    gender?: VoiceGender;
    /**
     * The voice's id, when its provider lists one.
     */
    id?: string;
    /**
     * The voice's display label, when its provider lists one.
     */
    name?: string;
    [property: string]: unknown;
}

/**
 * Perceived gender of a voice, as the platform reports it.
 */
export type VoiceGender = "female" | "male" | "neutral";

/**
 * The content representation: 'text', 'playback' or 'artifact'. 'prepared' ends a prepare()
 * run, carries no content, and lists each item in 'preparation'.
 */
export type TaskOutputType = "text" | "playback" | "artifact" | "prepared";
