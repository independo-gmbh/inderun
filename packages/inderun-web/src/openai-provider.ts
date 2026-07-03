import type { TaskRequest, TaskResult } from "@independo/inderun-contracts";
import {
  createAuthError,
  createInternal,
  createRateLimited,
  createTimeout,
  createUnavailable
} from "./errors.js";
import type { HostServices, HttpRequest } from "./host.js";
import type {
  ProviderAdapter,
  ProviderDescriptor,
  ProviderDynamicCapabilities,
  RunContext
} from "./provider.js";

export const DEFAULT_OPENAI_RESPONSES_ENDPOINT = "https://api.openai.com/v1/responses";

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
}

type OpenAIResponseBody = {
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
      transport: "http",
      supports: {
        run: true,
        streaming: false,
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
        reason:
          "OpenAI Responses provider requires a SecureStorageService when auth is enabled."
      };
    }

    return { available: true };
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

    const headers: Record<string, string> = {
      "Content-Type": "application/json"
    };

    if (this.auth === "authContextRef") {
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
    }

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
      throw this.mapHttpError(response.status, response.statusText, response.headers, response.body, context);
    }

    const responseBody = parseJson<OpenAIResponseBody>(response.body);
    const outputText = extractOutputText(responseBody);
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

    const usage = getUsage(responseBody);
    if (usage) {
      result.usage = usage;
    }

    return result;
  }

  private createRequestBody(request: TaskRequest): Record<string, unknown> {
    const body: Record<string, unknown> = {
      model: this.options.model,
      input: createInput(request)
    };

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
   * Maps an OpenAI HTTP error response onto the IndeRun error taxonomy:
   * - `401` / `403` → `AuthError`
   * - `429` → `RateLimited` (honors `Retry-After` when present)
   * - `408` / `504` → `Timeout`
   * - `409` / `5xx` → `Unavailable`
   * - any other non-2xx status → `Internal`
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
    const details = {
      status,
      statusText,
      errorType: getString(error.error?.type),
      errorCode: getString(error.error?.code)
    };

    if (status === 401 || status === 403) {
      return createAuthError(message, {
        providerId: this.id,
        runId: context.runId,
        details
      });
    }

    if (status === 429) {
      const retryAfterMs = parseRetryAfterMs(headers);
      const params = {
        providerId: this.id,
        runId: context.runId,
        retryable: true,
        details
      };

      if (retryAfterMs !== undefined) {
        return createRateLimited(message, {
          ...params,
          retryAfterMs
        });
      }

      return createRateLimited(message, params);
    }

    if (status === 408 || status === 504) {
      return createTimeout(message, {
        providerId: this.id,
        runId: context.runId,
        retryable: true,
        details
      });
    }

    if (status === 409 || status >= 500) {
      return createUnavailable(message, {
        providerId: this.id,
        runId: context.runId,
        retryable: true,
        details
      });
    }

    return createInternal(message, {
      providerId: this.id,
      runId: context.runId,
      details
    });
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
