import type { TelemetryEvent } from "@independo/inderun-web";

/**
 * Narrow view of the `route_decided` telemetry event payload the advanced routing panel reads.
 * The contract-level `TelemetryEvent.payload` is untyped, so fields are read defensively. The
 * simplification flow does not use this: it reads `ExecutionProvenance` instead.
 */
export interface RouteDecidedPayload {
  selectedProviderId: string | null;
  fallbackProviderIds: string[];
  rejectedProviders: Array<{
    providerId: string;
    reasons: Array<{ code: string; message: string }>;
  }>;
  /** The planner's summary; the engine emits it as a plain string. */
  explanation: string;
  constraints: Record<string, unknown> | null;
  preferences: Record<string, unknown> | null;
}

export function toRouteDecidedPayload(
  payload: Record<string, unknown>
): RouteDecidedPayload | undefined {
  if (typeof payload !== "object" || payload === null) {
    return undefined;
  }

  const rejectedProviders = Array.isArray(payload.rejectedProviders)
    ? (payload.rejectedProviders as RouteDecidedPayload["rejectedProviders"])
    : [];

  return {
    selectedProviderId:
      typeof payload.selectedProviderId === "string" ? payload.selectedProviderId : null,
    fallbackProviderIds: Array.isArray(payload.fallbackProviderIds)
      ? (payload.fallbackProviderIds as string[])
      : [],
    rejectedProviders,
    explanation: typeof payload.explanation === "string" ? payload.explanation : "",
    constraints: (payload.constraints as Record<string, unknown> | null) ?? null,
    preferences: (payload.preferences as Record<string, unknown> | null) ?? null
  };
}

export class RouteDecisionTelemetryService {
  private lastRouteDecision: RouteDecidedPayload | undefined;

  emit(event: TelemetryEvent): void {
    if (event.type !== "route_decided") {
      return;
    }

    this.lastRouteDecision = toRouteDecidedPayload(event.payload as Record<string, unknown>);
  }

  getLastRouteDecision(): RouteDecidedPayload | undefined {
    return this.lastRouteDecision;
  }
}
