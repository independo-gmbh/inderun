import type {
  ExecutionProvenance,
  StreamEvent,
  StreamTerminalOutcome,
  TaskRequest,
  TaskResult
} from "@independo/inderun-contracts";
import { IndeRunException } from "../core/errors.js";
import type { IndeRunApi } from "../core/generated/inderun-api.js";
import { AUTO_MODEL_PROFILE } from "../core/model-profiles.js";

/**
 * The primary text API: `generateText()` and `streamText()`.
 *
 * Both are translation only. Each call compiles to exactly one canonical `TaskRequest`
 * ({@link toTaskRequest}) and calls `run()` or `stream()` on the `IndeRunApi` it is given, so
 * routing, fallback, cancellation, credentials, telemetry, and error normalization are the
 * engine's and identical to a direct call. Written against the generated interface rather than
 * the engine class, so anything that implements `IndeRunApi` -- a bridge included -- gets the
 * same facade. See `docs/architecture/api-layering.md`.
 */

type Message = NonNullable<TaskRequest["messages"]>[number];

/**
 * Compact execution policy. Reuses the canonical enum values, so moving a call between the
 * facade and `run()` never changes what a constraint means.
 */
export interface TextExecutionOptions {
  /** `constraints.privacy`: how strict placement is, e.g. `"local_required"`. */
  privacy?: NonNullable<TaskRequest["constraints"]>["privacy"];
  /** `constraints.cloud`: `"forbidden"`, `"allowed"`, or `"required"`. */
  cloud?: NonNullable<TaskRequest["constraints"]>["cloud"];
  /** `constraints.timeoutMs`. */
  timeoutMs?: number;
  /** `preferences.optimizeFor`. */
  optimizeFor?: NonNullable<TaskRequest["preferences"]>["optimizeFor"];
}

interface TextGenerationCommonOptions {
  /**
   * Model profile to route within, as configured on the engine. Omitted or `"auto"` routes
   * across every registered target. Never a vendor model id.
   */
  model?: string;
  /** Instructions sent as a leading `system` message. */
  system?: string;
  maxOutputTokens?: number;
  temperature?: number;
  topP?: number;
  stop?: string[];
  seed?: number;
  execution?: TextExecutionOptions;
  /** Secure-storage slot for provider credentials. Never a raw secret. */
  authContextRef?: string;
  telemetry?: TaskRequest["telemetry"];
  /** Fixes the run id, for correlation. */
  requestId?: string;
}

/** Options for {@link generateText} and {@link streamText}: a prompt or a message list. */
export type TextGenerationOptions = TextGenerationCommonOptions &
  ({ prompt: string; messages?: never } | { messages: Message[]; prompt?: never });

/** What {@link generateText} returns. */
export interface GeneratedText {
  text: string;
  finishReason: TaskResult["finishReason"];
  usage?: TaskResult["usage"];
  runId: string;
  /** How the run played out; see `ExecutionProvenance`. */
  provenance?: ExecutionProvenance;
  /** The canonical result, for anything the summary above leaves out. */
  taskResult: TaskResult;
}

/** How a {@link streamText} run ended, when it did not fail. */
export interface StreamedText {
  /** The full text, or the partial text a cancelled run had delivered. */
  text: string;
  /** `"cancelled"` when the run was cancelled; otherwise as the provider reported it. */
  finishReason?: TaskResult["finishReason"];
  usage?: TaskResult["usage"];
  runId: string;
  provenance?: ExecutionProvenance;
  /** The canonical terminal outcome. */
  outcome: StreamTerminalOutcome;
}

/** What {@link streamText} returns. */
export interface TextStream {
  runId: string;
  /**
   * Text increments, in order. Ends when the run completes or is cancelled; throws the run's
   * `IndeRunException` when it fails, and {@link TextStreamRetractedError} when the provider
   * replaces delivered text (use `fullStream` to render retractions).
   */
  textStream: AsyncIterable<string>;
  /** The canonical `StreamEvent` sequence, terminal included. */
  fullStream: AsyncIterable<StreamEvent>;
  /**
   * Settles with the run's ending: resolves on completion or cancellation, rejects with the
   * run's `IndeRunException` on failure.
   */
  result: Promise<StreamedText>;
  /** Cancels the run; idempotent. */
  cancel(reason?: string): void;
}

