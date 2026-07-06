import type {
  ClockService,
  ConnectivityService,
  HostServices,
  HttpClientService,
  HttpRequest,
  HttpResponse
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
 * Options for constructing default browser host services.
 */
export interface CreateBrowserHostServicesOptions extends Partial<HostServices> {
  /**
   * Optional fetch implementation used when `httpClient` is not supplied.
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
