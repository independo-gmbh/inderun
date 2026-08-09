import type { ModelPackage, TaskRequest, TaskResult } from "@independo/inderun-contracts";

/**
 * Availability snapshot reported by an ONNX text generation runtime.
 *
 * The `reason` string uses the provider-internal capability vocabulary documented in
 * `docs/architecture/onnx-runtime-provider-family.md`. It is not a public enum: the provider
 * flattens every failure into a single `capability_unavailable` route rejection and carries the
 * reason as human-readable text.
 */
export interface OnnxRuntimeAvailability {
  /** Whether the runtime can execute the given model package on this host right now. */
  available: boolean;
  /** Human-readable detail describing why the runtime is unavailable. */
  reason?: string;
}

/**
 * Normalized conversation turn handed to an ONNX text generation runtime.
 */
export interface OnnxGenerationMessage {
  /** The role of the author of this turn. */
  role: "system" | "user" | "assistant";
  /** Plain-text content of this turn. */
  content: string;
}

/**
 * Normalized generation request handed to an ONNX text generation runtime.
 */
export interface OnnxGenerationInput {
  /** The model package the provider was configured with. */
  modelPackage: ModelPackage;
  /** Conversation turns, normalized from `prompt` or `messages` by the provider. */
  messages: OnnxGenerationMessage[];
  /** Optional generation controls copied from the task request. */
  generation?: NonNullable<TaskRequest["generation"]>;
}

/**
 * Normalized generation result returned by an ONNX text generation runtime.
 */
export interface OnnxGenerationOutput {
  /** The generated text. */
  text: string;
  /** Optional normalized finish reason; the provider defaults to `stop`. */
  finishReason?: TaskResult["finishReason"];
  /** Optional token accounting, when the runtime reports it. */
  usage?: TaskResult["usage"];
}

/**
 * Failure category a runtime can signal so the provider maps it onto the IndeRun error taxonomy.
 *
 * - `capability`: model or runtime cannot serve this request (`CapabilityMismatch`).
 * - `unavailable`: runtime initialization failure or resource exhaustion (`Unavailable`).
 * - `timeout`: generation exceeded its budget or was aborted (`Timeout`).
 * - `internal`: unexpected runtime failure (`Internal`).
 */
export type OnnxRuntimeErrorKind = "capability" | "unavailable" | "timeout" | "internal";

/**
 * Error type ONNX runtime implementations throw to steer IndeRun error normalization.
 *
 * Anything else thrown by a runtime is normalized to `Internal`.
 */
export class OnnxRuntimeError extends Error {
  /** Failure category used by the provider to select an IndeRun error class. */
  readonly kind: OnnxRuntimeErrorKind;
  /** Optional underlying error captured for telemetry details. */
  readonly originalError?: unknown;

  constructor(kind: OnnxRuntimeErrorKind, message: string, originalError?: unknown) {
    super(message);
    this.name = "OnnxRuntimeError";
    this.kind = kind;
    if (originalError !== undefined) this.originalError = originalError;

    Object.setPrototypeOf(this, OnnxRuntimeError.prototype);
  }
}

/**
 * Injectable seam between the IndeRun ONNX Web provider and the actual on-device runtime.
 *
 * IndeRun ships a Transformers.js-backed implementation as the default and a deterministic
 * fixture for tests, but applications can supply their own implementation (for example a
 * hand-rolled `onnxruntime-web` pipeline) without touching the provider.
 */
export interface OnnxTextGenerationRuntime {
  /**
   * Checks runtime package availability, execution backend availability, and model readiness.
   * Implementations must resolve with an availability snapshot rather than throwing.
   */
  prepare(modelPackage: ModelPackage): Promise<OnnxRuntimeAvailability>;
  /**
   * Runs one Mode-1 generation. Implementations should honor `signal` where the underlying
   * runtime allows it; ONNX inference is not hard-interruptible, so cancellation is best effort.
   */
  generate(input: OnnxGenerationInput, signal?: AbortSignal): Promise<OnnxGenerationOutput>;
}

/**
 * Configuration for the deterministic fixture runtime.
 */
export interface FixtureOnnxRuntimeOptions {
  /** Availability snapshot returned by `prepare`. Defaults to `{ available: true }`. */
  availability?: OnnxRuntimeAvailability;
  /** Text or full output produced by `generate`. Defaults to a deterministic echo. */
  respond?: (input: OnnxGenerationInput) => string | OnnxGenerationOutput;
  /** Error thrown by `generate` instead of producing output. */
  failWith?: unknown;
  /** Artificial generation delay in milliseconds, used to exercise timeouts. */
  delayMs?: number;
}

/**
 * Creates a deterministic in-memory ONNX runtime.
 *
 * This is the test seam mandated by the ONNX Runtime provider family specification: it proves the
 * model package contract, capability checks, routing, and error normalization without depending on
 * a real ONNX runtime, and it lets demos exercise the on-device route offline.
 *
 * @param options - Scripted availability, response, failure, and delay behavior.
 */
export function createFixtureOnnxRuntime(
  options: FixtureOnnxRuntimeOptions = {}
): OnnxTextGenerationRuntime {
  const availability = options.availability ?? { available: true };

  return {
    async prepare(): Promise<OnnxRuntimeAvailability> {
      return availability;
    },
    async generate(
      input: OnnxGenerationInput,
      signal?: AbortSignal
    ): Promise<OnnxGenerationOutput> {
      if (options.delayMs !== undefined && options.delayMs > 0) {
        await delay(options.delayMs, signal);
      }

      throwIfAborted(signal);

      if (options.failWith !== undefined) {
        throw options.failWith;
      }

      const response = options.respond
        ? options.respond(input)
        : createFixtureText(input.modelPackage, input.messages);

      return typeof response === "string" ? { text: response } : response;
    }
  };
}

function createFixtureText(modelPackage: ModelPackage, messages: OnnxGenerationMessage[]): string {
  const lastUserMessage = [...messages].reverse().find((message) => message.role === "user");
  const prompt = lastUserMessage?.content ?? "";
  return `[fixture:${modelPackage.id}] ${prompt}`;
}

function delay(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, ms);

    function onAbort(): void {
      clearTimeout(timer);
      reject(new OnnxRuntimeError("timeout", "Fixture ONNX generation was aborted."));
    }

    if (signal?.aborted) {
      onAbort();
      return;
    }
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}

function throwIfAborted(signal?: AbortSignal): void {
  if (signal?.aborted) {
    throw new OnnxRuntimeError("timeout", "Fixture ONNX generation was aborted.");
  }
}