/**
 * Thrown by `textStream` when the provider replaces text it already delivered with text that
 * does not extend it, which an append-only text view cannot represent.
 */
export class TextStreamRetractedError extends Error {
  constructor(readonly runId: string) {
    super(
      `Run ${runId} replaced text it had already delivered; read fullStream to render retractions.`
    );
    this.name = "TextStreamRetractedError";
  }
}

/** The canonical `TaskRequest` a facade call compiles to. */
export function toTaskRequest(options: TextGenerationOptions): TaskRequest {
  const request: TaskRequest = { schemaVersion: "1.0", task: { kind: "text_to_text" } };

  if (options.system !== undefined) {
    const conversation =
      options.messages ??
      (options.prompt !== undefined ? [{ role: "user" as const, content: options.prompt }] : []);
    request.messages = [{ role: "system", content: options.system }, ...conversation];
  } else if (options.messages !== undefined) {
    // An empty list is the engine's to reject, with the same validation error as run().
    request.messages = options.messages as NonNullable<TaskRequest["messages"]>;
  } else if (options.prompt !== undefined) {
    request.prompt = options.prompt;
  }

  if (options.model !== undefined && options.model !== AUTO_MODEL_PROFILE) {
    request.modelProfile = options.model;
  }

  const generation: NonNullable<TaskRequest["generation"]> = {};
  if (options.maxOutputTokens !== undefined) generation.maxOutputTokens = options.maxOutputTokens;
  if (options.temperature !== undefined) generation.temperature = options.temperature;
  if (options.topP !== undefined) generation.topP = options.topP;
  if (options.stop !== undefined) generation.stop = options.stop;
  if (options.seed !== undefined) generation.seed = options.seed;
  if (Object.keys(generation).length > 0) request.generation = generation;

  const execution = options.execution ?? {};
  const constraints: NonNullable<TaskRequest["constraints"]> = {};
  if (execution.privacy !== undefined) constraints.privacy = execution.privacy;
  if (execution.cloud !== undefined) constraints.cloud = execution.cloud;
  if (execution.timeoutMs !== undefined) constraints.timeoutMs = execution.timeoutMs;
  if (Object.keys(constraints).length > 0) request.constraints = constraints;
  if (execution.optimizeFor !== undefined) {
    request.preferences = { optimizeFor: execution.optimizeFor };
  }

  if (options.authContextRef !== undefined) request.authContextRef = options.authContextRef;
  if (options.telemetry !== undefined) request.telemetry = options.telemetry;
  if (options.requestId !== undefined) request.requestId = options.requestId;

  return request;
}

/**
 * Generates text in one call: `run()` over the canonical request. Not cancellable, for the same
 * reason `run()` is not; use {@link streamText} when cancellation matters.
 * @throws {IndeRunException} Exactly as `run()` does.
 */
export async function generateText(
  inderun: IndeRunApi,
  options: TextGenerationOptions
): Promise<GeneratedText> {
  const taskResult = await inderun.run(toTaskRequest(options));
  return {
    text: taskResult.output.text,
    finishReason: taskResult.finishReason,
    ...(taskResult.usage !== undefined ? { usage: taskResult.usage } : {}),
    runId: taskResult.runId,
    ...(taskResult.provenance !== undefined ? { provenance: taskResult.provenance } : {}),
    taskResult
  };
}

/**
 * Streams text: `stream()` over the canonical request. The run starts immediately and is read
 * once, into a replay buffer, so `textStream`, `fullStream`, and `result` can each be consumed
 * in any order (or not at all) without stalling the others.
 * @throws {IndeRunException} Exactly as `stream()` does: validation and routing refusals reject
 *   here, before there is a run.
 */
