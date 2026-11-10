import type { TaskRequest, TaskResult } from "@independo/inderun-contracts";
import type {
  HostServices,
  ProviderAdapter,
  ProviderStreamContext,
  ProviderStreamEvent
} from "../provider.js";

/**
 * Fakes shared by the Mode 2 test suites.
 *
 * `src/test/**` is excluded from both the build (`tsconfig.json`) and the
 * published package (`package.json` `files`), so this module never ships.
 */

export function createRequest(overrides: Partial<TaskRequest> = {}): TaskRequest {
  return {
    schemaVersion: "1.0",
    task: { kind: "text_to_text" },
    prompt: "test prompt",
    constraints: { privacy: "local_required" },
    ...overrides
  };
}

/**
 * The request the `non_text_outputs` conformance cases stream: speech 'Hallo' in de-AT,
 * played back on the device.
 */
export function createSpeechRequest(overrides: Partial<TaskRequest> = {}): TaskRequest {
  return {
    schemaVersion: "1.0",
    task: { kind: "text_to_speech" },
    speech: { text: "Hallo", locale: "de-AT" },
    delivery: { mode: "playback" },
    constraints: { privacy: "local_required" },
    ...overrides
  };
}

export function createMockHostServices(options: { online?: boolean } = {}): HostServices {
  let timeVal = 1000;
  const online = options.online ?? true;
  return {
    connectivity: {
      async isOnline() {
        return online;
      }
    },
    clock: {
      now() {
        timeVal += 1;
        return timeVal;
      }
    }
  };
}

/**
 * Host services reading the real wall clock, for the one case that asserts
 * `StreamRunHandle.startedAt` is Unix epoch milliseconds rather than whatever
 * counter a mock happens to hand out.
 */
export function createWallClockHostServices(): HostServices {
  return {
    connectivity: {
      async isOnline() {
        return true;
      }
    },
    clock: {
      now() {
        return Date.now();
      }
    }
  };
}

export function delay(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    if (ms <= 0 || signal.aborted) {
      resolve();
      return;
    }
    const timer = setTimeout(resolve, ms);
    signal.addEventListener(
      "abort",
      () => {
        clearTimeout(timer);
        resolve();
      },
      { once: true }
    );
  });
}

function awaitAbort(signal: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    if (signal.aborted) {
      resolve();
      return;
    }
    signal.addEventListener("abort", () => resolve(), { once: true });
  });
}

export type ScriptStep =
  | { event: ProviderStreamEvent; delayMs?: number }
  /**
   * Blocks until the run is cancelled, then records that the provider observed
   * its own cancellation. Preferred over a timed delay: it removes the race, and
   * it is the same idiom the Swift and Kotlin fakes use.
   */
  | { waitForCancellation: true }
  /**
   * Calls `ctx.commit()` and records what it returned. A commit step directly after
   * `waitForCancellation` runs once the cancellation has been observed, which is how a
   * provider that asks to commit too late is modelled.
   */
  | { commit: true }
  /**
   * Calls the commit `provider` kept from its own, earlier attempt -- a late callback from
   * an attempt the run has already left -- and records the result as that provider's.
   */
  | { callKeptCommitOf: FakeStreamProvider };

export interface FakeStreamProviderOptions {
  cancel?: "hard" | "soft" | "none";
  type?: "local" | "cloud";
  script: ScriptStep[];
  throwAfter?: unknown;
  throwImmediately?: unknown;
  /** Descriptor-level `supports.streaming`. */
  declaresStreaming?: boolean;
  /** When false the adapter has no `stream()` at all, despite what it declares. */
  implementsStream?: boolean;
  /** Dynamic capability snapshot: a provider that declares streaming but cannot stream here. */
  streamingAvailable?: boolean;
  streamingUnavailableReason?: string;
  /**
   * The task the fake declares. `text_to_speech` adds a speech capability with playback
   * delivery, so the planner routes speech requests to it.
   */
  task?: "text_to_text" | "text_to_speech";
}

export interface FakeStreamProvider extends ProviderAdapter {
  callCount: () => number;
  wasInterrupted: () => boolean;
  /** What each `ctx.commit()` call returned, in call order. */
  commitResults: () => boolean[];
  /** Resolves when the provider has called `ctx.commit()` for the first time. */
  committed: Promise<void>;
  /** Resolves when `stream()` has been entered for the first time. */
  started: Promise<void>;
  /** Calls the `ctx.commit` of this provider's latest attempt and records what it returned. */
  callKeptCommit: () => void;
}

