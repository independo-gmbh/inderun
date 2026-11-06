import type {
  AudioOutputFormat,
  AudioOutputService,
  ModelPackage,
  TaskRequest
} from "@independo/inderun-contracts";
import { normalizeSpeechText } from "@independo/inderun-route-core-wasm";
import { describe, expect, it } from "vitest";

import { ArtifactStore, type ArtifactSink } from "../../core/artifacts.js";
import { IndeRunException } from "../../core/errors.js";
import type { HostServices } from "../../core/host.js";
import type { RunContext } from "../../core/provider.js";
import { IndeRun } from "../../index.js";
import { ProviderRegistry } from "../../provider.js";
import { createFixtureAudioOutput } from "../../test/audio-output-fixture.js";
import { createFakeStreamProvider, createWallClockHostServices } from "../../test/stream-fakes.js";
import {
  createFixtureNeuralSpeechRuntime,
  type FixtureNeuralSpeechRuntimeOptions
} from "./fixture-runtime.js";
import { NeuralSpeechWebProvider, type NeuralSpeechProviderOptions } from "./provider.js";
import {
  NeuralSpeechRuntimeError,
  type NeuralSpeechRuntime,
  type NeuralSpeechSynthesisInput,
  type PcmChunk
} from "./runtime.js";

const PACKAGE: ModelPackage = {
  id: "fixture-tts",
  version: "1",
  format: "onnx",
  tasks: ["text_to_speech"],
  source: { sourceType: "app_managed" },
  speech: {
    pipeline: "fixture",
    sampleRate: 24000,
    graphs: { acoustic: "acoustic.onnx" },
    frontend: { kind: "grapheme" },
    voices: [
      { id: "v_de", name: "Fixture German", locales: ["de-DE", "de-AT"], gender: "female" },
      { id: "v_at", name: "Fixture Austrian", locales: ["de-AT"] },
      { id: "v_en", name: "Fixture English", locales: ["en-US"], gender: "male" }
    ]
  }
};

function createProvider(
  runtimeOptions: FixtureNeuralSpeechRuntimeOptions = {},
  overrides: Partial<NeuralSpeechProviderOptions> = {}
) {
  const runtime = createFixtureNeuralSpeechRuntime(runtimeOptions);
  const provider = new NeuralSpeechWebProvider({ modelPackage: PACKAGE, runtime, ...overrides });
  return { provider, runtime };
}

function speechRequest(overrides: Partial<TaskRequest> = {}): TaskRequest {
  return {
    schemaVersion: "1.0",
    task: { kind: "text_to_speech" },
    speech: { text: "Hallo Welt.", locale: "de-AT" },
    delivery: { mode: "playback" },
    ...overrides
  };
}

function runContext(hostServices: HostServices) {
  let commits = 0;
  const commit = () => {
    commits += 1;
    return true;
  };
  const context: RunContext = {
    runId: "run-1",
    hostServices,
    commit,
    artifacts: new ArtifactStore().attempt(commit)
  };
  return { context, commitCount: () => commits };
}

async function rejection(promise: Promise<unknown>): Promise<IndeRunException> {
  try {
    await promise;
  } catch (error) {
    expect(error).toBeInstanceOf(IndeRunException);
    return error as IndeRunException;
  }
  throw new Error("expected a rejection");
}

const host = createWallClockHostServices();

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** The fixture runtime, with `beforeSentence(n)` awaited before the n-th sentence (from 1). */
function pacedRuntime(beforeSentence: (call: number) => Promise<void>): NeuralSpeechRuntime {
  const fixture = createFixtureNeuralSpeechRuntime();
  let calls = 0;
  return {
    availability: (pkg) => fixture.availability(pkg),
    prepare: (pkg) => fixture.prepare(pkg),
    async *synthesize(input: NeuralSpeechSynthesisInput): AsyncGenerator<PcmChunk> {
      calls += 1;
      await beforeSentence(calls);
      yield* fixture.synthesize(input);
    }
  };
}

/** Holds the thread until `ms` of wall time have passed: the sink's calls are synchronous. */
function spin(ms: number): void {
  const until = Date.now() + ms;
  while (Date.now() < until) {
    // Busy-wait on the clock the provider reads.
  }
}

