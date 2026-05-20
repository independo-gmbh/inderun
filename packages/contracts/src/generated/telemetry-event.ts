/* This file was generated from JSON Schema. Do not edit by hand. */

/**
 * Normalized telemetry event emitted by the orchestrator and providers.
 */
export interface TelemetryEvent {
  /**
   * Telemetry event kind emitted by the orchestrator or provider integration.
   */
  type: "route_decided" | "attempt_succeeded" | "attempt_failed";
  /**
   * Opaque run identifier associated with this execution event.
   */
  runId: string;
  /**
   * Wall-clock event timestamp in Unix epoch milliseconds.
   */
  timestamp: number;
  /**
   * Event-specific metadata. It must not contain prompt payloads or raw secrets.
   */
  payload: {
    [k: string]: unknown;
  };
  [k: string]: unknown;
}
