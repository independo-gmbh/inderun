/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

/**
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
