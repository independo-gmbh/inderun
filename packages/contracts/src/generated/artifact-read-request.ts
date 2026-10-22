/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

/**
 * A ranged read of an engine-owned media artifact through IndeRunApi.readArtifact (ADR
 * 017). Reads are repeatable until the artifact is disposed; each returns at most the
 * engine's configured maximum read size, which bounds what one call -- and one bridge
 * message -- carries.
 */
export type ArtifactReadRequest = {
    /**
     * MediaArtifact.id of the artifact to read.
     */
    artifactId: string;
    /**
     * Most bytes to return. Absent, or larger than the engine's maximum read size, means that
     * maximum.
     */
    maxBytes?: number;
    /**
     * Byte offset to read from. Absent means 0. An offset equal to the artifact's size returns
     * an empty, final chunk; a larger one is rejected.
     */
    offset?: number;
    [property: string]: unknown;
}
