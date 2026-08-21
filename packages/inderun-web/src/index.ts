export {
  type ConnectivityService,
  type DeviceConstraintsService,
  type SecureStorageService,
  type ClockService,
  type HttpClientService,
  type HttpRequest,
  type HttpResponse,
  type HostServices,
  type ThermalState
} from "./core/host.js";

export {
  type ProviderDescriptor,
  type ProviderDynamicCapabilities,
  type ProviderCapabilitySnapshot,
  type RunContext,
  type ProviderAdapter,
  type ProviderStreamContext,
  type ProviderStreamEvent
} from "./core/provider.js";

export { EventGate } from "./core/event-gate.js";

export { ProviderRegistry } from "./core/registry.js";

export { type RouteSelection, Router } from "./core/router.js";
export {
  type RoutePlanner,
  type PlannerOutcome,
  type WasmUnavailableReason,
  type SharedPlannerInput,
  type SharedPlannerRoutePlan,
  WasmRoutePlanner
} from "./core/route-planner.js";

export {
  type IndeRunExceptionParams,
  IndeRunException,
  createCapabilityMismatch,
  createOffline,
  createAuthError,
  createRateLimited,
  createTimeout,
  createUnavailable,
  createInternal,
  toIndeRunException
} from "./core/errors.js";

export { IndeRun, type StreamHandleResult } from "./core/engine.js";
export type { IndeRunApi } from "./core/generated/inderun-api.js";

export {
  type TelemetryEventType,
  type TelemetryEvent,
  type TelemetryService,
  NoOpTelemetryService
} from "./core/telemetry.js";

export {
  BrowserConnectivityService,
  FetchHttpClient,
  SystemClockService,
  createBrowserHostServices,
  type CreateBrowserHostServicesOptions,
  type FetchHttpClientOptions
} from "./core/browser-host.js";

export { createIndeRunWeb, type CreateIndeRunWebOptions } from "./web-sdk.js";

// The OpenAI Responses adapter is provider-specific and intentionally excluded
// from this unified index. Import it from "@independo/inderun-web/openai".
