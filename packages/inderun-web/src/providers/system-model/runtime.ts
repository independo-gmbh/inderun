import type { TaskRequest, TaskResult } from "@independo/inderun-contracts";

/**
 * Capability state reported by a system-model runtime.
 *
 * The `reason` string uses the provider-internal capability vocabulary documented in
 * `docs/architecture/web-system-model-provider-family.md`. It is not a public enum: the provider
 * flattens every non-`available` kind into a single `capability_unavailable` route rejection and
 * carries the reason as human-readable text.
 */
export type SystemModelAvailabilityKind =
  | "available"
  | "downloadable"
  | "downloading"
  | "model_unavailable"
  | "api_missing"
  | "browser_unsupported"
  | "feature_disabled"
  | "hardware_unsupported"
  | "resource_constrained"
  | "unavailable";

/**
 * Availability snapshot reported by a system-model runtime.
 */
export interface SystemModelAvailability {
  /** The specific availability state the runtime observed. */
  kind: SystemModelAvailabilityKind;
  /** Human-readable detail describing the state; expected for every non-`available` kind. */
  reason?: string;
}

/**
 * Normalized conversation turn handed to a system-model runtime.
 */
export interface SystemModelPromptMessage {
  /** The role of the author of this turn. */
  role: "system" | "user" | "assistant";
  /** Plain-text content of this turn. */
  content: string;
}

/**
 * Normalized generation request handed to a system-model runtime.
 */
export interface SystemModelGenerationInput {
  /** Conversation turns, normalized from `prompt` or `messages` by the provider. */
  messages: SystemModelPromptMessage[];
  /** Optional generation controls copied from the task request. */
  generation?: NonNullable<TaskRequest["generation"]>;
}

/**
 * Normalized generation result returned by a system-model runtime.
 */
export interface SystemModelGenerationOutput {
  /** The generated text. */
  text: string;
  /** Optional normalized finish reason; the provider defaults to `stop`. */
  finishReason?: TaskResult["finishReason"];
}

/**
 * Failure category a runtime can signal so the provider maps it onto the IndeRun error taxonomy.
 *
 * - `capability`: the browser or hardware cannot serve this request (`CapabilityMismatch`).
 * - `unavailable`: resource exhaustion or transient failure (`Unavailable`).
 * - `timeout`: generation exceeded its budget or was aborted (`Timeout`).
 * - `internal`: unexpected runtime failure (`Internal`).
 */
export type SystemModelRuntimeErrorKind = "capability" | "unavailable" | "timeout" | "internal";

/**
 * Error type system-model runtime implementations throw to steer IndeRun error normalization.
 *
 * Anything else thrown by a runtime is normalized to `Internal`.
 */
export class SystemModelRuntimeError extends Error {
  /** Failure category used by the provider to select an IndeRun error class. */
  readonly kind: SystemModelRuntimeErrorKind;
  /** Optional underlying error captured for telemetry details. */
  readonly originalError?: unknown;

  constructor(kind: SystemModelRuntimeErrorKind, message: string, originalError?: unknown) {
    super(message);
    this.name = "SystemModelRuntimeError";
    this.kind = kind;
    if (originalError !== undefined) this.originalError = originalError;

    Object.setPrototypeOf(this, SystemModelRuntimeError.prototype);
  }
}

/**
 * Injectable seam between the IndeRun Web system-model provider and the browser's on-device model
 * API.
 *
 * IndeRun ships a Chrome Prompt API-backed implementation as the default and a deterministic
 * fixture for tests. The seam exposes only Mode-1 generation (no session object, no streaming
 * method) so streaming/session support cannot leak in even as unused scaffolding.
 */
export interface SystemModelRuntime {
  /**
   * Checks browser API presence and model readiness. Implementations must resolve with an
   * availability snapshot rather than throwing.
   */
  availability(): Promise<SystemModelAvailability>;
  /**
   * Runs one Mode-1 generation. Implementations should honor `signal` where the underlying API
   * allows it.
   */
  generate(
    input: SystemModelGenerationInput,
    signal?: AbortSignal
  ): Promise<SystemModelGenerationOutput>;
}

/**
 * Configuration for the deterministic fixture runtime.
 */
export interface FixtureSystemModelRuntimeOptions {
  /** Availability snapshot returned by `availability`. Defaults to `{ kind: "available" }`. */
  availability?: SystemModelAvailability;
  /** Text or full output produced by `generate`. Defaults to a deterministic echo. */
  respond?: (input: SystemModelGenerationInput) => string | SystemModelGenerationOutput;
  /** Error thrown by `generate` instead of producing output. */
  failWith?: unknown;
  /** Artificial generation delay in milliseconds, used to exercise timeouts. */
  delayMs?: number;
}

/**
 * Creates a deterministic in-memory system-model runtime.
 *
 * This is the test seam for the Web system-model provider family: it proves capability checks,
 * routing, and error normalization without depending on a real browser Prompt API implementation.
 *
 * @param options - Scripted availability, response, failure, and delay behavior.
 */
export function createFixtureSystemModelRuntime(
  options: FixtureSystemModelRuntimeOptions = {}
): SystemModelRuntime {
  const availability = options.availability ?? { kind: "available" };

  return {
    async availability(): Promise<SystemModelAvailability> {
      return availability;
    },
    async generate(
      input: SystemModelGenerationInput,
      signal?: AbortSignal
    ): Promise<SystemModelGenerationOutput> {
      if (options.delayMs !== undefined && options.delayMs > 0) {
        await delay(options.delayMs, signal);
      }

      throwIfAborted(signal);

      if (options.failWith !== undefined) {
        throw options.failWith;
      }

      const response = options.respond ? options.respond(input) : createFixtureText(input.messages);

      return typeof response === "string" ? { text: response } : response;
    }
  };
}

function createFixtureText(messages: SystemModelPromptMessage[]): string {
  const lastUserMessage = [...messages].reverse().find((message) => message.role === "user");
  const prompt = lastUserMessage?.content ?? "";
  return `[fixture:system-model] ${prompt}`;
}

function delay(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, ms);

    function onAbort(): void {
      clearTimeout(timer);
      reject(
        new SystemModelRuntimeError("timeout", "Fixture system-model generation was aborted.")
      );
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
    throw new SystemModelRuntimeError("timeout", "Fixture system-model generation was aborted.");
  }
}
