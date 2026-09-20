import type { TaskRequest, TaskResult } from "@independo/inderun-contracts";
import type {
  HostServices,
  ProviderAdapter,
  ProviderStreamContext,
  ProviderStreamEvent
} from "../index.js";

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
  | { waitForCancellation: true };

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
}

export interface FakeStreamProvider extends ProviderAdapter {
  callCount: () => number;
  wasInterrupted: () => boolean;
}

export function createFakeStreamProvider(
  id: string,
  opts: FakeStreamProviderOptions
): FakeStreamProvider {
  const state = { callCount: 0, interrupted: false };
  const declaresStreaming = opts.declaresStreaming ?? true;

  const provider: FakeStreamProvider = {
    callCount: () => state.callCount,
    wasInterrupted: () => state.interrupted,
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
        tasks: ["text_to_text"]
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
      if (opts.throwImmediately !== undefined) {
        throw opts.throwImmediately;
      }
      for (const step of opts.script) {
        if ("waitForCancellation" in step) {
          await awaitAbort(ctx.signal);
          state.interrupted = true;
          return;
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
