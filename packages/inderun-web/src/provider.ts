/**
 * Provider-authoring and host-integration entry point
 * (`@independo/inderun-web/provider`).
 *
 * For code that extends the engine rather than calls it: custom provider
 * adapters, custom host services (transport, credential storage, clock), and
 * assembling an `IndeRun` by hand from a `ProviderRegistry`. Applications that
 * only call `generateText` / `streamText` or `run()` / `stream()` need nothing
 * from here. Changes to this surface are called out in release notes.
 */

/**
 * Host services: the platform capabilities the engine reads and calls through,
 * and the seams an embedder overrides to supply its own.
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

/** Holds the provider adapters a given engine instance can route to. */
export { ProviderRegistry } from "./core/registry.js";

/**
 * Constructors for the normalized error taxonomy. A provider maps every failure
 * onto one of these classes; the engine does the rest.
 */
export {
  type IndeRunExceptionParams,
  createCapabilityMismatch,
  createOffline,
  createAuthError,
  createRateLimited,
  createTimeout,
  createUnavailable,
  createInternal
} from "./core/errors.js";
