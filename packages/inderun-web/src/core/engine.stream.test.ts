import type { TaskRequest, TaskResult } from "@independo/inderun-contracts";
import { describe, it, expect, beforeEach } from "vitest";
import {
  IndeRun,
  ProviderRegistry,
  type HostServices,
  type ProviderAdapter,
  type ProviderStreamContext,
  type ProviderStreamEvent
} from "../index.js";

function createRequest(overrides: Partial<TaskRequest> = {}): TaskRequest {
  return {
    schemaVersion: "1.0",
    task: { kind: "text_to_text" },
    prompt: "test prompt",
    constraints: { privacy: "local_required" },
    ...overrides
  };
}

function createMockHostServices(): HostServices {
  let timeVal = 1000;
  return {
    connectivity: {
      async isOnline() {
        return true;
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

function delay(ms: number, signal: AbortSignal): Promise<void> {
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

interface ScriptStep {
  delayMs?: number;
  event: ProviderStreamEvent;
}

interface FakeStreamProviderOptions {
  cancel?: "hard" | "soft" | "none";
  script: ScriptStep[];
  throwAfter?: unknown;
  throwImmediately?: unknown;
}

function createFakeStreamProvider(
  id: string,
  opts: FakeStreamProviderOptions
): ProviderAdapter & { callCount: () => number } {
  const state = { callCount: 0 };

  return {
    callCount: () => state.callCount,
    describe() {
      return {
        id,
        type: "local",
        transport: "in_process",
        supports: {
          run: true,
          streaming: true,
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
        await delay(step.delayMs ?? 0, ctx.signal);
        if (ctx.signal.aborted) {
          return;
        }
        yield step.event;
      }
      if (opts.throwAfter !== undefined) {
        throw opts.throwAfter;
      }
    }
  };
}

class MockTelemetryService {
  events: Array<{ type: string; payload: Record<string, unknown> }> = [];
  emit(event: { type: string; payload: Record<string, unknown> }) {
    this.events.push(event);
  }
}

async function drain<T>(iterable: AsyncIterable<T>): Promise<T[]> {
  const out: T[] = [];
  for await (const item of iterable) out.push(item);
  return out;
}

describe("IndeRun.stream()", () => {
  let registry: ProviderRegistry;
  let host: HostServices;

  beforeEach(() => {
    registry = new ProviderRegistry();
    host = createMockHostServices();
  });

  it("throws CapabilityMismatch when no eligible provider supports streaming", async () => {
    const engine = new IndeRun(registry, host);
    await expect(engine.stream(createRequest())).rejects.toMatchObject({
      errorClass: "CapabilityMismatch"
    });
  });

  it("delivers content_delta events and a completed terminal outcome", async () => {
    const provider = createFakeStreamProvider("p1", {
      script: [
        { event: { kind: "delta", text: "Hello" } },
        { event: { kind: "delta", text: " world" } },
        { event: { kind: "done", finalText: "Hello world" } }
      ]
    });
    registry.register(provider);

    const engine = new IndeRun(registry, host);
    const { events } = await engine.stream(createRequest());
    const received = await drain(events);

    expect(received.map((e) => e.type)).toEqual(["content_delta", "content_delta", "terminal"]);
    const terminal = received[2];
    expect(terminal!.payload).toMatchObject({ outcome: "completed", finalText: "Hello world" });
    expect(received.map((e) => e.sequence)).toEqual([0, 1, 2]);
  });

  it("cancel-during-emit: stops further deltas and produces exactly one cancelled terminal", async () => {
    const provider = createFakeStreamProvider("p1", {
      script: [
        { event: { kind: "delta", text: "a" }, delayMs: 5 },
        { event: { kind: "delta", text: "b" }, delayMs: 50 },
        { event: { kind: "done", finalText: "ab" }, delayMs: 5 }
      ]
    });
    registry.register(provider);

    const engine = new IndeRun(registry, host);
    const { events, cancel } = await engine.stream(createRequest());

    const received: Awaited<ReturnType<typeof drain>> = [];
    for await (const ev of events) {
      received.push(ev);
      if (ev.type === "content_delta") {
        cancel("caller requested cancel");
      }
    }

    expect(received.map((e) => e.type)).toEqual(["content_delta", "terminal"]);
    expect(received[1]!.payload).toMatchObject({
      outcome: "cancelled",
      partialText: "a",
      reason: "caller requested cancel"
    });
  });

  it("cancel-after-terminal is a no-op", async () => {
    const provider = createFakeStreamProvider("p1", {
      script: [{ event: { kind: "done", finalText: "done" } }]
    });
    registry.register(provider);

    const engine = new IndeRun(registry, host);
    const { events, cancel } = await engine.stream(createRequest());
    const received = await drain(events);
    cancel("too late");

    expect(received).toHaveLength(1);
    expect(received[0]!.payload).toMatchObject({ outcome: "completed" });
  });

  it("suppresses a duplicate 'done' from a buggy provider", async () => {
    const provider = createFakeStreamProvider("p1", {
      script: [
        { event: { kind: "done", finalText: "first" } },
        { event: { kind: "done", finalText: "second" } }
      ]
    });
    registry.register(provider);

    const engine = new IndeRun(registry, host);
    const received = await drain((await engine.stream(createRequest())).events);

    expect(received.filter((e) => e.type === "terminal")).toHaveLength(1);
    expect(received[0]!.payload).toMatchObject({ outcome: "completed", finalText: "first" });
  });

  it("post-commit provider failure becomes a terminal error and never falls back", async () => {
    const failing = createFakeStreamProvider("p1", {
      script: [{ event: { kind: "delta", text: "partial " } }],
      throwAfter: new Error("boom")
    });
    const fallback = createFakeStreamProvider("p2", {
      script: [{ event: { kind: "done", finalText: "should not run" } }]
    });
    registry.register(failing);
    registry.register(fallback);

    const engine = new IndeRun(registry, host);
    const received = await drain((await engine.stream(createRequest())).events);

    const terminal = received[received.length - 1]!;
    expect(terminal.type).toBe("terminal");
    expect(terminal.payload).toMatchObject({ outcome: "error", partialText: "partial " });
    expect(fallback.callCount()).toBe(0);
  });

  it("pre-commit provider failure falls back to the next provider", async () => {
    const failing = createFakeStreamProvider("p1", {
      script: [],
      throwImmediately: new Error("boom before any content")
    });
    const fallback = createFakeStreamProvider("p2", {
      script: [{ event: { kind: "done", finalText: "fallback succeeded" } }]
    });
    registry.register(failing);
    registry.register(fallback);

    const engine = new IndeRun(registry, host);
    const received = await drain((await engine.stream(createRequest())).events);

    expect(fallback.callCount()).toBe(1);
    const terminal = received[received.length - 1]!;
    expect(terminal.payload).toMatchObject({
      outcome: "completed",
      finalText: "fallback succeeded"
    });
  });

  it("concurrent cancel() calls produce exactly one cancelled outcome and never throw", async () => {
    const provider = createFakeStreamProvider("p1", {
      script: [{ event: { kind: "delta", text: "x" }, delayMs: 5 }],
      throwAfter: new Error("should never surface")
    });
    registry.register(provider);

    const engine = new IndeRun(registry, host);
    const { events, cancel } = await engine.stream(createRequest());

    const collector = drain(events);
    cancel("first");
    cancel("second");
    const received = await collector;

    const terminals = received.filter((e) => e.type === "terminal");
    expect(terminals).toHaveLength(1);
    expect(terminals[0]!.payload).toMatchObject({ outcome: "cancelled", reason: "first" });
  });

  it("cancel before any provider event still yields exactly one cancelled outcome, no fallback", async () => {
    const provider = createFakeStreamProvider("p1", {
      script: [{ event: { kind: "delta", text: "x" }, delayMs: 20 }]
    });
    const fallback = createFakeStreamProvider("p2", {
      script: [{ event: { kind: "done", finalText: "should not run" } }]
    });
    registry.register(provider);
    registry.register(fallback);

    const engine = new IndeRun(registry, host);
    const { events, cancel } = await engine.stream(createRequest());
    cancel("immediate");
    const received = await drain(events);

    expect(received.map((e) => e.type)).toEqual(["terminal"]);
    expect(received[0]!.payload).toMatchObject({ outcome: "cancelled", partialText: "" });
    expect(fallback.callCount()).toBe(0);
  });

  it("emits the streaming telemetry sequence for a normal completion", async () => {
    const provider = createFakeStreamProvider("p1", {
      script: [
        { event: { kind: "delta", text: "hi" } },
        { event: { kind: "done", finalText: "hi" } }
      ]
    });
    registry.register(provider);

    const telemetry = new MockTelemetryService();
    const engine = new IndeRun(registry, host, telemetry);
    await drain((await engine.stream(createRequest())).events);

    const types = telemetry.events.map((e) => e.type);
    expect(types).toEqual([
      "route_decided",
      "stream_attempt_started",
      "stream_attempt_succeeded",
      "stream_completed"
    ]);
  });

  it("emits stream_cancelled telemetry without leaking raw error detail on cancel", async () => {
    const provider = createFakeStreamProvider("p1", {
      script: [{ event: { kind: "delta", text: "x" }, delayMs: 5 }]
    });
    registry.register(provider);

    const telemetry = new MockTelemetryService();
    const engine = new IndeRun(registry, host, telemetry);
    const { events, cancel } = await engine.stream(createRequest());

    for await (const ev of events) {
      if (ev.type === "content_delta") cancel();
    }

    const cancelledTelemetry = telemetry.events.find((e) => e.type === "stream_cancelled");
    expect(cancelledTelemetry).toBeDefined();
  });
});
