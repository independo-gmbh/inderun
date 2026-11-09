import type {
  ProviderDescriptor,
  StreamEvent,
  TaskRequest,
  TaskResult
} from "@independo/inderun-contracts";
import { describe, expect, it } from "vitest";

import { IndeRun, IndeRunException, speak } from "../index.js";
import { adoptOwnedResources } from "./engine.js";
import { createFixtureNeuralSpeechRuntime } from "../providers/neural-speech/fixture-runtime.js";
import { NeuralSpeechWebProvider } from "../providers/neural-speech/provider.js";
import {
  ProviderRegistry,
  type PreparableProviderAdapter,
  type ProviderAdapter,
  type RunContext
} from "../provider.js";
import { createFixtureAudioOutput } from "../test/audio-output-fixture.js";
import {
  createFakeStreamProvider,
  createMockHostServices,
  createRequest,
  drain
} from "../test/stream-fakes.js";

function deferred<T = void>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => (resolve = r));
  return { promise, resolve };
}

function engineOf(...providers: ProviderAdapter[]): IndeRun {
  const registry = new ProviderRegistry();
  for (const provider of providers) registry.register(provider);
  return new IndeRun(registry, createMockHostServices());
}

function terminals(events: StreamEvent[]): StreamEvent[] {
  return events.filter((event) => event.type === "terminal");
}

async function expectEngineClosed(promise: Promise<unknown>): Promise<void> {
  const error = await promise.then(
    () => undefined,
    (e: unknown) => e
  );
  expect(error).toBeInstanceOf(IndeRunException);
  expect(error).toMatchObject({
    errorClass: "Unavailable",
    retryable: false,
    details: { code: "engine_closed" }
  });
}

/** A text provider whose run() waits for `release`. */
function gatedRunProvider(id: string, release: Promise<void>): ProviderAdapter {
  const base = createFakeStreamProvider(id, { script: [] });
  return {
    ...base,
    async run(request: TaskRequest, context: RunContext): Promise<TaskResult> {
      await release;
      return base.run(request, context);
    }
  };
}

const textRequest: TaskRequest = createRequest();