/** Wraps `inner`, recording what its writers were handed; `onWrite` runs before each write. */
function spyArtifacts(inner: ArtifactSink, onWrite: () => void = () => undefined) {
  const written: Uint8Array[] = [];
  let finishCalls = 0;
  let aborts = 0;
  const sink: ArtifactSink = {
    create(spec) {
      const writer = inner.create(spec);
      return {
        write(bytes) {
          onWrite();
          written.push(bytes.slice());
          writer.write(bytes);
        },
        finish() {
          finishCalls += 1;
          return writer.finish();
        },
        abort() {
          aborts += 1;
          writer.abort();
        }
      };
    }
  };
  return { sink, written, finishCalls: () => finishCalls, aborts: () => aborts };
}

/** The data section of a canonical WAV, as samples. */
function wavSamples(bytes: Uint8Array): number[] {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const samples: number[] = [];
  for (let at = 44; at < bytes.byteLength; at += 2) samples.push(view.getInt16(at, true));
  return samples;
}

describe("NeuralSpeechWebProvider", () => {
  it("describes a hard-cancel in-process speech provider", () => {
    const { provider } = createProvider();
    expect(provider.id).toBe("local.onnx.speech.web:fixture-tts");
    expect(provider.describe()).toEqual({
      id: "local.onnx.speech.web:fixture-tts",
      type: "local",
      model: "fixture-tts",
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
      cancel: "hard",
      tasks: ["text_to_speech"],
      taskCapabilities: [
        {
          kind: "text_to_speech",
          inputs: ["text"],
          interaction: { prepare: true, run: true, stream: true },
          cancel: "hard",
          outputs: [{ delivery: "playback" }, { delivery: "artifact", mediaTypes: ["audio/wav"] }],
          locales: ["de-DE", "de-AT", "en-US"],
          privacy: { dataLeavesDevice: false }
        }
      ],
      privacy: { dataLeavesDevice: false }
    });
  });

  it("takes an explicit id", () => {
    const { provider } = createProvider({}, { id: "speech" });
    expect(provider.describe().id).toBe("speech");
  });

  it("capability check never loads the model and reports it cold", async () => {
    const { provider, runtime } = createProvider();
    await provider.capabilities(host);
    const capabilities = await provider.capabilities(host);

    expect(runtime.prepareCalls).toBe(0);
    expect(capabilities.available).toBe(true);
    expect(capabilities.taskCapabilities?.[0]?.readiness).toBe("cold");
    expect(capabilities.taskCapabilities?.[0]?.voices).toEqual([
      {
        id: "v_de",
        name: "Fixture German",
        locale: "de-DE",
        locales: ["de-DE", "de-AT"],
        gender: "female",
        networkRequired: false
      },
      {
        id: "v_at",
        name: "Fixture Austrian",
        locale: "de-AT",
        locales: ["de-AT"],
        networkRequired: false
      },
      {
        id: "v_en",
        name: "Fixture English",
        locale: "en-US",
        locales: ["en-US"],
        gender: "male",
        networkRequired: false
      }
    ]);
  });

  it("refuses a malformed package, a package without speech, an unsupported source type, an unsupported platform, and what the runtime refuses", async () => {
    const voice = PACKAGE.speech!.voices[0];
    const cases: {
      modelPackage: ModelPackage;
      runtime?: FixtureNeuralSpeechRuntimeOptions;
      reason: string;
    }[] = [
      {
        modelPackage: { ...PACKAGE, speech: { ...PACKAGE.speech!, voices: [voice, voice] } },
        reason: "model package malformed:"
      },
      {
        modelPackage: { id: "text-only", format: "onnx", tasks: ["text_to_text"] },
        reason: "unsupported task:"
      },
      {
        modelPackage: { ...PACKAGE, source: { sourceType: "filesystem", ref: "/models/tts" } },
        reason: "model source unavailable:"
      },
      {
        modelPackage: { ...PACKAGE, runtime: { platforms: ["ios", "android"] } },
        reason: "platform unsupported:"
      },
      {
        modelPackage: PACKAGE,
        runtime: { availability: { available: false, reason: "unsupported pipeline: kokoro" } },
        reason: "unsupported pipeline: kokoro"
      }
    ];

    for (const entry of cases) {
      const runtime = createFixtureNeuralSpeechRuntime(entry.runtime);
      const provider = new NeuralSpeechWebProvider({ modelPackage: entry.modelPackage, runtime });
      const capabilities = await provider.capabilities(host);
      expect(capabilities.available).toBe(false);
      if (entry.runtime === undefined) {
        expect(capabilities.reason?.startsWith(entry.reason)).toBe(true);
      } else {
        expect(capabilities.reason).toBe(entry.reason);
      }
    }
  });

  it("remembers a load failure", async () => {
    const { provider, runtime } = createProvider({
      prepareResult: { available: false, reason: "graph missing" }
    });
    const preparing = (async () => {
      for await (const step of provider.prepare({
        runId: "prep-1",
        hostServices: host,
        task: "text_to_speech",
        signal: new AbortController().signal
      })) {
        void step;
      }
    })();

    const error = await rejection(preparing);
    expect(error.errorClass).toBe("CapabilityMismatch");
    expect(await provider.capabilities(host)).toEqual({
      available: false,
      reason: "graph missing"
    });
    expect(runtime.prepareCalls).toBe(1);
  });

  it("reports readiness absent once prepared", async () => {
    const { provider, runtime } = createProvider();
    for await (const step of provider.prepare({
      runId: "prep-1",
      hostServices: host,
      task: "text_to_speech",
      signal: new AbortController().signal
    })) {
      void step;
    }

    const capabilities = await provider.capabilities(host);
    expect(runtime.prepareCalls).toBe(1);
    expect(capabilities.available).toBe(true);
    expect(capabilities.taskCapabilities?.[0]?.readiness).toBeUndefined();
    expect(capabilities.taskCapabilities?.[0]?.voices).toHaveLength(3);
  });

  it("reports a runtime's not_prepared hint for the task and every voice until loaded", async () => {
    const { provider } = createProvider({
      availability: { available: true, readiness: "not_prepared" }
    });

    const capabilities = await provider.capabilities(host);
    const task = capabilities.taskCapabilities?.[0];
    expect(capabilities.available).toBe(true);
    expect(task?.readiness).toBe("not_prepared");
    expect(task?.voices?.map((voice) => voice.readiness)).toEqual([
      "not_prepared",
      "not_prepared",
      "not_prepared"
    ]);

    for await (const step of provider.prepare({
      runId: "prep-1",
      hostServices: host,
      task: "text_to_speech",
      signal: new AbortController().signal
    })) {
      void step;
    }
    const after = await provider.capabilities(host);
    expect(after.taskCapabilities?.[0]?.readiness).toBeUndefined();
    expect(after.taskCapabilities?.[0]?.voices?.map((voice) => voice.readiness)).toEqual([
      undefined,
      undefined,
      undefined
    ]);
  });

  it("leaves voice readiness absent without a hint", async () => {
    const { provider } = createProvider();
    const task = (await provider.capabilities(host)).taskCapabilities?.[0];
    expect(task?.readiness).toBe("cold");
    expect(task?.voices?.every((voice) => !("readiness" in voice))).toBe(true);
  });

  it("refuses an inline delivery and a non-speech request before commit", async () => {
    const { provider, runtime } = createProvider();
    const audio = createFixtureAudioOutput();
    const { context, commitCount } = runContext({ ...host, audioOutput: audio.service });

    const inline = await rejection(
      provider.run(speechRequest({ delivery: { mode: "inline" } }), context)
    );
    const text = await rejection(
      provider.run(
        { schemaVersion: "1.0", task: { kind: "text_to_text" }, prompt: "Hello" },
        context
      )
    );

    expect(inline.errorClass).toBe("CapabilityMismatch");
    expect(text.errorClass).toBe("CapabilityMismatch");
    expect(commitCount()).toBe(0);
    expect(audio.sessions).toHaveLength(0);
    expect(runtime.synthesized).toHaveLength(0);
  });

  it("stops the session when cancelled while the audio drains", async () => {
    const { provider } = createProvider();
    let drainStarted!: () => void;
    const draining = new Promise<void>((resolve) => (drainStarted = resolve));
    let releaseDrain: (() => void) | undefined;
    let stops = 0;
    const service: AudioOutputService = {
      async open() {
        return {
          async write() {},
          drain() {
            drainStarted();
            return new Promise<void>((resolve) => (releaseDrain = resolve));
          },
          stop() {
            stops += 1;
            releaseDrain?.();
          },
          firstAudioMs: () => 0
        };
      }
    };
    const controller = new AbortController();
    const { context, commitCount } = runContext({ ...host, audioOutput: service });

    const events: unknown[] = [];
    const consumed = (async () => {
      for await (const event of provider.stream(speechRequest(), {
        ...context,
        signal: controller.signal
      })) {
        events.push(event);
      }
    })();
    await draining;
    controller.abort();
    await consumed;

    expect(commitCount()).toBe(1);
    expect(stops).toBeGreaterThan(0);
    expect(events).toEqual([]);
  });

  it("times out before commit when the first chunk is slower than timeoutMs", async () => {
    const { provider } = createProvider({ delayMs: 2000 }, { timeoutMs: 20 });
    const audio = createFixtureAudioOutput();
    const { context, commitCount } = runContext({ ...host, audioOutput: audio.service });

    const error = await rejection(provider.run(speechRequest(), context));

    expect(error.errorClass).toBe("Timeout");
    expect(commitCount()).toBe(0);
    expect(audio.sessions[0]?.stopped).toBe(true);
    expect(audio.sessions[0]?.writtenFrames).toBe(0);
  });

  it("does not time out a slow sentence after commit", async () => {
    const runtime = pacedRuntime((call) => (call === 2 ? sleep(400) : Promise.resolve()));
    const provider = new NeuralSpeechWebProvider({ modelPackage: PACKAGE, runtime });
    const audio = createFixtureAudioOutput();
    const { context, commitCount } = runContext({ ...host, audioOutput: audio.service });

    const result = await provider.run(
      speechRequest({
        speech: { text: "Hallo Welt. Wie geht es dir?", locale: "de-AT" },
        constraints: { timeoutMs: 200 }
      }),
      context
    );

    expect(result.output.type).toBe("playback");
    expect(commitCount()).toBe(1);
    // 27 characters across the two sentences: 1350 ms.
    expect(audio.sessions[0]?.writtenFrames).toBe(32400);
  });

  it("bounds an artifact's whole synthesis with timeoutMs", async () => {
    // Each sentence alone fits the budget; both together do not.
    const runtime = pacedRuntime(() => sleep(150));
    const provider = new NeuralSpeechWebProvider({ modelPackage: PACKAGE, runtime });
    const { context, commitCount } = runContext(host);

    const error = await rejection(
      provider.run(
        speechRequest({
          speech: { text: "Hallo Welt. Wie geht es dir?", locale: "de-AT" },
          delivery: { mode: "artifact" },
          constraints: { timeoutMs: 200 }
        }),
        context
      )
    );

    expect(error.errorClass).toBe("Timeout");
    expect(commitCount()).toBe(0);
  });

  it("times out without waiting for a runtime that ignores the abort", async () => {
    let release!: () => void;
    const gate = new Promise<void>((resolve) => (release = resolve));
    let pending = true;
    const runtime = pacedRuntime(async () => {
      await gate;
      pending = false;
    });
    const provider = new NeuralSpeechWebProvider({ modelPackage: PACKAGE, runtime, timeoutMs: 20 });
    const audio = createFixtureAudioOutput();
    const { context, commitCount } = runContext({ ...host, audioOutput: audio.service });

    const outcome = await Promise.race([
      rejection(provider.run(speechRequest(), context)),
      sleep(1000).then(() => "still waiting" as const)
    ]);

    expect(outcome).not.toBe("still waiting");
    expect((outcome as IndeRunException).errorClass).toBe("Timeout");
    expect(pending).toBe(true);
    expect(commitCount()).toBe(0);
    expect(audio.sessions[0]?.stopped).toBe(true);
    release();
  });

  it("treats a timeoutMs of zero or less as unbounded", async () => {
    const { provider } = createProvider({ delayMs: 5 }, { timeoutMs: 0 });
    const audio = createFixtureAudioOutput();
    const { context, commitCount } = runContext({ ...host, audioOutput: audio.service });

    const result = await provider.run(speechRequest(), context);

    expect(result.output.type).toBe("playback");
    expect(commitCount()).toBe(1);
  });

  it("reports a runtime whose availability check throws as unavailable", async () => {
    const fixture = createFixtureNeuralSpeechRuntime();
    const runtime: NeuralSpeechRuntime = {
      availability: () => Promise.reject(new Error("onnxruntime-web is missing")),
      prepare: (pkg) => fixture.prepare(pkg),
      synthesize: (input) => fixture.synthesize(input)
    };
    const provider = new NeuralSpeechWebProvider({ modelPackage: PACKAGE, runtime });

    expect(await provider.capabilities(host)).toEqual({
      available: false,
      reason: "runtime availability failed: onnxruntime-web is missing"
    });

    const registry = new ProviderRegistry();
    registry.register(provider);
    registry.register(createFakeStreamProvider("other", { task: "text_to_speech", script: [] }));
    const snapshots = await new IndeRun(registry, host).checkCapabilities();
    expect(snapshots.map((entry) => [entry.providerId, entry.capabilities.available])).toEqual([
      [provider.id, false],
      ["other", true]
    ]);
  });

  it("refuses a package that is not mono", async () => {
    const runtime = createFixtureNeuralSpeechRuntime();
    const provider = new NeuralSpeechWebProvider({
      modelPackage: { ...PACKAGE, speech: { ...PACKAGE.speech!, channels: 2 } },
      runtime
    });

    expect(await provider.capabilities(host)).toEqual({
      available: false,
      reason: "unsupported channels: 2"
    });
  });

  it("counts firstAudioMs from the instant before open() was called", async () => {
    const { provider } = createProvider();
    const audio = createFixtureAudioOutput();
    // The fixture session reports 0: its first write happens at once on its virtual clock.
    const slowOpen: AudioOutputService = {
      async open(format: AudioOutputFormat, signal) {
        await sleep(200);
        return audio.service.open(format, signal);
      }
    };
    const { context } = runContext({ ...host, audioOutput: slowOpen });

    const result = await provider.run(speechRequest(), context);

    const timing = result.output.playback?.timing;
    expect(audio.sessions[0]?.firstAudioMs()).toBe(0);
    // The session measures from the start of its own open(), so the slow open is counted once,
    // by the session; counting from when open() returned would add it a second time.
    expect(timing?.firstAudioMs).toBeDefined();
    expect(timing!.firstAudioMs!).toBeLessThan(200);
  });

  it("copies each chunk when buffering an artifact, so a runtime may reuse its buffer", async () => {
    const fixture = createFixtureNeuralSpeechRuntime();
    const runtime: NeuralSpeechRuntime = {
      availability: (pkg) => fixture.availability(pkg),
      prepare: (pkg) => fixture.prepare(pkg),
      async *synthesize(): AsyncGenerator<PcmChunk> {
        const scratch = new Int16Array(4);
        for (let fill = 1; fill <= 3; fill += 1) {
          scratch.fill(fill);
          yield { samples: scratch, sampleRate: 24000, isLast: fill === 3 };
        }
      }
    };
    const provider = new NeuralSpeechWebProvider({ modelPackage: PACKAGE, runtime });
    const { context } = runContext(host);
    const spy = spyArtifacts(context.artifacts);

    const result = await provider.run(speechRequest({ delivery: { mode: "artifact" } }), {
      ...context,
      artifacts: spy.sink
    });

    expect(result.output.type).toBe("artifact");
    expect(spy.written).toHaveLength(1);
    expect(wavSamples(spy.written[0]!)).toEqual([1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3]);
  });

  it("bounds an artifact with timeoutMs up to finish()", async () => {
    const { provider } = createProvider({}, { timeoutMs: 500 });
    const { context, commitCount } = runContext(host);
    // Synthesis is instant, well inside the budget even on a loaded runner; writing the WAV takes
    // the run past its deadline.
    const spy = spyArtifacts(context.artifacts, () => spin(600));

    const error = await rejection(
      provider.run(speechRequest({ delivery: { mode: "artifact" } }), {
        ...context,
        artifacts: spy.sink
      })
    );

    expect(error.errorClass).toBe("Timeout");
    expect(spy.finishCalls()).toBe(0);
    expect(spy.aborts()).toBe(1);
    expect(commitCount()).toBe(0);
  });
});

