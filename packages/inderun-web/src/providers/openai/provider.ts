import type { TaskRequest, TaskResult } from "@independo/inderun-contracts";
import {
  createAuthError,
  createInternal,
  createRateLimited,
  createTimeout,
  createUnavailable,
  type IndeRunExceptionParams
} from "../../core/errors.js";
import type { HostServices, HttpRequest } from "../../core/host.js";
import type {
  ProviderAdapter,
  ProviderDescriptor,
  ProviderDynamicCapabilities,
  ProviderStreamContext,
  ProviderStreamEvent,
  RunContext
} from "../../core/provider.js";
import { parseSseStream } from "../../core/sse.js";

/**
 * The subset of the Responses API's server-sent event payloads this adapter
 * reads. The event set is open and additive, so unknown fields and unknown
 * types are ignored rather than treated as errors.
 */
interface OpenAIStreamEvent {
  type?: string;
  delta?: string;
  response?: OpenAIResponseBody;
  error?: OpenAIReportedError;
  /** Root-level failure fields, as carried by the standalone `error` event. */
  message?: string;
  code?: unknown;
}

/**
 * A failure reported inside a response body or stream event. `code` is a string
 * on OpenAI and the numeric HTTP status on OpenRouter, so it is read as either.
 */
interface OpenAIReportedError {
  message?: string | undefined;
  type?: string | undefined;
  code?: unknown;
  /** OpenRouter's typed classification on an untyped (chat-completions-shaped) error event. */
  metadata?: { error_type?: unknown } | undefined;
}

type ErrorParams = Omit<IndeRunExceptionParams, "errorClass" | "message">;

/** Buffers a body stream to text, for error responses that are not event streams. */
async function drainToText(body: AsyncIterable<Uint8Array>): Promise<string> {
  const decoder = new TextDecoder();
  let text = "";
  for await (const chunk of body) {
    text += decoder.decode(chunk, { stream: true });
  }
  return text + decoder.decode();
}

export const DEFAULT_OPENAI_RESPONSES_ENDPOINT = "https://api.openai.com/v1/responses";

const DEFAULT_HEALTH_CHECK_TIMEOUT_MS = 3000;
const DEFAULT_HEALTH_CHECK_CACHE_MS = 5000;

/**
 * Configuration for the OpenAI Responses provider.
 */
export interface OpenAIProviderOptions {
  /**
   * Provider id exposed in telemetry and routing explanations.
   */
  id?: string;
  /**
   * OpenAI model id sent to the Responses API.
   */
  model: string;
  /**
   * Responses-compatible endpoint. Use a same-origin proxy endpoint in browser apps.
   */
  endpointUrl?: string;
  /**
   * Authentication mode. Use "none" for browser proxy endpoints that resolve
   * OpenAI credentials server-side.
   */
  auth?: "authContextRef" | "none";
  /**
   * Default secure-storage slot used when the request does not provide authContextRef.
   */
  authContextRef?: string;
  /**
   * Optional HTTP timeout for the host transport attempt.
   */
  timeoutMs?: number;
  /**
   * Timeout for the endpoint reachability probe issued from `capabilities()`.
   * Defaults to 3000ms. The OpenAI API has no dedicated health endpoint, so this
   * is a cheap unauthenticated `GET` against the configured endpoint.
   */
  healthCheckTimeoutMs?: number;
  /**
   * How long a reachability probe result is cached before `capabilities()` re-probes.
   * Defaults to 5000ms. Avoids re-probing on every routing decision and UI capability check.
   */
  healthCheckCacheMs?: number;
}

type OpenAIResponseBody = {
  model?: unknown;
  output_text?: unknown;
  output?: unknown;
  status?: unknown;
  usage?: {
    input_tokens?: unknown;
    output_tokens?: unknown;
    total_tokens?: unknown;
  };
  incomplete_details?: {
    reason?: unknown;
  };
  error?: OpenAIReportedError;
  /**
   * OpenRouter's typed classification of a failed response. It sits beside
   * `error`, whose native `code` collapses many causes into `server_error`.
   */
  error_type?: unknown;
};

