import type { TaskRequest, TaskResult } from "@independo/inderun-contracts";
import {
  createCapabilityMismatch,
  createInternal,
  createTimeout,
  createUnavailable,
  toIndeRunException,
  type IndeRunException
} from "./errors.js";
import type { HostServices } from "./host.js";
import { createChromePromptApiRuntime } from "./system-model-chrome-runtime.js";
import {
  SystemModelRuntimeError,
  type SystemModelAvailability,
  type SystemModelPromptMessage,
  type SystemModelRuntime
} from "./system-model-runtime.js";
import type {
  ProviderAdapter,
  ProviderDescriptor,
  ProviderDynamicCapabilities,
  RunContext
} from "./provider.js";

/** Default provider id of the Web member of the system-model provider family. */
export const DEFAULT_SYSTEM_MODEL_WEB_PROVIDER_ID = "local.system-model.web";

/** Task kind this provider implements in Milestone 2 (Mode 1 only). */
const TEXT_TO_TEXT = "text_to_text";

/**
 * Configuration for the Web system-model provider.
 */
export interface SystemModelProviderOptions {
  /**
   * Provider id exposed in telemetry and routing explanations.
   */
  id?: string;
  /**
   * Runtime implementation used to check availability and execute generation. Defaults to
   * `createChromePromptApiRuntime()`; pass `createFixtureSystemModelRuntime()` from
   * `system-model.js` for tests and offline demos.
   */
  runtime?: SystemModelRuntime;
  /**
   * Optional generation timeout in milliseconds. A request-level `constraints.timeoutMs` wins.
   */
  timeoutMs?: number;
}

/**
 * Local provider adapter that executes Mode-1 text-to-text requests against a browser-managed
 * on-device model (for example Chrome's Prompt API / Gemini Nano).
 *
 * Unlike the ONNX Runtime provider family, this provider takes no developer-supplied model: the
 * browser owns model availability, download, and execution. The adapter owns the IndeRun-facing
 * contract (descriptor, capability checks, error taxonomy) and delegates everything else to an
 * injectable {@link SystemModelRuntime}.
 */
export class SystemModelWebProvider implements ProviderAdapter {
  private readonly id: string;
  private readonly runtime: SystemModelRuntime;

  /**
   * Creates a Web system-model provider.
   * @param options - Optional id, runtime, and timeout overrides.
   */
  constructor(private readonly options: SystemModelProviderOptions = {}) {
    this.id = options.id ?? DEFAULT_SYSTEM_MODEL_WEB_PROVIDER_ID;
    this.runtime = options.runtime ?? createChromePromptApiRuntime();
  }

  /**
   * Returns static metadata used by the router for deterministic provider selection.
   */
  describe(): ProviderDescriptor {
    return {
      id: this.id,
      type: "local",
      transport: "system_service",
      supports: {
        run: true,
        streaming: false,
        realtime: false,
        tools: false,
        reasoningEvents: false,
        structuredOutput: false,
        multimodal: false
      },
      cancel: "soft",
      tasks: [TEXT_TO_TEXT],
      privacy: {
        dataLeavesDevice: false
      }
    };
  }

  /**
   * Reports dynamic provider availability for the current host.
   *
   * Every failure below is provider-internal detail: the shared route planner flattens it into a
   * single `capability_unavailable` rejection carrying the returned reason.
   *
   * @param _host - Host services available to the engine (unused; the browser owns execution).
   */
  async capabilities(_host: HostServices): Promise<ProviderDynamicCapabilities> {
    const availability = await this.runtime.availability();
    return toDynamicCapabilities(availability);
  }