describe("NeuralSpeechWebProvider text normalization", () => {
  function normalizingRuntime() {
    const runtime = createFixtureNeuralSpeechRuntime();
    const hooked: NeuralSpeechRuntime & { calls: { text: string; locale: string }[] } = {
      calls: [],
      availability: (pkg) => runtime.availability(pkg),
      prepare: (pkg) => runtime.prepare(pkg),
      synthesize: (input) => runtime.synthesize(input),
      async normalizeText(_pkg, text, locale) {
        hooked.calls.push({ text, locale });
        return normalizeSpeechText(text, locale);
      }
    };
    return { hooked, runtime };
  }

  async function speak(
    runtime: NeuralSpeechRuntime,
    text: string,
    locale: string,
    pkg: ModelPackage = PACKAGE
  ) {
    const provider = new NeuralSpeechWebProvider({ modelPackage: pkg, runtime });
    const { context } = runContext(host);
    await provider.run(
      speechRequest({ speech: { text, locale }, delivery: { mode: "artifact" } }),
      context
    );
  }

  it("normalizes the whole text before it is split into sentences", async () => {
    const { hooked, runtime } = normalizingRuntime();
    await speak(hooked, "Am 3. Mai, z. B. um 14:30 Uhr.", "de-DE");
    expect(runtime.synthesized.map((s) => s.text)).toEqual([
      "Am dritten Mai, zum Beispiel um vierzehn Uhr dreißig."
    ]);
    expect(hooked.calls).toHaveLength(1);
  });

  it("speaks the voice's locale when the request's language differs", async () => {
    const { hooked, runtime } = normalizingRuntime();
    const onlyDe: ModelPackage = {
      ...PACKAGE,
      speech: {
        ...(PACKAGE.speech as NonNullable<ModelPackage["speech"]>),
        voices: [{ id: "v_de", name: "German", locales: ["de-DE"] }]
      }
    };
    await speak(hooked, "Am 3.1.2026.", "de-AT", onlyDe);
    expect(runtime.synthesized.map((s) => s.text)).toEqual([
      "Am dritten Jänner zweitausendsechsundzwanzig."
    ]);
    expect(hooked.calls[0]?.locale).toBe("de-AT");
  });

  it("uses the voice's locale when the languages differ", async () => {
    const { hooked } = normalizingRuntime();
    await speak(hooked, "Am 3. Mai.", "en-US", {
      ...PACKAGE,
      speech: {
        ...(PACKAGE.speech as NonNullable<ModelPackage["speech"]>),
        voices: [{ id: "v_de", name: "German", locales: ["de-DE"] }]
      }
    });
    expect(hooked.calls[0]?.locale).toBe("de-DE");
  });

  it("hands the text over unchanged to a runtime without the hook", async () => {
    const runtime = createFixtureNeuralSpeechRuntime();
    await speak(runtime, "Es ist 14:30 Uhr.", "de-DE");
    expect(runtime.synthesized.map((s) => s.text)).toEqual(["Es ist 14:30 Uhr."]);
  });

  it("fails Unavailable before any audio when the normalization hook is unavailable", async () => {
    const runtime = createFixtureNeuralSpeechRuntime();
    const hooked: NeuralSpeechRuntime = {
      availability: (pkg) => runtime.availability(pkg),
      prepare: (pkg) => runtime.prepare(pkg),
      synthesize: (input) => runtime.synthesize(input),
      normalizeText() {
        throw new NeuralSpeechRuntimeError("unavailable", "speech text frontend unavailable: boom");
      }
    };
    const provider = new NeuralSpeechWebProvider({ modelPackage: PACKAGE, runtime: hooked });
    const audio = createFixtureAudioOutput();
    const { context, commitCount } = runContext({ ...host, audioOutput: audio.service });

    const error = await rejection(provider.run(speechRequest(), context));

    expect(error.errorClass).toBe("Unavailable");
    expect(commitCount()).toBe(0);
    expect(audio.sessions).toHaveLength(0);
    expect(runtime.synthesized).toHaveLength(0);
  });

  for (const mode of ["playback", "artifact"] as const) {
    it(`ends as a cancellation when the normalization hook fails after the run was cancelled (${mode})`, async () => {
      const runtime = createFixtureNeuralSpeechRuntime();
      let reject!: (error: unknown) => void;
      let started!: () => void;
      const hookStarted = new Promise<void>((resolve) => (started = resolve));
      const hooked: NeuralSpeechRuntime = {
        availability: (pkg) => runtime.availability(pkg),
        prepare: (pkg) => runtime.prepare(pkg),
        synthesize: (input) => runtime.synthesize(input),
        normalizeText() {
          started();
          return new Promise<string>((_resolve, rej) => (reject = rej));
        }
      };
      const provider = new NeuralSpeechWebProvider({ modelPackage: PACKAGE, runtime: hooked });
      const audio = createFixtureAudioOutput();
      const { context, commitCount } = runContext({ ...host, audioOutput: audio.service });
      const controller = new AbortController();

      const events: unknown[] = [];
      let failure: unknown;
      const consumed = (async () => {
        for await (const event of provider.stream(
          speechRequest(mode === "artifact" ? { delivery: { mode: "artifact" } } : {}),
          { ...context, signal: controller.signal }
        )) {
          events.push(event);
        }
      })().catch((error: unknown) => (failure = error));
      await hookStarted;
      controller.abort();
      reject(new NeuralSpeechRuntimeError("unavailable", "speech text frontend unavailable"));
      await consumed;

      expect(failure).toBeUndefined();
      expect(events).toEqual([]);
      expect(commitCount()).toBe(0);
      expect(audio.sessions).toHaveLength(0);
      expect(runtime.synthesized).toHaveLength(0);
    });
  }
});
