/**
 * Types of telemetry events emitted by the orchestrator.
 * - 'route_decided': Fired once the routing engine resolves a candidate provider.
 * - 'attempt_succeeded': Fired when the selected provider runs and returns successfully.
 * - 'attempt_failed': Fired if the orchestrator fails at validation, routing, or provider execution.
 */
export type TelemetryEventType =
  | "route_decided"
  | "attempt_succeeded"
  | "attempt_failed";

/**
 * Normalized telemetry event structure emitted by the orchestrator.
 */
export interface TelemetryEvent {
  /**
   * The type of the telemetry event.
   */
  type: TelemetryEventType;
  /**
   * Unique execution run ID.
   */
  runId: string;
  /**
   * UNIX timestamp in milliseconds when the event was generated.
   */
  timestamp: number;
  /**
   * Rich event payload details containing specific event metadata.
   */
  payload: Record<string, unknown>;
}

/**
 * Telemetry service listener hook interface.
 */
export interface TelemetryService {
  /**
   * Emits a telemetry event.
   * @param event - The generated telemetry event.
   */
  emit(event: TelemetryEvent): void;
}

/**
 * Default no-op telemetry handler that discards all events.
 */
export class NoOpTelemetryService implements TelemetryService {
  /**
   * Discards the telemetry event.
   * @param _event - The telemetry event to discard.
   */
  emit(_event: TelemetryEvent): void {
    // No-op
  }
}