type OpenAIErrorBody = {
  error?: {
    message?: unknown;
    type?: unknown;
    code?: unknown;
  };
};

/**
 * Cloud provider adapter that executes Mode-1 text-to-text requests through the OpenAI Responses API.
 *
 * Browser applications should prefer a same-origin proxy endpoint with `auth: "none"` so OpenAI credentials
 * stay server-side. Direct OpenAI authentication is available through `authContextRef` and `SecureStorageService`
 * for controlled environments.
 */
export class OpenAIResponsesProvider implements ProviderAdapter {
  private readonly id: string;
  private readonly endpointUrl: string;
  private readonly auth: "authContextRef" | "none";
  private cachedHealth?: { result: ProviderDynamicCapabilities; checkedAt: number };

  /**
   * Creates an OpenAI Responses provider.
   * @param options - Provider configuration, including required OpenAI model id.
   */
  constructor(private readonly options: OpenAIProviderOptions) {
    this.id = options.id ?? "openai";
    this.endpointUrl = options.endpointUrl ?? DEFAULT_OPENAI_RESPONSES_ENDPOINT;
    this.auth = options.auth ?? "authContextRef";
  }

  /**
   * Returns static metadata used by the router for deterministic provider selection.
   */
  describe(): ProviderDescriptor {
    return {
      id: this.id,
      type: "cloud",
      model: this.options.model,
      transport: "http",
      streamingStyle: "tokens",
      supports: {
        run: true,
        streaming: true,
        realtime: false,
        tools: false,
        reasoningEvents: false,
        structuredOutput: false,
        multimodal: false
      },
      cancel: "hard",
      tasks: ["text_to_text"],
      privacy: {
        dataLeavesDevice: true
      }
    };
  }

  /**
   * Reports dynamic provider availability for the current host.
   *
   * After the static host-service checks pass, this probes endpoint reachability with a
   * cheap unauthenticated `GET` against the configured endpoint (the OpenAI API has no
   * dedicated health endpoint). The result is cached for `healthCheckCacheMs` so routing
   * decisions and repeated UI capability checks don't re-probe on every call.
   * @param host - Host services available to the engine.
   */
  async capabilities(host: HostServices): Promise<ProviderDynamicCapabilities> {
    if (!host.httpClient) {
      return {
        available: false,
        reason: "OpenAI Responses provider requires an HttpClientService."
      };
    }

    if (this.auth !== "none" && !host.secureStorage) {
      return {
        available: false,
        reason: "OpenAI Responses provider requires a SecureStorageService when auth is enabled."
      };
    }

    const reachability = await this.checkEndpointReachable(host.httpClient, host.clock);
    if (host.streamingHttpClient) {
      return reachability;
    }

    // Mode 1 still works without it; only streaming is taken away, and the
    // planner turns this into an inspectable `streaming_unavailable` rejection
    // rather than an unexplained routing failure.
    return {
      ...reachability,
      streamingAvailable: false,
      streamingUnavailableReason:
        "Host does not provide an HttpStreamingClientService, which OpenAI streaming requires."
    };
  }

  private async checkEndpointReachable(
    httpClient: NonNullable<HostServices["httpClient"]>,
    clock: HostServices["clock"]
  ): Promise<ProviderDynamicCapabilities> {
    const now = clock ? clock.now() : Date.now();
    const cacheMs = this.options.healthCheckCacheMs ?? DEFAULT_HEALTH_CHECK_CACHE_MS;

    if (this.cachedHealth && now - this.cachedHealth.checkedAt < cacheMs) {
      return this.cachedHealth.result;
    }

    let result: ProviderDynamicCapabilities;
    try {
      const response = await httpClient.send({
        method: "GET",
        url: this.endpointUrl,
        timeoutMs: this.options.healthCheckTimeoutMs ?? DEFAULT_HEALTH_CHECK_TIMEOUT_MS
      });

      result =
        response.status >= 500
          ? {
              available: false,
              reason: `OpenAI Responses endpoint returned HTTP ${response.status}.`
            }
          : { available: true };
    } catch (err) {
      result = {
        available: false,
        reason: isAbortError(err)
          ? "OpenAI Responses endpoint health check timed out."
          : "OpenAI Responses endpoint is unreachable."
      };
    }

    this.cachedHealth = { result, checkedAt: now };
    return result;
  }

