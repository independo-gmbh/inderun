/**
 * Unified entry point for the IndeRun Web SDK (`@independo/inderun-web`).
 *
 * Everything a browser app needs to run and stream tasks is exported from here:
 * the engine, the routing and provider seams, host services, error and telemetry
 * types, and the contract types the SDK's own signatures use. Provider adapters
 * are the deliberate exception — each ships from its own subpath
 * (`/openai`, `/onnx`, `/system-model`) so this surface stays provider-agnostic.
 */

/**
 * Host services: the platform capabilities the engine reads and calls through,
 * and the seams an embedder overrides to supply its own (custom transport,
 * credential storage, clock).
 */
export {
  type AbortSignalLike,
  type ConnectivityService,
  type DeviceConstraintsService,
  type SecureStorageService,
  type ClockService,
  type HttpClientService,
  type HttpRequest,
  type HttpResponse,
  type HttpStreamResponse,
  type HttpStreamingClientService,
  type HostServices,
  type ThermalState
} from "./core/host.js";

/**
 * The provider contract. Implement `ProviderAdapter` for a Mode 1 backend and add
 * a `stream` for Mode 2; the descriptor and dynamic capability check are what the
 * router plans against.
 */
export {
  type ProviderDescriptor,
  type ProviderDynamicCapabilities,
  type ProviderCapabilitySnapshot,
  type RunContext,
  type ProviderAdapter,
  type ProviderStreamContext,
  type ProviderStreamEvent,
  type StreamRun
} from "./core/provider.js";

/**
 * Per-run gatekeeper for a Mode 2 stream: assigns the sequence numbers callers
 * order by, and enforces that exactly one terminal outcome is produced with
 * nothing admitted after it. Exported for embedders driving a stream themselves.
 */
export { EventGate } from "./core/event-gate.js";

/** Holds the provider adapters a given engine instance can route to. */
export { ProviderRegistry } from "./core/registry.js";

/**
 * Route selection. `Router` turns a request plus a host capability snapshot into
 * a provider chain; `WasmRoutePlanner` is the shared Rust planner behind it, and
 * the only planner the Web SDK has — there is no JavaScript fallback.
 */
export { type RouteSelection, Router } from "./core/router.js";
export {
  type RoutePlanner,
  type PlannerOutcome,
  type WasmUnavailableReason,
  type SharedPlannerInput,
  type SharedPlannerRoutePlan,
  WasmRoutePlanner
} from "./core/route-planner.js";

/**
 * The normalized error taxonomy. Every failure the SDK surfaces is an
 * `IndeRunException` in one of these classes, whatever the provider raised.
 */
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

/** The engine itself, and the app-facing API surface it implements. */
export { IndeRun, type StreamHandleResult } from "./core/engine.js";
export type { IndeRunApi } from "./core/generated/inderun-api.js";

/**
 * The contract types this SDK's own signatures take and return.
 *
 * Re-exported so a typed app needs only the one dependency the README tells it to
 * install. `@independo/inderun-contracts` is ours transitively, and under pnpm's
 * isolated `node_modules` an undeclared import of it does not resolve at all.
 * This is the npm counterpart of Gradle `api(...)` on Android and `@_exported
 * import` on Swift — see
 * {@link https://github.com/independo-gmbh/inderun/issues/189 | #189}. The
 * host-service and telemetry blocks in this file re-export their halves of the
 * same contract surface for the same reason.
 *
 * Depend on `@independo/inderun-contracts` directly only for what is not
 * re-exported here: the JSON Schemas and the `get*ValidationIssues` validators.
 */
export type {
  IndeRunError,
  IndeRunErrorClass,
  StreamEvent,
  StreamRunHandle,
  StreamTerminalOutcome,
  TaskRequest,
  TaskResult
} from "@independo/inderun-contracts";

/**
 * Telemetry. Pass a `TelemetryService` to observe routing decisions and attempt
 * outcomes; the engine defaults to `NoOpTelemetryService`.
 */
export {
  type TelemetryEventType,
  type TelemetryEvent,
  type TelemetryService,
  NoOpTelemetryService
} from "./core/telemetry.js";

/**
 * The browser implementations of the host services above, and the factory that
 * assembles them. Use these directly only when constructing `IndeRun` by hand.
 */
export {
  BrowserConnectivityService,
  FetchHttpClient,
  FetchStreamingHttpClient,
  SystemClockService,
  createBrowserHostServices,
  type CreateBrowserHostServicesOptions,
  type FetchHttpClientOptions
} from "./core/browser-host.js";

/**
 * The recommended way in: builds host services, registers the providers named in
 * the options, and returns a ready engine.
 */
export { createIndeRunWeb, type CreateIndeRunWebOptions } from "./web-sdk.js";