export async function streamText(
  inderun: IndeRunApi,
  options: TextGenerationOptions
): Promise<TextStream> {
  const run = await inderun.stream(toTaskRequest(options));
  const runId = run.handle.runId;
  const replay = new ReplayBuffer<StreamEvent>();

  const result = (async (): Promise<StreamedText> => {
    // The terminal event is the last one a run delivers, so it settles everything; a source
    // that stays open after it (a bridge subscription, say) must not hold the result back.
    // Releasing the source is not awaited for the same reason.
    const events = run.events[Symbol.asyncIterator]();
    try {
      for (let next = await events.next(); next.done !== true; next = await events.next()) {
        replay.push(next.value);
        if (next.value.type === "terminal") {
          void events.return?.()?.catch(() => undefined);
          break;
        }
      }
      replay.close();
    } catch (error) {
      replay.fail(error);
      throw error;
    }
    const terminal = replay.items.find((event) => event.type === "terminal");
    if (terminal === undefined) {
      throw new IndeRunException({
        errorClass: "Internal",
        message: `Run ${runId} ended without a terminal event.`,
        runId
      });
    }
    return settle(terminal.payload as unknown as StreamTerminalOutcome);
  })();
  // Consumers may read only one view; an unread rejection must not surface as unhandled.
  result.catch(() => undefined);

  return {
    runId,
    fullStream: { [Symbol.asyncIterator]: () => replay.iterate() },
    textStream: { [Symbol.asyncIterator]: () => textIncrements(replay.iterate(), runId) },
    result,
    cancel: (reason?: string) => run.cancel(reason)
  };
}

function settle(outcome: StreamTerminalOutcome): StreamedText {
  const provenance = outcome.provenance !== undefined ? { provenance: outcome.provenance } : {};
  switch (outcome.outcome) {
    case "completed":
      return {
        text: outcome.finalText ?? "",
        ...(outcome.finishReason !== undefined ? { finishReason: outcome.finishReason } : {}),
        ...(outcome.usage !== undefined ? { usage: outcome.usage } : {}),
        runId: outcome.runId,
        ...provenance,
        outcome
      };
    case "cancelled":
      return {
        text: outcome.partialText ?? "",
        finishReason: "cancelled",
        runId: outcome.runId,
        ...provenance,
        outcome
      };
    case "error": {
      const error = outcome.error!;
      throw new IndeRunException({
        errorClass: error.errorClass,
        message: error.message,
        runId: outcome.runId,
        ...(error.providerId !== undefined ? { providerId: error.providerId } : {}),
        ...(error.retryable !== undefined ? { retryable: error.retryable } : {}),
        ...(error.retryAfterMs !== undefined ? { retryAfterMs: error.retryAfterMs } : {}),
        ...(error.details !== undefined ? { details: error.details } : {}),
        ...(outcome.provenance !== undefined ? { provenance: outcome.provenance } : {})
      });
    }
  }
}

async function* textIncrements(
  events: AsyncIterable<StreamEvent>,
  runId: string
): AsyncGenerator<string> {
  let text = "";
  for await (const event of events) {
    if (event.type === "content_delta") {
      const delta = (event.payload as { text: string }).text;
      text += delta;
      yield delta;
    } else if (event.type === "content_snapshot") {
      const snapshot = (event.payload as { text: string }).text;
      if (!snapshot.startsWith(text)) {
        throw new TextStreamRetractedError(runId);
      }
      const suffix = snapshot.slice(text.length);
      text = snapshot;
      if (suffix.length > 0) yield suffix;
    } else if (event.type === "terminal") {
      settle(event.payload as unknown as StreamTerminalOutcome);
      return;
    }
  }
}

/**
 * Holds every item read from a single-use source so any number of readers can iterate it from
 * the start, each at its own pace. Readers that catch up wait for the next item.
 */
class ReplayBuffer<T> {
  readonly items: T[] = [];
  private done = false;
  private failure: { error: unknown } | undefined;
  private waiters: (() => void)[] = [];

  push(item: T): void {
    this.items.push(item);
    this.wake();
  }

  close(): void {
    this.done = true;
    this.wake();
  }

  fail(error: unknown): void {
    this.failure = { error };
    this.close();
  }

  async *iterate(): AsyncGenerator<T> {
    let index = 0;
    while (true) {
      if (index < this.items.length) {
        yield this.items[index++]!;
        continue;
      }
      if (this.done) {
        if (this.failure !== undefined) throw this.failure.error;
        return;
      }
      await new Promise<void>((resolve) => this.waiters.push(resolve));
    }
  }

  private wake(): void {
    const waiters = this.waiters;
    this.waiters = [];
    for (const wake of waiters) wake();
  }
}