  /**
   * Executes a normalized text-to-text task using the OpenAI Responses API.
   * @param request - Canonical IndeRun task request.
   * @param context - Engine execution context containing run id and host services.
   * @returns Normalized IndeRun task result.
   * @throws IndeRunException mapped to the standard error taxonomy.
   */
  async run(request: TaskRequest, context: RunContext): Promise<TaskResult> {
    const httpClient = context.hostServices.httpClient;
    if (!httpClient) {
      throw createUnavailable("OpenAI Responses provider requires an HTTP client.", {
        providerId: this.id,
        runId: context.runId
      });
    }

    const headers = await this.resolveHeaders(request, context);

    let response;
    try {
      const httpRequest: HttpRequest = {
        method: "POST",
        url: this.endpointUrl,
        headers,
        body: JSON.stringify(this.createRequestBody(request))
      };

      if (this.options.timeoutMs !== undefined) {
        httpRequest.timeoutMs = this.options.timeoutMs;
      }

      response = await httpClient.send(httpRequest);
    } catch (err) {
      if (isAbortError(err)) {
        throw createTimeout("OpenAI Responses request timed out.", {
          providerId: this.id,
          runId: context.runId
        });
      }

      throw createUnavailable("OpenAI Responses request failed before a response was received.", {
        providerId: this.id,
        runId: context.runId,
        details: { originalError: getErrorSummary(err) }
      });
    }

    if (response.status < 200 || response.status >= 300) {
      throw this.mapHttpError(
        response.status,
        response.statusText,
        response.headers,
        response.body,
        context
      );
    }

    const responseBody = parseJson<OpenAIResponseBody>(response.body);
    // A lenient server (OpenRouter among them) can answer 2xx for a run that
    // failed upstream; that is a failure to classify, not an empty answer.
    if (responseBody.status === "failed" || responseBody.status === "cancelled") {
      throw this.mapReportedError(
        responseBody.error,
        `OpenAI Responses run ended with status '${responseBody.status}'.`,
        context,
        responseBody.error_type
      );
    }

    const outputText = extractOutputText(responseBody);
    if (outputText === undefined && isRecord(responseBody.error)) {
      throw this.mapReportedError(
        responseBody.error,
        "OpenAI Responses payload reported an error.",
        context,
        responseBody.error_type
      );
    }
    if (outputText === undefined) {
      throw createInternal("OpenAI Responses payload did not contain text output.", {
        providerId: this.id,
        runId: context.runId
      });
    }

    const result: TaskResult = {
      schemaVersion: "1.0",
      runId: context.runId,
      output: {
        type: "text",
        text: outputText
      },
      finishReason: getFinishReason(responseBody),
      telemetry: {
        providerUsed: this.id,
        totalMs: 0
      }
    };

    const reportedModel = getReportedModel(responseBody);
    if (reportedModel !== undefined) {
      result.telemetry.reportedModel = reportedModel;
    }

    const usage = getUsage(responseBody);
    if (usage) {
      result.usage = usage;
    }

    return result;
  }

