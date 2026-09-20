import type {
  ClockService,
  ConnectivityService,
  HostServices,
  HttpClientService,
  HttpRequest,
  HttpResponse,
  HttpStreamResponse,
  HttpStreamingClientService
} from "./host.js";

/**
 * Configuration for the fetch-backed HTTP host service.
 */
export interface FetchHttpClientOptions {
  /**
   * Optional fetch implementation. Useful for tests, SSR-like environments, or custom wrappers.
   */
  fetchFn?: typeof fetch;
}

/**
 * Browser connectivity service based on `navigator.onLine`.
 */
export class BrowserConnectivityService implements ConnectivityService {
  /**
   * Returns the browser's current online hint.
   * Non-browser environments are treated as online so injected HTTP clients can still run in tests.
   */
  async isOnline(): Promise<boolean> {
    if (typeof navigator === "undefined") {
      return true;
    }

    return navigator.onLine;
  }
}

/**
 * Clock service using wall-clock time and the browser performance timer when available.
 */
export class SystemClockService implements ClockService {
  /**
   * Returns current Unix epoch time in milliseconds.
   */
  now(): number {
    return Date.now();
  }

  /**
   * Returns monotonic milliseconds from `performance.now()` when available.
   */
  monotonicNow(): number {
    if (typeof performance === "undefined") {
      return Date.now();
    }

    return performance.now();
  }
}

/**
 * HTTP client service that adapts the platform `fetch` API to IndeRun's normalized HTTP contract.
 */
export class FetchHttpClient implements HttpClientService {
  private readonly fetchFn: typeof fetch;

  /**
   * Creates a fetch-backed HTTP client.
   * @param options - Optional fetch implementation override.
   * @throws Error when no fetch implementation is available.
   */
  constructor(options: FetchHttpClientOptions = {}) {
    const fetchFn = options.fetchFn ?? globalThis.fetch?.bind(globalThis);
    if (!fetchFn) {
      throw new Error("FetchHttpClient requires a fetch implementation.");
    }

    this.fetchFn = fetchFn;
  }

  /**
   * Sends a normalized HTTP request using `fetch`.
   * @param request - Normalized HTTP request payload.
   * @returns Normalized HTTP response payload with lower-cased response header names.
   */
  async send(request: HttpRequest): Promise<HttpResponse> {
    const controller = typeof AbortController === "undefined" ? undefined : new AbortController();
    let timeoutId: ReturnType<typeof setTimeout> | undefined;

    if (controller && request.timeoutMs !== undefined) {
      timeoutId = setTimeout(() => controller.abort(), request.timeoutMs);
    }

    try {
      const init: RequestInit = {
        method: request.method
      };

      if (request.headers) {
        init.headers = request.headers;
      }
      if (request.body !== undefined) {
        init.body = request.body;
      }
      if (controller) {
        init.signal = controller.signal;
      }

      const response = await this.fetchFn(request.url, init);

      const headers: Record<string, string> = {};
      response.headers.forEach((value, key) => {
        headers[key.toLowerCase()] = value;
      });

      return {
        status: response.status,
        statusText: response.statusText,
        headers,
        body: await response.text()
      };
    } finally {
      if (timeoutId !== undefined) {
        clearTimeout(timeoutId);
      }
    }
  }
}

/**
 * Streaming HTTP client service that adapts `fetch` to IndeRun's incremental
 * HTTP contract by handing back `Response.body` rather than buffering it.
 *
 * Two abort sources are merged onto one controller: `timeoutMs`, which bounds
 * only the wait for the response head, and the caller's `signal`, which stays
 * live for the whole body. The timeout timer is therefore cleared as soon as
 * the head resolves — a stream that legitimately stays open for minutes must
 * not be killed by a time-to-first-byte budget.
 */
export class FetchStreamingHttpClient implements HttpStreamingClientService {
  private readonly fetchFn: typeof fetch;

  /**
   * Creates a fetch-backed streaming HTTP client.
   * @param options - Optional fetch implementation override.
   * @throws Error when no fetch implementation is available.
   */
  constructor(options: FetchHttpClientOptions = {}) {
    const fetchFn = options.fetchFn ?? globalThis.fetch?.bind(globalThis);
    if (!fetchFn) {
      throw new Error("FetchStreamingHttpClient requires a fetch implementation.");
    }

    this.fetchFn = fetchFn;
  }