export function createFakeStreamProvider(
  id: string,
  opts: FakeStreamProviderOptions
): FakeStreamProvider {
  const state = { callCount: 0, interrupted: false, commitResults: [] as boolean[] };
  const declaresStreaming = opts.declaresStreaming ?? true;
  const task = opts.task ?? "text_to_text";
  let markCommitted = () => {};
  let markStarted = () => {};
  const committed = new Promise<void>((resolve) => (markCommitted = resolve));
  const started = new Promise<void>((resolve) => (markStarted = resolve));
  const commit = (ctx: ProviderStreamContext) => {
    const result = ctx.commit();
    state.commitResults.push(result);
    markCommitted();
  };
  let keptContext: ProviderStreamContext | undefined;

  const provider: FakeStreamProvider = {
    callCount: () => state.callCount,
    wasInterrupted: () => state.interrupted,
    commitResults: () => [...state.commitResults],
    committed,
    started,
    callKeptCommit: () => commit(keptContext!),
    describe() {
      return {
        id,
        type: opts.type ?? "local",
        transport: "in_process",
        supports: {
          run: true,
          streaming: declaresStreaming,
          realtime: false,
          tools: false,
          reasoningEvents: false,
          structuredOutput: false,
          multimodal: false
        },
        cancel: opts.cancel ?? "soft",
        tasks: [task],
        ...(task === "text_to_speech"
          ? {
              taskCapabilities: [
                {
                  kind: "text_to_speech",
                  inputs: ["text" as const],
                  interaction: { run: true, stream: declaresStreaming },
                  cancel: opts.cancel ?? "soft",
                  outputs: [{ delivery: "playback" as const }],
                  locales: ["de-AT"]
                }
              ]
            }
          : {})
      };
    },
    async capabilities() {
      if (opts.streamingAvailable === false) {
        return {
          available: true,
          streamingAvailable: false,
          ...(opts.streamingUnavailableReason !== undefined
            ? { streamingUnavailableReason: opts.streamingUnavailableReason }
            : {})
        };
      }
      return { available: true };
    },
    async run(req: TaskRequest): Promise<TaskResult> {
      return {
        schemaVersion: "1.0",
        runId: req.requestId || "run-123",
        output: { type: "text", text: "unused" },
        finishReason: "stop",
        telemetry: { providerUsed: id, totalMs: 0 }
      };
    },
    async *stream(
      _req: TaskRequest,
      ctx: ProviderStreamContext
    ): AsyncGenerator<ProviderStreamEvent> {
      state.callCount++;
      keptContext = ctx;
      markStarted();
      if (opts.throwImmediately !== undefined) {
        throw opts.throwImmediately;
      }
      for (const [index, step] of opts.script.entries()) {
        if ("waitForCancellation" in step) {
          await awaitAbort(ctx.signal);
          state.interrupted = true;
          for (const late of opts.script.slice(index + 1)) {
            if ("commit" in late) commit(ctx);
          }
          return;
        }
        if ("commit" in step) {
          commit(ctx);
          continue;
        }
        if ("callKeptCommitOf" in step) {
          step.callKeptCommitOf.callKeptCommit();
          continue;
        }
        await delay(step.delayMs ?? 0, ctx.signal);
        if (ctx.signal.aborted) {
          state.interrupted = true;
          return;
        }
        yield step.event;
      }
      if (opts.throwAfter !== undefined) {
        throw opts.throwAfter;
      }
    }
  };

  if (opts.implementsStream === false) {
    delete provider.stream;
  }

  return provider;
}

/** A provider that does not stream at all — the Mode 1-only case. */
export function createRunOnlyProvider(
  id: string,
  type: "local" | "cloud" = "local"
): FakeStreamProvider {
  return createFakeStreamProvider(id, {
    type,
    script: [],
    declaresStreaming: false,
    implementsStream: false
  });
}

export class MockTelemetryService {
  events: Array<{ type: string; payload: Record<string, unknown> }> = [];
  emit(event: { type: string; payload: Record<string, unknown> }): void {
    this.events.push(event);
  }
}

export async function drain<T>(iterable: AsyncIterable<T>): Promise<T[]> {
  const out: T[] = [];
  for await (const item of iterable) out.push(item);
  return out;
}