  /**
   * Executes a normalized text-to-text task in Mode 2 against the OpenAI
   * Responses API's server-sent event stream.
   *
   * The request is the Mode 1 body plus `"stream": true`, so both modes stay a
   * single code path up to the transport. The response head is classified
   * before the body is read: a non-2xx is drained to text and run through the
   * same `mapHttpError` as Mode 1, because a 429 must surface as RateLimited
   * rather than as a malformed event stream.
   *
   * Event mapping, from the Responses API's typed SSE events to the canonical
   * provider vocabulary:
   *
   * - `response.output_text.delta` becomes a delta;
   * - `response.completed` and `response.incomplete` become the terminal done,
   *   with `finalText`, `usage`, and `finishReason` read off the embedded
   *   response object by the same helpers Mode 1 uses — it has the same shape;
   * - `response.failed`, `response.error` and `error` become a terminal error,
   *   as does an untyped event carrying an `error` object (OpenRouter's
   *   documented mid-stream failure shape);
   * - every other event type is ignored, since the set is open and additive.
   *
   * @param request - Canonical IndeRun task request.
   * @param context - Engine stream context: run id, host services, abort signal.
   */
  async *stream(
    request: TaskRequest,
    context: ProviderStreamContext
  ): AsyncGenerator<ProviderStreamEvent> {
    const streamingClient = context.hostServices.streamingHttpClient;
    if (!streamingClient) {
      throw createUnavailable(
        "OpenAI Responses streaming requires an HttpStreamingClientService.",
        {
          providerId: this.id,
          runId: context.runId
        }
      );
    }

    const headers = await this.resolveHeaders(request, context);
    headers.Accept = "text/event-stream";

    let response;
    try {
      const httpRequest: HttpRequest = {
        method: "POST",
        url: this.endpointUrl,
        headers,
        body: JSON.stringify(this.createRequestBody(request, true))
      };

      if (this.options.timeoutMs !== undefined) {
        httpRequest.timeoutMs = this.options.timeoutMs;
      }

      response = await streamingClient.stream(httpRequest, context.signal);
    } catch (err) {
      if (isAbortError(err)) {
        throw createTimeout("OpenAI Responses stream timed out before the first byte.", {
          providerId: this.id,
          runId: context.runId
        });
      }

      throw createUnavailable("OpenAI Responses stream failed before a response was received.", {
        providerId: this.id,
        runId: context.runId,
        details: { originalError: getErrorSummary(err) }
      });
    }

    if (response.status < 200 || response.status >= 300) {
      throw this.mapHttpError(
        response.status,
        response.statusText,
        response.headers,
        await drainToText(response.body),
        context
      );
    }

    for await (const sseEvent of parseSseStream(response.body)) {
      if (sseEvent.data === "[DONE]") {
        continue;
      }

      const parsed = parseJson<OpenAIStreamEvent>(sseEvent.data);
      // The `event:` line and the payload's own `type` carry the same value;
      // prefer the payload so a proxy that drops event names still works.
      const type = parsed.type ?? sseEvent.event;

      if (type === "response.output_text.delta") {
        if (parsed.delta) {
          yield { kind: "delta", text: parsed.delta };
        }
        continue;
      }

      if (type === "response.completed" || type === "response.incomplete") {
        const body = parsed.response ?? {};
        const done: ProviderStreamEvent = {
          kind: "done",
          finalText: extractOutputText(body) ?? "",
          finishReason: getFinishReason(body)
        };
        const usage = getUsage(body);
        if (usage) {
          done.usage = usage;
        }
        const reportedModel = getReportedModel(body);
        if (reportedModel !== undefined) {
          done.reportedModel = reportedModel;
        }
        yield done;
        return;
      }

      if (
        type === "response.failed" ||
        type === "response.error" ||
        type === "error" ||
        (type === undefined && isRecord(parsed.error))
      ) {
        yield { kind: "error", error: this.mapStreamError(parsed, context) };
        return;
      }
    }

    // Falling out of the loop means the stream ended without a terminal event.
    // The engine reports that as a provider fault; inventing a completion from
    // whatever deltas happened to arrive would hide a truncated response.
  }

