import type { HttpRequest, HttpResponse, TelemetryEvent } from "./generated/index.js";

/**
 * Service to inspect and monitor network connectivity status.
 */
export interface ConnectivityService {
  /**
   * Resolves to true if the host is connected to the network, false otherwise.
   */
  isOnline(): Promise<boolean>;
}

/**
 * Operating system thermal states denoting system heat and throttling risk.
 */
export type ThermalState = "nominal" | "fair" | "serious" | "critical";

/**
 * Service to inspect host device battery, power, and thermal constraints.
 */
export interface DeviceConstraintsService {
  /**
   * Retrieves the current thermal state of the device, if supported.
   */
  getThermalState?(): Promise<ThermalState>;
  /**
   * Checks if the host device has low power mode enabled, if supported.
   */
  isLowPowerModeEnabled?(): Promise<boolean>;
}

/**
 * Secure storage interface to store and retrieve sensitive credentials/tokens
 * without exposing them to request payloads.
 */
export interface SecureStorageService {
  /**
   * Gets a secret by its unique slot identifier.
   */
  getSecret(slotId: string): Promise<string | null>;
  /**
   * Securely saves a secret under a unique slot identifier.
   */
  setSecret(slotId: string, secret: string): Promise<void>;
  /**
   * Deletes a secret by its slot identifier.
   */
  deleteSecret(slotId: string): Promise<void>;
}

/**
 * Service providing clocks for request timeouts and execution timing telemetry.
 */
export interface ClockService {
  /**
   * Returns current UNIX timestamp in milliseconds.
   */
  now(): number;
  /**
   * Returns monotonic high-resolution time in milliseconds.
   */
  monotonicNow?(): number;
}

export type { HttpRequest, HttpResponse, TelemetryEvent } from "./generated/index.js";

/**
 * HttpClient service for cloud provider communication.
 */
export interface HttpClientService {
  /**
   * Dispatches a normalized HTTP request and returns the normalized response.
   * @param request - Configuration options for the HTTP request.
   */
  send(request: HttpRequest): Promise<HttpResponse>;
}

/**
 * The structural subset of the standard `AbortSignal` that IndeRun relies on.
 *
 * The contracts package targets a platform-neutral library surface and so has
 * no DOM lib; a real `AbortSignal` satisfies this shape, so host implementations
 * and callers can pass one directly.
 */
export interface AbortSignalLike {
  /**
   * Whether cancellation has already been requested.
   */
  readonly aborted: boolean;
  /**
   * Registers a cancellation listener.
   */
  addEventListener(type: "abort", listener: () => void, options?: { once?: boolean }): void;
  /**
   * Removes a previously registered cancellation listener.
   */
  removeEventListener(type: "abort", listener: () => void): void;
}

/**
 * A streamed HTTP response: the status line and headers are resolved first, and
 * the body is delivered incrementally as raw byte chunks.
 *
 * The head is deliberately separated from the body so a caller can classify a
 * non-2xx response (mapping it through the normal HTTP error taxonomy) before
 * deciding to interpret the body as a protocol stream. Chunk boundaries are
 * transport artifacts and carry no meaning: a chunk may split a protocol frame
 * or even a multi-byte UTF-8 sequence, so consumers must buffer and decode
 * incrementally rather than treating a chunk as a unit.
 */
export interface HttpStreamResponse {
  /**
   * HTTP status code.
   */
  status: number;
  /**
   * HTTP status text.
   */
  statusText: string;
  /**
   * Response headers, with lower-cased names.
   */
  headers: Record<string, string>;
  /**
   * The response body as an incremental sequence of raw byte chunks. Iterating
   * it to completion, or abandoning it, releases the underlying connection.
   */
  body: AsyncIterable<Uint8Array>;
}

/**
 * Optional host capability for HTTP responses that must be consumed while they
 * are still arriving — the transport requirement behind Mode 2 streaming over
 * the network (for example server-sent events).
 *
 * It is a separate service rather than a method on {@link HttpClientService}
 * because it is genuinely optional: a host that cannot stream simply omits it,
 * and providers report that as `streamingAvailable: false` in their dynamic
 * capabilities, which the route planner turns into an inspectable
 * `streaming_unavailable` rejection.
 */
export interface HttpStreamingClientService {
  /**
   * Dispatches a normalized HTTP request and resolves once the response head is
   * available, leaving the body to be consumed incrementally.
   *
   * `HttpRequest.timeoutMs` bounds the wait for the response head only — the
   * time to first byte. It cannot bound total duration, since a stream is
   * open-ended by nature; use `signal` to stop a stream that runs too long.
   *
   * @param request - Normalized HTTP request payload.
   * @param signal - Optional caller-driven cancellation. Aborting it must tear
   * down the underlying connection and cause the body iterator to stop.
   */
  stream(request: HttpRequest, signal?: AbortSignalLike): Promise<HttpStreamResponse>;
}

export type TelemetryEventType = TelemetryEvent["type"];

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
 * Registry of platform-specific host services utilized by the Engine Core.
 * Evaluates execution capabilities and manages OS-level boundaries.
 */
export interface HostServices {
  /**
   * Network connectivity service.
   */
  connectivity: ConnectivityService;
  /**
   * Device constraints service.
   */
  deviceConstraints?: DeviceConstraintsService;
  /**
   * Secure storage service.
   */
  secureStorage?: SecureStorageService;
  /**
   * Clock service.
   */
  clock?: ClockService;
  /**
   * HTTP Client service for performing network requests.
   */
  httpClient?: HttpClientService;
  /**
   * HTTP client service for responses consumed while still arriving. Absent on
   * hosts that cannot stream a response body.
   */
  streamingHttpClient?: HttpStreamingClientService;
  /**
   * Telemetry service to monitor execution steps, latency, and success rates.
   */
  telemetry?: TelemetryService;
}
