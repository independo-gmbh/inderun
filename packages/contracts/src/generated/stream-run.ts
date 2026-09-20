/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

/**
 * The serializable acknowledgment returned when a Mode 2 stream is opened, before any
 * StreamEvent has arrived. This is the identity/correlation contract only: the live,
 * consumable stream itself is a platform-idiomatic construct (an AsyncIterable<StreamEvent>
 * in TypeScript, a Flow<StreamEvent> in Kotlin, an AsyncThrowingStream<StreamEvent, Error>
 * in Swift) that is never serialized and is out of scope for this schema. Design seam only;
 * no engine or provider implementation exists yet (see docs/architecture/architecture.md).
 */
export type StreamRunHandle = {
    /**
     * Identifier of the provider selected to service this stream, if routing has completed by
     * the time the handle is returned. Absent while route selection is still pending.
     */
    providerId?: string;
    /**
     * A unique, opaque identifier assigned by the engine for this stream run. Every StreamEvent
     * and the terminal StreamTerminalOutcome for this run carry the same runId, matching the
     * identity convention used by TaskResult.runId and IndeRunError.runId.
     */
    runId: string;
    /**
     * Contract schema version used to interpret this handle payload.
     */
    schemaVersion: "1.0";
    /**
     * Wall-clock time the stream run was opened, in Unix epoch milliseconds.
     */
    startedAt: number;
    [property: string]: unknown;
}