  /**
   * Maps a `response.failed` / `response.error` / `error` stream event onto the
   * error taxonomy. These arrive over an HTTP 200 body, so there is no status
   * code to classify from; the event's own `code` is classified instead.
   *
   * Two payload shapes exist and both are accepted: the standalone `error`
   * event carries `code`/`message` at its root, while `response.failed` nests
   * them under `response.error` and some servers nest them under `error`. The
   * root `type` is the event name rather than an error type, so it is never
   * read as one. OpenRouter's typed classification comes from the embedded
   * response (`response.failed`) or the error's metadata (untyped events).
   */
  private mapStreamError(event: OpenAIStreamEvent, context: ProviderStreamContext): unknown {
    const nested = event.error ?? event.response?.error;
    return this.mapReportedError(
      {
        message: nested?.message ?? event.message,
        type: nested?.type,
        code: nested?.code ?? event.code
      },
      "OpenAI Responses stream reported a failure.",
      context,
      event.response?.error_type ?? nested?.metadata?.error_type
    );
  }

  /**
   * Classifies a failure reported in a body rather than by the HTTP status: a
   * failed stream event or a 2xx run body whose status is `failed`. The most
   * specific signal wins:
   * 1. OpenRouter's typed `error_type`, classified by the HTTP status it
   *    documents for that type (see `openRouterErrorTypeStatus`);
   * 2. an integer `code`, which is an HTTP status (OpenRouter's convention) and
   *    is classified exactly as `mapHttpError` classifies that status;
   * 3. a string code, by OpenAI's names.
   * Anything unrecognized is a transient `Unavailable`, since the server did
   * accept the request.
   */
  private mapReportedError(
    reported: OpenAIReportedError | undefined,
    fallbackMessage: string,
    context: RunContext,
    errorType?: unknown
  ): Error {
    const message =
      typeof reported?.message === "string" && reported.message.length > 0
        ? reported.message
        : fallbackMessage;
    const typedStatus = openRouterErrorTypeStatus(errorType);
    const details = {
      errorType: typedStatus !== undefined ? (errorType as string) : reported?.type,
      errorCode: getErrorCode(reported?.code)
    };
    const params = { providerId: this.id, runId: context.runId, details };

    if (typedStatus !== undefined) {
      return this.errorForStatus(typedStatus, message, params);
    }

    const code = reported?.code;
    if (typeof code === "number" && Number.isInteger(code)) {
      return this.errorForStatus(code, message, params);
    }

    switch (code) {
      case "rate_limit_exceeded":
        return createRateLimited(message, { ...params, retryable: true });
      case "invalid_api_key":
      case "authentication_error":
        return createAuthError(message, params);
      // The request itself was rejected; repeating it cannot succeed.
      case "invalid_prompt":
      case "image_content_policy_violation":
        return createInternal(message, params);
      default:
        return createUnavailable(message, { ...params, retryable: true });
    }
  }

  /**
   * Resolves the request headers, including the bearer token behind
   * `authContextRef`. Shared by `run` and `stream`: the credential never travels
   * in the request payload, only the slot id does, so both modes must resolve it
   * the same way.
   */
  private async resolveHeaders(
    request: TaskRequest,
    context: RunContext
  ): Promise<Record<string, string>> {
    const headers: Record<string, string> = {
      "Content-Type": "application/json"
    };

    if (this.auth !== "authContextRef") {
      return headers;
    }

    const slotId = request.authContextRef ?? this.options.authContextRef;
    if (!slotId) {
      throw createAuthError("OpenAI Responses provider requires authContextRef.", {
        providerId: this.id,
        runId: context.runId
      });
    }

    const secureStorage = context.hostServices.secureStorage;
    if (!secureStorage) {
      throw createAuthError(
        "OpenAI Responses provider requires a SecureStorageService when auth is enabled.",
        {
          providerId: this.id,
          runId: context.runId
        }
      );
    }

    const secret = await secureStorage.getSecret(slotId);
    if (!secret) {
      throw createAuthError(`No OpenAI credential found for authContextRef '${slotId}'.`, {
        providerId: this.id,
        runId: context.runId
      });
    }

    headers.Authorization = `Bearer ${secret}`;
    return headers;
  }