  /**
   * Executes a normalized text-to-text task against the browser-managed on-device model.
   * @param request - Canonical IndeRun task request.
   * @param context - Engine execution context containing run id and host services.
   * @returns Normalized IndeRun task result.
   * @throws IndeRunException mapped to the standard error taxonomy.
   */
  async run(request: TaskRequest, context: RunContext): Promise<TaskResult> {
    const availability = await this.runtime.availability();
    const capabilities = toDynamicCapabilities(availability);
    if (!capabilities.available) {
      throw createCapabilityMismatch(
        capabilities.reason ?? "Web system-model provider is unavailable on this host.",
        { providerId: this.id, runId: context.runId }
      );
    }

    const messages = createMessages(request);
    if (messages.length === 0) {
      throw createInternal("Web system-model provider requires a prompt or messages.", {
        providerId: this.id,
        runId: context.runId
      });
    }

    const timeoutMs = request.constraints?.timeoutMs ?? this.options.timeoutMs;
    const controller = new AbortController();
    const timer =
      timeoutMs !== undefined && timeoutMs > 0
        ? setTimeout(() => controller.abort(), timeoutMs)
        : undefined;

    let output: Awaited<ReturnType<SystemModelRuntime["generate"]>>;
    try {
      output = await this.runtime.generate(
        {
          messages,
          ...(request.generation !== undefined ? { generation: request.generation } : {})
        },
        controller.signal
      );
    } catch (err) {
      throw this.mapRuntimeError(err, context);
    } finally {
      if (timer !== undefined) clearTimeout(timer);
    }

    if (typeof output.text !== "string" || output.text.length === 0) {
      throw createInternal("Web system-model provider returned no text output.", {
        providerId: this.id,
        runId: context.runId
      });
    }

    return {
      schemaVersion: "1.0",
      runId: context.runId,
      output: {
        type: "text",
        text: output.text
      },
      finishReason: output.finishReason ?? "stop",
      telemetry: {
        providerUsed: this.id,
        totalMs: 0
      }
    };
  }

  private mapRuntimeError(error: unknown, context: RunContext): IndeRunException {
    const extra = { providerId: this.id, runId: context.runId };

    if (error instanceof SystemModelRuntimeError) {
      const details =
        error.originalError !== undefined
          ? { details: { originalError: getErrorSummary(error.originalError) } }
          : {};

      switch (error.kind) {
        case "capability":
          return createCapabilityMismatch(error.message, { ...extra, ...details });
        case "unavailable":
          return createUnavailable(error.message, { ...extra, ...details });
        case "timeout":
          return createTimeout(error.message, { ...extra, ...details });
        default:
          return createInternal(error.message, { ...extra, ...details });
      }
    }

    if (isAbortError(error)) {
      return createTimeout("Web system-model generation timed out.", extra);
    }

    return toIndeRunException(error, extra);
  }
}

const REASON_PREFIX: Record<SystemModelAvailability["kind"], string | undefined> = {
  available: undefined,
  downloadable: "model downloadable",
  downloading: "model downloading",
  model_unavailable: "model unavailable",
  api_missing: "system model API missing",
  browser_unsupported: "browser unsupported",
  feature_disabled: "browser feature disabled",
  hardware_unsupported: "hardware unsupported",
  resource_constrained: "storage or network constraints",
  unavailable: "provider temporarily unavailable"
};

function toDynamicCapabilities(availability: SystemModelAvailability): ProviderDynamicCapabilities {
  if (availability.kind === "available") {
    return { available: true };
  }

  const prefix = REASON_PREFIX[availability.kind];
  const reason = availability.reason
    ? `${prefix}: ${availability.reason}`
    : `${prefix}: the Web system-model provider is unavailable.`;

  return { available: false, reason };
}

function createMessages(request: TaskRequest): SystemModelPromptMessage[] {
  if (request.messages && request.messages.length > 0) {
    return request.messages.map((message) => ({
      role: message.role,
      content: message.content
    }));
  }

  const prompt = request.prompt;
  return prompt !== undefined && prompt.length > 0 ? [{ role: "user", content: prompt }] : [];
}

function isAbortError(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    (error as { name?: unknown }).name === "AbortError"
  );
}

function getErrorSummary(error: unknown): Record<string, unknown> {
  if (error instanceof Error) {
    return { name: error.name, message: error.message, stack: error.stack };
  }
  return { message: String(error) };
}