describe("IndeRun.close()", () => {
  it("close cancels an in-flight stream: exactly one cancelled terminal, no events after", async () => {
    const provider = createFakeStreamProvider("p1", {
      script: [{ event: { kind: "delta", text: "a" } }, { waitForCancellation: true }]
    });
    const engine = engineOf(provider);
    const { events } = await engine.stream(createRequest());
    const collected = drain(events);
    await provider.started;

    await engine.close();
    const all = await collected;

    const ended = terminals(all);
    expect(ended).toHaveLength(1);
    expect(ended[0]).toBe(all.at(-1));
    expect(ended[0]!.payload).toMatchObject({ outcome: "cancelled" });
  });

  it("close cancels an in-flight prepare", async () => {
    const entered = deferred();
    const never = deferred();
    const provider: PreparableProviderAdapter = {
      ...createFakeStreamProvider("p1", { script: [] }),
      describe: (): ProviderDescriptor => ({
        ...createFakeStreamProvider("p1", { script: [] }).describe(),
        taskCapabilities: [
          {
            kind: "text_to_text",
            inputs: ["text"],
            interaction: { run: true, stream: false, prepare: true },
            cancel: "none",
            outputs: [{ delivery: "inline" }]
          }
        ]
      }),
      capabilities: async () => ({
        available: true,
        taskCapabilities: [{ kind: "text_to_text", readiness: "cold" as const }]
      }),
      async *prepare() {
        entered.resolve();
        await never.promise;
        yield { fractionCompleted: 1 };
      }
    };
    const engine = engineOf(provider);
    const run = await engine.prepare();
    const collected = drain(run.events);
    await entered.promise;

    await engine.close();
    const all = await collected;

    expect(terminals(all)).toHaveLength(1);
    expect(all.at(-1)!.payload).toMatchObject({ outcome: "cancelled" });
  });

  it("close waits for an in-flight run to settle", async () => {
    const release = deferred();
    const engine = engineOf(gatedRunProvider("p1", release.promise));
    const run = engine.run(textRequest);
    await new Promise((resolve) => setTimeout(resolve, 0));

    let closed = false;
    const closing = engine.close().then(() => (closed = true));
    await new Promise((resolve) => setTimeout(resolve, 5));
    expect(closed).toBe(false);

    release.resolve();
    await closing;
    expect(closed).toBe(true);
    // The run was not cancelled: it completes normally.
    await expect(run).resolves.toMatchObject({ output: { type: "text" } });
  });

  it("calls after close reject with engine_closed", async () => {
    const engine = engineOf(createFakeStreamProvider("p1", { script: [] }));
    await engine.close();

    await expectEngineClosed(engine.run(textRequest));
    await expectEngineClosed(engine.stream(textRequest));
    await expectEngineClosed(engine.prepare());
    // checkCapabilities cannot throw on every SDK, so it reports an empty snapshot.
    await expect(engine.checkCapabilities()).resolves.toEqual([]);
    await expectEngineClosed(engine.readArtifact({ artifactId: "x" }));
    await expect(
      engine.disposeArtifact({ id: "x", owner: "engine", mediaType: "audio/wav" })
    ).resolves.toBeUndefined();
  });

  it("a call made from inside a cancel listener during close rejects with engine_closed", async () => {
    const base = createFakeStreamProvider("p1", { script: [{ waitForCancellation: true }] });
    const holder: { engine?: IndeRun } = {};
    let fromListener: Promise<unknown> | undefined;
    const provider: ProviderAdapter = {
      ...base,
      async *stream(request, context) {
        context.signal.addEventListener("abort", () => {
          fromListener = holder.engine!.run(textRequest);
        });
        yield* base.stream!(request, context);
      }
    };
    const engine = engineOf(provider);
    holder.engine = engine;
    const { events } = await engine.stream(createRequest());
    const collected = drain(events);
    await base.started;

    await engine.close();
    await collected;

    expect(fromListener).toBeDefined();
    await expectEngineClosed(fromListener!);
  });

  it("a stream never pulled does not block close; a later pull yields one cancelled terminal", async () => {
    const provider = createFakeStreamProvider("p1", {
      script: [{ event: { kind: "delta", text: "a" } }]
    });
    const engine = engineOf(provider);
    const { events } = await engine.stream(createRequest());

    await engine.close();
    const all = await drain(events);

    expect(terminals(all)).toHaveLength(1);
    expect(all.at(-1)).toBe(terminals(all)[0]);
    expect(all.at(-1)!.payload).toMatchObject({ outcome: "cancelled" });
  });

  it("a consumer paused between events sees one cancelled terminal after close", async () => {
    const provider = createFakeStreamProvider("p1", {
      script: [{ event: { kind: "delta", text: "a" } }, { waitForCancellation: true }]
    });
    const engine = engineOf(provider);
    const { events } = await engine.stream(createRequest());
    const iterator = events[Symbol.asyncIterator]();
    const seen: StreamEvent[] = [];
    for (;;) {
      const next = await iterator.next();
      if (next.done === true) break;
      seen.push(next.value);
      if (next.value.type === "content_delta") break;
    }
    // The consumer now stops pulling; close must neither hang on it nor lose the terminal.
    await engine.close();
    for (;;) {
      const next = await iterator.next();
      if (next.done === true) break;
      seen.push(next.value);
    }

    expect(terminals(seen)).toHaveLength(1);
    expect(seen.at(-1)).toBe(terminals(seen)[0]);
    expect(seen.at(-1)!.payload).toMatchObject({ outcome: "cancelled" });
  });

  it("close disposes engine-owned artifacts", async () => {
    const provider: ProviderAdapter = {
      describe: () => ({
        id: "art",
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
        cancel: "none",
        tasks: ["text_to_speech"],
        taskCapabilities: [
          {
            kind: "text_to_speech",
            inputs: ["text"],
            interaction: { run: true, stream: false },
            cancel: "none",
            outputs: [{ delivery: "artifact", mediaTypes: ["audio/wav"] }],
            locales: ["de-AT"]
          }
        ]
      }),
      capabilities: async () => ({ available: true }),
      async run(_request, context) {
        const writer = context.artifacts.create({ mediaType: "audio/wav" });
        writer.write(new Uint8Array([1, 2, 3]));
        const artifact = writer.finish();
        return {
          schemaVersion: "1.0",
          runId: context.runId,
          output: { type: "artifact", artifact },
          finishReason: "stop",
          telemetry: { providerUsed: "art", totalMs: 0 }
        };
      }
    };
    const engine = engineOf(provider);
    const result = await engine.run({
      schemaVersion: "1.0",
      task: { kind: "text_to_speech" },
      speech: { text: "Hallo", locale: "de-AT" },
      delivery: { mode: "artifact", mediaTypes: ["audio/wav"] },
      constraints: { privacy: "local_required" }
    });
    const artifact = result.output.artifact!;
    await expect(engine.readArtifact({ artifactId: artifact.id })).resolves.toMatchObject({
      totalBytes: 3
    });

    await engine.close();

    // The store is empty; only the closed engine's own rejection is observable from outside,
    // so check the bytes are gone through a second engine sharing nothing: dispose was called.
    expect(engineStoreSize(engine)).toBe(0);
  });

  it("concurrent_close_closes_once", async () => {
    let closes = 0;
    const registry = new ProviderRegistry();
    registry.register(createFakeStreamProvider("p1", { script: [] }));
    const engine = new IndeRun(registry, createMockHostServices());
    adoptOwnedResources(engine, [
      {
        close: async () => {
          closes += 1;
        }
      }
    ]);

    const first = engine.close();
    const second = engine.close();
    await Promise.all([first, second]);
    await engine.close();

    expect(closes).toBe(1);
  });

  it("close_racing_stream_start", async () => {
    const provider = createFakeStreamProvider("p1", {
      script: [{ waitForCancellation: true }]
    });
    const engine = engineOf(provider);

    // stream() is still routing when close() begins.
    const starting = engine.stream(createRequest()).then(
      (run) => ({ run }),
      (error: unknown) => ({ error })
    );
    const closing = engine.close();
    const [outcome] = await Promise.all([starting, closing]);

    if ("error" in outcome) {
      expect(outcome.error).toMatchObject({ details: { code: "engine_closed" } });
    } else {
      const all = await drain(outcome.run.events);
      expect(terminals(all)).toHaveLength(1);
      expect(all.at(-1)!.payload).toMatchObject({ outcome: "cancelled" });
    }
    await expectEngineClosed(engine.stream(createRequest()));
  });

  it("close does not close an app-supplied runtime", async () => {
    const pkg = {
      id: "tts",
      format: "onnx" as const,
      tasks: ["text_to_speech" as const],
      source: { sourceType: "app_managed" as const },
      speech: {
        pipeline: "fixture",
        sampleRate: 24000,
        graphs: { acoustic: "acoustic.onnx" },
        voices: [{ id: "v_de", name: "Fixture German", locales: ["de-DE"] }]
      }
    };
    const runtime = createFixtureNeuralSpeechRuntime();
    const audio = createFixtureAudioOutput();
    const hostServices = { ...createMockHostServices(), audioOutput: audio.service };
    const build = (withFallback: boolean) => {
      const registry = new ProviderRegistry();
      const neural = new NeuralSpeechWebProvider({ modelPackage: pkg, runtime });
      registry.register(neural);
      const fallback = createFakeStreamProvider("fallback", {
        task: "text_to_speech",
        script: [{ event: { kind: "result", output: { type: "playback", playback: {} } } }]
      });
      if (withFallback) registry.register(fallback);
      return {
        engine: new IndeRun(registry, hostServices, {
          modelProfiles: { chain: [neural.describe().id, "fallback"] }
        }),
        fallback
      };
    };
    const a = build(true);
    const b = build(true);

    await a.engine.close();
    const spoken = await (
      await speak(b.engine, { text: "Hallo", locale: "de-DE", model: "chain" })
    ).result;
    expect(spoken.outcome.outcome).toBe("completed");
    expect(runtime.synthesized.length).toBeGreaterThan(0);
    expect(b.fallback.callCount()).toBe(0);

    await runtime.close!();
    const after = await (
      await speak(b.engine, { text: "Hallo", locale: "de-DE", model: "chain" })
    ).result;
    expect(after.outcome.outcome).toBe("completed");
    expect(b.fallback.callCount()).toBe(1);
    // The closed runtime reports itself unavailable, so routing skips the neural provider.
    expect(after.provenance?.routeRejections).toMatchObject([
      { providerId: "local.onnx.speech.web:tts", codes: ["capability_unavailable"] }
    ]);
  });
});

/** Number of artifacts the engine still holds, read through its private store. */
function engineStoreSize(engine: IndeRun): number {
  const store = (engine as unknown as { artifacts: { artifacts: Map<string, unknown> } }).artifacts;
  return store.artifacts.size;
}