  private createRequestBody(request: TaskRequest, stream = false): Record<string, unknown> {
    const body: Record<string, unknown> = {
      model: this.options.model,
      input: createInput(request)
    };

    if (stream) {
      body.stream = true;
    }

    const generation = request.generation;
    if (generation?.maxOutputTokens !== undefined) {
      body.max_output_tokens = generation.maxOutputTokens;
    }
    if (generation?.temperature !== undefined) {
      body.temperature = generation.temperature;
    }
    if (generation?.topP !== undefined) {
      body.top_p = generation.topP;
    }
    if (generation?.stop !== undefined) {
      body.stop = generation.stop;
    }

    return body;
  }

  /**
   * Maps an OpenAI HTTP error response onto the IndeRun error taxonomy by its
   * status (see `errorForStatus`), honoring `Retry-After` on whichever status
   * carries it.
   */
  private mapHttpError(
    status: number,
    statusText: string,
    headers: Record<string, string>,
    body: string,
    context: RunContext
  ): Error {
    const error = parseJson<OpenAIErrorBody>(body);
    const message = getOpenAIErrorMessage(error, status, statusText);
    const params: ErrorParams = {
      providerId: this.id,
      runId: context.runId,
      details: {
        status,
        statusText,
        errorType: getString(error.error?.type),
        errorCode: getErrorCode(error.error?.code)
      }
    };

    return this.errorForStatus(status, message, params, parseRetryAfterMs(headers));
  }

  /**
   * The status classification shared by HTTP errors and numeric in-body codes:
   * - `401` / `403` → `AuthError`
   * - `402` → `Unavailable`, not retryable: the account is out of credits, so
   *   this target cannot serve until someone tops it up. A 402 that carries
   *   `Retry-After` is the exception — OpenRouter documents it for its
   *   in-flight budget limit, a wait-and-retry case — and is `RateLimited`. Fallback is unaffected
   *   either way: the engine moves on to the next target whatever the class.
   * - `429` → `RateLimited`
   * - `408` / `504` → `Timeout`
   * - `409` / `5xx` → `Unavailable`
   * - any other status → `Internal`
   *
   * `retryAfterMs` travels on every retryable class; it is absent for numeric
   * in-body codes, which have no header to read it from.
   */
  private errorForStatus(
    status: number,
    message: string,
    params: ErrorParams,
    retryAfterMs?: number
  ): Error {
    const retry: ErrorParams = { ...params, retryable: true };
    if (retryAfterMs !== undefined) {
      retry.retryAfterMs = retryAfterMs;
    }

    if (status === 401 || status === 403) {
      return createAuthError(message, params);
    }

    if (status === 402) {
      return retryAfterMs === undefined
        ? createUnavailable(message, { ...params, retryable: false })
        : createRateLimited(message, retry);
    }

    if (status === 429) {
      return createRateLimited(message, retry);
    }

    if (status === 408 || status === 504) {
      return createTimeout(message, retry);
    }

    if (status === 409 || status >= 500) {
      return createUnavailable(message, retry);
    }

    return createInternal(message, params);
  }
}

function createInput(request: TaskRequest): string | Array<Record<string, string>> {
  if (request.messages && request.messages.length > 0) {
    return request.messages.map((message) => ({
      role: message.role === "system" ? "developer" : message.role,
      content: message.content
    }));
  }

  return request.prompt ?? "";
}

function extractOutputText(response: OpenAIResponseBody): string | undefined {
  if (typeof response.output_text === "string") {
    return response.output_text;
  }

  if (!Array.isArray(response.output)) {
    return undefined;
  }

  const textParts: string[] = [];
  for (const item of response.output) {
    if (!isRecord(item) || !Array.isArray(item.content)) {
      continue;
    }

    for (const contentItem of item.content) {
      if (
        isRecord(contentItem) &&
        contentItem.type === "output_text" &&
        typeof contentItem.text === "string"
      ) {
        textParts.push(contentItem.text);
      }
    }
  }

  return textParts.length > 0 ? textParts.join("") : undefined;
}

function getFinishReason(response: OpenAIResponseBody): TaskResult["finishReason"] {
  if (response.status === "incomplete") {
    return response.incomplete_details?.reason === "max_output_tokens" ? "length" : "error";
  }

  return "stop";
}

