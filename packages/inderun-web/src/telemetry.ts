import type { TelemetryEvent, TelemetryService } from "@independo/inderun-contracts";

export type {
  TelemetryEvent,
  TelemetryEventType,
  TelemetryService
} from "@independo/inderun-contracts";

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
