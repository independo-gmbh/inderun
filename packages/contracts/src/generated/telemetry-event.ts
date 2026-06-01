/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

/**
 * Normalized telemetry event emitted by the orchestrator and providers.
 */
export type TelemetryEvent = {
    /**
     * Event-specific metadata. It must not contain prompt payloads or raw secrets.
     */
    payload: { [key: string]: unknown };
    /**
     * Opaque run identifier associated with this execution event.
     */
    runId: string;
    /**
     * Wall-clock event timestamp in Unix epoch milliseconds.
     */
    timestamp: number;
    /**
     * Telemetry event kind emitted by the orchestrator or provider integration.
     */
    type: Type;
    [property: string]: unknown;
}

/**
 * Telemetry event kind emitted by the orchestrator or provider integration.
 */
export type Type = "route_decided" | "attempt_succeeded" | "attempt_failed";