/**
 * The model id the Responses API echoes on the response object. It names the model that
 * served the request, which can be a dated snapshot of the configured alias.
 */
function getReportedModel(responseBody: OpenAIResponseBody): string | undefined {
  return typeof responseBody.model === "string" && responseBody.model.length > 0
    ? responseBody.model
    : undefined;
}

function getUsage(response: OpenAIResponseBody): TaskResult["usage"] | undefined {
  const usage: TaskResult["usage"] = {};

  if (typeof response.usage?.input_tokens === "number") {
    usage.inputTokens = response.usage.input_tokens;
  }
  if (typeof response.usage?.output_tokens === "number") {
    usage.outputTokens = response.usage.output_tokens;
  }
  if (typeof response.usage?.total_tokens === "number") {
    usage.totalTokens = response.usage.total_tokens;
  }

  return Object.keys(usage).length > 0 ? usage : undefined;
}

function parseJson<T>(value: string): T {
  try {
    return JSON.parse(value) as T;
  } catch {
    return {} as T;
  }
}

function getOpenAIErrorMessage(
  response: OpenAIErrorBody,
  status: number,
  statusText: string
): string {
  if (typeof response.error?.message === "string" && response.error.message.length > 0) {
    return response.error.message;
  }

  return `OpenAI Responses request failed with HTTP ${status} ${statusText}.`;
}

function parseRetryAfterMs(headers: Record<string, string>): number | undefined {
  const raw = headers["retry-after"] ?? headers["Retry-After"];
  if (!raw) {
    return undefined;
  }

  const seconds = Number(raw);
  if (Number.isFinite(seconds)) {
    return Math.max(0, seconds * 1000);
  }

  const dateMs = Date.parse(raw);
  if (Number.isFinite(dateMs)) {
    return Math.max(0, dateMs - Date.now());
  }

  return undefined;
}

function isAbortError(error: unknown): boolean {
  return isRecord(error) && getString(error.name) === "AbortError";
}

function getErrorSummary(error: unknown): Record<string, string> {
  if (error instanceof Error) {
    return {
      name: error.name,
      message: error.message
    };
  }

  return { message: String(error) };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object";
}

function getString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

/**
 * The HTTP status OpenRouter documents for each typed `error_type`, so a typed
 * failure is classified exactly like the equivalent HTTP error. Refusals and
 * content-policy violations are documented as 403 but are not credential
 * failures, so they classify as a rejected request (400). Unknown types return
 * `undefined` and the native `code` decides instead.
 */
function openRouterErrorTypeStatus(errorType: unknown): number | undefined {
  return typeof errorType === "string" && Object.hasOwn(OPENROUTER_ERROR_TYPE_STATUS, errorType)
    ? OPENROUTER_ERROR_TYPE_STATUS[errorType]
    : undefined;
}

const OPENROUTER_ERROR_TYPE_STATUS: Readonly<Record<string, number>> = {
  authentication: 401,
  payment_required: 402,
  permission_denied: 403,
  rate_limit_exceeded: 429,
  timeout: 504,
  provider_unavailable: 502,
  provider_overloaded: 503,
  server: 500,
  unmapped: 500,
  not_found: 404,
  image_not_found: 404,
  precondition_failed: 412,
  payload_too_large: 413,
  unprocessable: 422,
  content_policy_violation: 400,
  refusal: 400,
  context_length_exceeded: 400,
  max_tokens_exceeded: 400,
  token_limit_exceeded: 400,
  string_too_long: 400,
  invalid_request: 400,
  invalid_prompt: 400,
  invalid_image: 400,
  image_too_large: 400,
  image_too_small: 400,
  unsupported_image_format: 400,
  image_download_failed: 400
};

/** An error `code` as a detail string, whether the server sent a name or a numeric status. */
function getErrorCode(value: unknown): string | undefined {
  return typeof value === "number" ? String(value) : getString(value);
}
