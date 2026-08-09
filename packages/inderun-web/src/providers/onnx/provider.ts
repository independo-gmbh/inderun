import {
  getModelPackageValidationIssues,
  type ModelPackage,
  type ModelSourceType,
  type TaskRequest,
  type TaskResult
} from "@independo/inderun-contracts";
import {
  createCapabilityMismatch,
  createInternal,
  createTimeout,
  createUnavailable,
  toIndeRunException,
  type IndeRunException
} from "../../core/errors.js";
import type { HostServices } from "../../core/host.js";
import {
  OnnxRuntimeError,
  type OnnxGenerationMessage,
  type OnnxGenerationOutput,
  type OnnxTextGenerationRuntime
} from "./runtime.js";
import { createTransformersJsRuntime } from "./transformers-runtime.js";
import type {
  ProviderAdapter,
  ProviderDescriptor,
  ProviderDynamicCapabilities,
  RunContext
} from "../../core/provider.js";

/** Default provider id of the Web member of the ONNX Runtime provider family. */
export const DEFAULT_ONNX_WEB_PROVIDER_ID = "local.onnx.genai.web";

/** Task kind this provider implements in Milestone 2 (Mode 1 only). */
const TEXT_TO_TEXT = "text_to_text";

/**
 * Model source types the Web member of the ONNX Runtime provider family can honor.
 *
 * `filesystem` is unsupported because browsers do not expose arbitrary local paths, and `remote`
 * is deferred: hosts download model files themselves and then supply them as `bundled`,
 * `app_managed`, or `programmatic`.
 */
export const SUPPORTED_WEB_MODEL_SOURCE_TYPES: readonly ModelSourceType[] = [
  "registry",
  "bundled",
  "programmatic",
  "app_managed"
];

/**
 * Configuration for the Web ONNX Runtime provider.
 */
export interface OnnxProviderOptions {
  /**
   * Provider id exposed in telemetry and routing explanations.
   */
  id?: string;
  /**
   * Provider-neutral bootstrap metadata describing the developer-supplied model.
   */
  modelPackage: ModelPackage;
  /**
   * Runtime implementation used to execute generation. Defaults to the Transformers.js-backed
   * runtime; applications can inject their own implementation of the seam.
   */
  runtime?: OnnxTextGenerationRuntime;
  /**
   * Optional generation timeout in milliseconds. A request-level `constraints.timeoutMs` wins.
   */
  timeoutMs?: number;
}

/**
 * Local provider adapter that executes Mode-1 text-to-text requests with a developer-supplied ONNX
 * model in the browser.
 *
 * The adapter owns the IndeRun-facing contract (descriptor, capability checks, error taxonomy) and
 * delegates execution to an injectable {@link OnnxTextGenerationRuntime}. ONNX Runtime execution
 * backends (WASM, WebGPU, WebNN) stay behind that seam and are never public routing concepts.
 */
export class OnnxRuntimeWebProvider implements ProviderAdapter {
  private readonly id: string;
  private readonly modelPackage: ModelPackage;
  private readonly runtime: OnnxTextGenerationRuntime;

  /**
   * Creates a Web ONNX Runtime provider.
   * @param options - Model package plus optional id, runtime, and timeout overrides.
   */
  constructor(private readonly options: OnnxProviderOptions) {
    this.id = options.id ?? DEFAULT_ONNX_WEB_PROVIDER_ID;
    this.modelPackage = options.modelPackage;
    this.runtime = options.runtime ?? createTransformersJsRuntime();
  }

  /**
   * Returns static metadata used by the router for deterministic provider selection.
   */
  describe(): ProviderDescriptor {
    return {
      id: this.id,
      type: "local",
      transport: "in_process",
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
      tasks: getDeclaredTasks(this.modelPackage),
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
   * @param _host - Host services available to the engine (unused; ONNX runs in-process).
   */
  async capabilities(_host: HostServices): Promise<ProviderDynamicCapabilities> {
    const issues = getModelPackageValidationIssues(this.modelPackage);
    if (issues.length > 0) {
      const summary = issues.map((issue) => `${issue.path} ${issue.message}`).join("; ");
      return { available: false, reason: `model package malformed: ${summary}` };
    }

    const sourceType = this.modelPackage.source?.sourceType;
    if (sourceType !== undefined && !SUPPORTED_WEB_MODEL_SOURCE_TYPES.includes(sourceType)) {
      return {
        available: false,
        reason:
          sourceType === "filesystem"
            ? "model source unavailable: 'filesystem' model sources are unsupported on Web because browsers cannot read arbitrary local paths."
            : `model source unavailable: '${sourceType}' model sources are deferred on Web; supply model files as ${SUPPORTED_WEB_MODEL_SOURCE_TYPES.join(", ")}.`
      };
    }

    const platforms = this.modelPackage.runtime?.platforms;
    if (Array.isArray(platforms) && platforms.length > 0 && !platforms.includes("web")) {
      return {
        available: false,
        reason: `platform unsupported: the model package targets ${platforms.join(", ")} and does not list 'web'.`
      };
    }

    if (!getDeclaredTasks(this.modelPackage).includes(TEXT_TO_TEXT)) {
      return {
        available: false,
        reason: `unsupported task: the model package declares ${getDeclaredTasks(this.modelPackage).join(", ")} and does not support '${TEXT_TO_TEXT}'.`
      };
    }

    return this.runtime.prepare(this.modelPackage);
  }

  /**
   * Executes a normalized text-to-text task on the developer-supplied local ONNX model.
   * @param request - Canonical IndeRun task request.
   * @param context - Engine execution context containing run id and host services.
   * @returns Normalized IndeRun task result.
   * @throws IndeRunException mapped to the standard error taxonomy.
   */
  async run(request: TaskRequest, context: RunContext): Promise<TaskResult> {
    const availability = await this.capabilities(context.hostServices);
    if (!availability.available) {
      throw createCapabilityMismatch(
        availability.reason ?? "ONNX Runtime Web provider is unavailable on this host.",
        { providerId: this.id, runId: context.runId }
      );
    }

    const messages = createMessages(request);
    if (messages.length === 0) {
      throw createInternal("ONNX Runtime Web provider requires a prompt or messages.", {
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

    let output: OnnxGenerationOutput;
    try {
      output = await this.runtime.generate(
        {
          modelPackage: this.modelPackage,
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
      throw createInternal("ONNX Runtime Web provider returned no text output.", {
        providerId: this.id,
        runId: context.runId
      });
    }

    const result: TaskResult = {
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

    if (output.usage) {
      result.usage = output.usage;
    }

    return result;
  }

  private mapRuntimeError(error: unknown, context: RunContext): IndeRunException {
    const extra = { providerId: this.id, runId: context.runId };

    if (error instanceof OnnxRuntimeError) {
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
      return createTimeout("ONNX Runtime Web generation timed out.", extra);
    }

    return toIndeRunException(error, extra);
  }
}

function getDeclaredTasks(modelPackage: ModelPackage): string[] {
  const tasks = modelPackage.tasks;
  return Array.isArray(tasks) && tasks.length > 0 ? tasks : [TEXT_TO_TEXT];
}

function createMessages(request: TaskRequest): OnnxGenerationMessage[] {
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