  /**
   * Sends a normalized HTTP request and resolves once the response head is available.
   * @param request - Normalized HTTP request payload.
   * @param signal - Optional caller-driven cancellation covering the whole response.
   * @returns Response head plus a lazily-consumed body chunk sequence.
   */
  async stream(request: HttpRequest, signal?: AbortSignal): Promise<HttpStreamResponse> {
    const controller = typeof AbortController === "undefined" ? undefined : new AbortController();
    let timeoutId: ReturnType<typeof setTimeout> | undefined;
    let onAbort: (() => void) | undefined;

    if (controller) {
      if (request.timeoutMs !== undefined) {
        timeoutId = setTimeout(() => controller.abort(), request.timeoutMs);
      }
      if (signal) {
        if (signal.aborted) {
          controller.abort();
        } else {
          onAbort = () => controller.abort();
          signal.addEventListener("abort", onAbort, { once: true });
        }
      }
    }

    const clearTimeoutTimer = () => {
      if (timeoutId !== undefined) {
        clearTimeout(timeoutId);
        timeoutId = undefined;
      }
    };
    const releaseAbortListener = () => {
      if (signal && onAbort) {
        signal.removeEventListener("abort", onAbort);
        onAbort = undefined;
      }
    };

    let response: Response;
    try {
      const init: RequestInit = { method: request.method };
      if (request.headers) {
        init.headers = request.headers;
      }
      if (request.body !== undefined) {
        init.body = request.body;
      }
      if (controller) {
        init.signal = controller.signal;
      }

      response = await this.fetchFn(request.url, init);
    } catch (error) {
      clearTimeoutTimer();
      releaseAbortListener();
      throw error;
    }

    clearTimeoutTimer();

    const headers: Record<string, string> = {};
    response.headers.forEach((value, key) => {
      headers[key.toLowerCase()] = value;
    });

    const stream = response.body;

    async function* iterate(): AsyncGenerator<Uint8Array> {
      try {
        if (!stream) {
          // A bodyless response (204, HEAD) or a fetch polyfill without stream
          // support: fall back to the buffered text so callers still terminate.
          const text = await response.text();
          if (text.length > 0) {
            yield new TextEncoder().encode(text);
          }
          return;
        }

        const reader = stream.getReader();
        // The body is also raced against `signal` directly, not just against the
        // fetch-level abort: a fetch implementation is free not to error an
        // in-flight body when its request signal fires, and the caller's
        // cancellation guarantee must not depend on that.
        let onBodyAbort: (() => void) | undefined;
        const aborted = new Promise<never>((_resolve, reject) => {
          if (!signal) return;
          onBodyAbort = () =>
            reject(Object.assign(new Error("The stream was aborted."), { name: "AbortError" }));
          if (signal.aborted) {
            onBodyAbort();
          } else {
            signal.addEventListener("abort", onBodyAbort, { once: true });
          }
        });
        // Keeps an abort that arrives after the body finished from surfacing as
        // an unhandled rejection; the race below still observes it.
        void aborted.catch(() => undefined);

        try {
          for (;;) {
            const { done, value } = await Promise.race([reader.read(), aborted]);
            if (done) return;
            if (value) yield value;
          }
        } catch (error) {
          await reader.cancel().catch(() => undefined);
          throw error;
        } finally {
          if (signal && onBodyAbort) {
            signal.removeEventListener("abort", onBodyAbort);
          }
          reader.releaseLock();
        }
      } finally {
        releaseAbortListener();
      }
    }

    return {
      status: response.status,
      statusText: response.statusText,
      headers,
      body: iterate()
    };
  }
}

/**
 * Options for constructing default browser host services.
 */
export interface CreateBrowserHostServicesOptions extends Partial<HostServices> {
  /**
   * Optional fetch implementation used when `httpClient`/`streamingHttpClient`
   * are not supplied.
   */
  fetchFn?: typeof fetch;
}

/**
 * Creates a browser-oriented HostServices bundle for the Web SDK.
 * Supplied host services override the defaults; missing connectivity, clock, and HTTP services are created.
 * @param options - Optional host service overrides and fetch implementation.
 */
export function createBrowserHostServices(
  options: CreateBrowserHostServicesOptions = {}
): HostServices {
  const hostServices: HostServices = {
    connectivity: options.connectivity ?? new BrowserConnectivityService()
  };

  hostServices.clock = options.clock ?? new SystemClockService();
  if (options.httpClient) {
    hostServices.httpClient = options.httpClient;
  } else if (options.fetchFn) {
    hostServices.httpClient = new FetchHttpClient({ fetchFn: options.fetchFn });
  } else {
    hostServices.httpClient = new FetchHttpClient();
  }

  if (options.streamingHttpClient) {
    hostServices.streamingHttpClient = options.streamingHttpClient;
  } else if (options.fetchFn) {
    hostServices.streamingHttpClient = new FetchStreamingHttpClient({ fetchFn: options.fetchFn });
  } else {
    hostServices.streamingHttpClient = new FetchStreamingHttpClient();
  }

  if (options.deviceConstraints) {
    hostServices.deviceConstraints = options.deviceConstraints;
  }

  if (options.secureStorage) {
    hostServices.secureStorage = options.secureStorage;
  }

  if (options.telemetry) {
    hostServices.telemetry = options.telemetry;
  }

  return hostServices;
}
