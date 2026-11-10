import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import type { ModelPackage } from "@independo/inderun-contracts";
import { describe, expect, it } from "vitest";

import { encodeSafetensors } from "../../../test/safetensors-writer.js";
import {
  NeuralSpeechRuntimeError,
  type PcmChunk,
  type SpeechGraphExecutor,
  type SpeechPackageFiles,
  type SpeechTensor
} from "../runtime.js";
import {
  clampDurations,
  encodeLetters,
  equalizeLetterRate,
  flowStep,
  frameCondition,
  frameCount,
  limitPeak,
  applyBiquad,
  lowShelfCoefficients,
  padSilence,
  shapeWaveform,
  splitLongSentence,
  toInt16,
  type NoiseSource
} from "./math.js";
import { parseArticulinoConfig } from "./config.js";
import { createArticulinoRuntime } from "./runtime.js";

interface Tensor {
  shape: number[];
  data?: number[];
}
type TensorMap = Record<string, Tensor>;
interface ExecutorScript {
  text?: TensorMap;
  dit_step?: TensorMap[];
  decoder?: TensorMap;
}
interface RecordedCall {
  role: string;
  inputs: Record<string, SpeechTensor>;
}
interface ExpectedCall {
  role: string;
  inputs: TensorMap;
}
interface FixtureCase {
  id: string;
  kind: CaseKind;
  text: string;
  language: string;
  speed?: number;
  pauseMs: number;
  cancelAfterCalls: number;
  executor: ExecutorScript;
  noise: Tensor[];
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- per-kind shapes are read by the handlers
  input: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- per-kind shapes are read by the handlers
  expect: any;
}
type CaseKind =
  | "letters"
  | "durations"
  | "frameCondition"
  | "flowSteps"
  | "postprocess"
  | "split"
  | "endToEnd"
  | "cancel";

const catalog = JSON.parse(
  readFileSync(
    join(
      dirname(fileURLToPath(import.meta.url)),
      "../../../../../../contracts/fixtures/speech/articulino-pipeline.json"
    ),
    "utf8"
  )
) as {
  config: Record<string, unknown> & { sample_rate: number; charset: string };
  voice: Record<string, Tensor>;
  cases: FixtureCase[];
};

const config = parseArticulinoConfig(new TextEncoder().encode(JSON.stringify(catalog.config)));
/** The voice's prompt frames P, read from `voice_cache`'s shape like the runtime does. */
const PROMPT_FRAMES = catalog.voice["voice_cache"]?.shape[4] as number;
const FLOAT_TOLERANCE = 1e-4;

const f32 = (values: number[]): Float32Array => new Float32Array(values);

function closeTo(actual: ArrayLike<number | bigint>, expected: number[], tolerance: number): void {
  expect(actual.length).toBe(expected.length);
  for (let i = 0; i < expected.length; i += 1) {
    expect(Math.abs(Number(actual[i]) - (expected[i] as number))).toBeLessThanOrEqual(tolerance);
  }
}

function fixtureNoise(tensors: Tensor[]): NoiseSource {
  let next = 0;
  return () => f32(tensors[next++]?.data ?? []);
}

function memoryFiles(files: Record<string, Uint8Array>): SpeechPackageFiles {
  return {
    async read(file) {
      const bytes = files[file];
      if (bytes === undefined) throw new Error(`no such file: ${file}`);
      return bytes;
    }
  };
}

function voiceTensors(voice: Record<string, Tensor>): Record<string, SpeechTensor> {
  return Object.fromEntries(
    Object.entries(voice).map(([name, t]) => [name, { shape: t.shape, data: f32(t.data ?? []) }])
  );
}

function fixturePackage(voiceFile: string | null = "voices/v.safetensors"): ModelPackage {
  return {
    id: "articulino-fixture",
    version: "1",
    format: "onnx",
    tasks: ["text_to_speech"],
    source: { sourceType: "app_managed" },
    speech: {
      pipeline: "articulino",
      sampleRate: 24000,
      graphs: { text: "text.onnx", dit_step: "dit_step.onnx", decoder: "decoder.onnx" },
      frontend: { kind: "grapheme", assets: { config: "config.json" } },
      voices: [
        {
          id: "v",
          name: "V",
          locales: ["de-DE", "en-US"],
          ...(voiceFile === null ? {} : { file: voiceFile })
        }
      ]
    }
  };
}

function packageFiles(voice: Uint8Array = encodeVoice()): SpeechPackageFiles {
  return memoryFiles({
    "config.json": new TextEncoder().encode(JSON.stringify(catalog.config)),
    "voices/v.safetensors": voice
  });
}

function encodeVoice(drop?: string): Uint8Array {
  const tensors = voiceTensors(catalog.voice);
  if (drop !== undefined) delete tensors[drop];
  return encodeSafetensors(tensors, { format: "inderun.articulino.voice/1" });
}

function toTensor(t: Tensor): SpeechTensor {
  return { shape: t.shape, data: f32(t.data ?? []) };
}

function scriptedExecutor(
  script: ExecutorScript,
  calls: RecordedCall[],
  afterCall?: (count: number) => void
): SpeechGraphExecutor {
  const steps = [...(script.dit_step ?? [])];
  return {
    async load() {},
    async run(role, inputs) {
      calls.push({ role, inputs });
      afterCall?.(calls.length);
      const outputs =
        role === "dit_step" ? steps.shift() : (script as Record<string, TensorMap>)[role];
      if (outputs === undefined) throw new Error(`no scripted output for ${role}`);
      return Object.fromEntries(Object.entries(outputs).map(([k, t]) => [k, toTensor(t)]));
    }
  };
}

async function collect(iterable: AsyncIterable<PcmChunk>): Promise<PcmChunk[]> {
  const chunks: PcmChunk[] = [];
  for await (const chunk of iterable) chunks.push(chunk);
  return chunks;
}

function expectCalls(actual: RecordedCall[], expected: ExpectedCall[]): void {
  expect(actual.map((c) => c.role)).toEqual(expected.map((c) => c.role));
  expected.forEach((want, i) => {
    for (const [name, tensor] of Object.entries(want.inputs)) {
      const got = actual[i]?.inputs[name];
      expect(got, `${want.role}.${name}`).toBeDefined();
      expect(got?.shape, `${want.role}.${name} shape`).toEqual(tensor.shape);
      if (tensor.data !== undefined) {
        closeTo(got?.data ?? [], tensor.data, FLOAT_TOLERANCE);
      }
    }
  });
}

type Handler = (c: FixtureCase) => Promise<void> | void;
const handlers: Record<CaseKind, Handler> = {
  letters(c) {
    const { ids, languages } = encodeLetters(c.text, c.language, config);
    expect([0, ...ids]).toEqual(c.expect.textIds);
    expect([languages[0] ?? 0, ...languages]).toEqual(c.expect.language);
    expect([0, ...ids.map(() => 1)]).toEqual(c.expect.textMask);
  },

  durations(c) {
    const { logDurations, textMask, speed, letterRate, textIds } = c.input;
    const mask = BigInt64Array.from((textMask as number[]).map(BigInt));
    const d = clampDurations(f32(logDurations), mask, speed, config.maxDurationUnits);
    if (letterRate > 0) {
      equalizeLetterRate(d, textIds, config.charset, 1, letterRate * speed);
    }
    d[0] = config.durationUnitsPerFrame * PROMPT_FRAMES;
    closeTo(d, c.expect.durations, FLOAT_TOLERANCE);
    expect(frameCount(d, config.durationUnitsPerFrame)).toBe(c.expect.frames);
  },

  frameCondition(c) {
    const { features, durations, first, frames } = c.input;
    const cond = frameCondition(
      f32(features.data),
      features.shape[1],
      f32(durations),
      first,
      frames,
      config.durationUnitsPerFrame
    );
    closeTo(cond, c.expect.condition.data, FLOAT_TOLERANCE);
  },

  flowSteps(c) {
    const noise: Tensor[] = c.input.noise;
    const velocities: Tensor[] = c.input.velocities;
    let x = f32(noise[0]?.data ?? []);
    let x1 = x;
    config.times.forEach((t, k) => {
      const next = k + 1 < config.times.length ? config.times[k + 1] : undefined;
      const step = flowStep(
        x,
        t,
        f32(velocities[k]?.data ?? []),
        next,
        next === undefined ? undefined : f32(noise[k + 1]?.data ?? [])
      );
      x1 = step.x1;
      if (step.next !== undefined) x = step.next;
    });
    closeTo(x1, c.expect.latents.data, FLOAT_TOLERANCE);
  },

  postprocess(c) {
    const { waveform, leadInFrames, pauseMs } = c.input;
    const wav = shapeWaveform(f32(waveform), leadInFrames * config.samplesPerFrame, config);
    const out = toInt16(padSilence(wav, pauseMs, config.sampleRate));
    closeTo(out, c.expect.samples, 1);
  },

  split(c) {
    expect(splitLongSentence(c.text)).toEqual(c.expect.pieces);
  },

  async endToEnd(c) {
    const calls: RecordedCall[] = [];
    const runtime = createArticulinoRuntime({
      executor: scriptedExecutor(c.executor, calls),
      files: packageFiles(),
      noise: fixtureNoise(c.noise),
      pauseMs: c.pauseMs,
      ...(c.speed === undefined ? {} : { speed: c.speed })
    });
    const chunks = await collect(
      runtime.synthesize({
        modelPackage: fixturePackage(),
        text: c.text,
        locale: c.language,
        voiceId: "v"
      })
    );
    expect(chunks).toHaveLength(1);
    expect(chunks[0]?.isLast).toBe(true);
    expect(chunks[0]?.sampleRate).toBe(c.expect.sampleRate);
    closeTo(chunks[0]?.samples ?? [], c.expect.samples, 1);
    expectCalls(calls, c.expect.calls);
  },

  async cancel(c) {
    const calls: RecordedCall[] = [];
    const controller = new AbortController();
    const runtime = createArticulinoRuntime({
      executor: scriptedExecutor(c.executor, calls, (n) => {
        if (n >= c.cancelAfterCalls) controller.abort();
      }),
      files: packageFiles(),
      noise: fixtureNoise(c.noise),
      pauseMs: c.pauseMs
    });
    const chunks = await collect(
      runtime.synthesize({
        modelPackage: fixturePackage(),
        text: c.text,
        locale: c.language,
        voiceId: "v",
        signal: controller.signal
      })
    );
    expect(chunks).toHaveLength(0);
    expect(calls.length).toBeLessThanOrEqual(c.expect.callsAtMost);
  }
};

describe("articulino pipeline conformance", () => {
  it("implements every case kind in the shared fixture, and no others", () => {
    expect(Object.keys(handlers).sort()).toEqual(
      [...new Set(catalog.cases.map((c) => c.kind))].sort()
    );
  });

  for (const c of catalog.cases) {
    it(c.id, async () => {
      await handlers[c.kind](c);
    });
  }

  it("holds the shelf coefficients and biquad helpers consistent with the config", () => {
    const [b0, b1, b2, a1, a2] = lowShelfCoefficients(180, 2, 24000, 0.7);
    const out = applyBiquad(new Float32Array(8).fill(1), [b0, b1, b2, a1, a2]);
    expect(out).toHaveLength(8);
    const loud = new Float32Array([2, -2]);
    limitPeak(loud, 0.95);
    expect(Math.abs(loud[0] as number)).toBeCloseTo(0.95, 6);
  });
});

describe("articulino runtime lifecycle", () => {
  const calls: RecordedCall[] = [];
  const idle = scriptedExecutor({}, calls);

  it("availability_requires_voice_files", async () => {
    const runtime = createArticulinoRuntime({ executor: idle, files: packageFiles() });
    expect(await runtime.availability(fixturePackage())).toEqual({ available: true });
    expect(await runtime.availability(fixturePackage(null))).toEqual({
      available: false,
      reason: "voice file missing: v"
    });
  });

  it("refuses a different pipeline, a missing config and a missing graph", async () => {
    const runtime = createArticulinoRuntime({ executor: idle, files: packageFiles() });
    const base = fixturePackage();
    const speech = base.speech as NonNullable<ModelPackage["speech"]>;
    expect(
      (await runtime.availability({ ...base, speech: { ...speech, pipeline: "x" } })).reason
    ).toBe("unsupported pipeline 'x'");
    expect(
      (
        await runtime.availability({
          ...base,
          speech: { ...speech, frontend: { kind: "grapheme" } }
        })
      ).reason
    ).toBe("pipeline config missing: speech.frontend.assets.config");
    const { dit_step: _omitted, ...graphs } = speech.graphs;
    expect((await runtime.availability({ ...base, speech: { ...speech, graphs } })).reason).toBe(
      "graph missing: dit_step"
    );
  });

  it("rejects a bundle without voice_cache at prepare", async () => {
    const runtime = createArticulinoRuntime({
      executor: idle,
      files: packageFiles(encodeVoice("voice_cache"))
    });
    const result = await runtime.prepare(fixturePackage());
    expect(result.available).toBe(false);
    expect(result.reason).toBe("voice file malformed: v: missing tensor 'voice_cache'");
  });

  it("rejects a bundle with the wrong format at prepare", async () => {
    const bytes = encodeSafetensors(voiceTensors(catalog.voice), { format: "other/1" });
    const runtime = createArticulinoRuntime({ executor: idle, files: packageFiles(bytes) });
    expect((await runtime.prepare(fixturePackage())).reason).toBe(
      "voice file malformed: v: unexpected format 'other/1'"
    );
  });

  it("refuses an unsupported locale and an unknown voice", async () => {
    const runtime = createArticulinoRuntime({ executor: idle, files: packageFiles() });
    const run = (locale: string, voiceId: string): Promise<PcmChunk[]> =>
      collect(runtime.synthesize({ modelPackage: fixturePackage(), text: "a", locale, voiceId }));
    await expect(run("fr-FR", "v")).rejects.toMatchObject({
      kind: "capability",
      message: "locale unsupported: fr-FR"
    });
    await expect(run("de-DE", "nope")).rejects.toMatchObject({
      kind: "capability",
      message: "voice not found: nope"
    });
  });

  it("wraps an executor failure that is not a NeuralSpeechRuntimeError", async () => {
    const executor: SpeechGraphExecutor = {
      async load() {},
      async run() {
        throw new Error("boom");
      }
    };
    const runtime = createArticulinoRuntime({ executor, files: packageFiles() });
    await expect(
      collect(
        runtime.synthesize({
          modelPackage: fixturePackage(),
          text: "hallo",
          locale: "de",
          voiceId: "v"
        })
      )
    ).rejects.toMatchObject({ kind: "internal", message: "pipeline failed: boom" });

    const typed: SpeechGraphExecutor = {
      async load() {},
      async run() {
        throw new NeuralSpeechRuntimeError("unavailable", "gone");
      }
    };
    const second = createArticulinoRuntime({ executor: typed, files: packageFiles() });
    await expect(
      collect(
        second.synthesize({
          modelPackage: fixturePackage(),
          text: "hallo",
          locale: "de",
          voiceId: "v"
        })
      )
    ).rejects.toMatchObject({ kind: "unavailable", message: "gone" });
  });
});

function filesWith(
  configPatch: Record<string, unknown> = {},
  voice: Uint8Array = encodeVoice()
): SpeechPackageFiles {
  return memoryFiles({
    "config.json": new TextEncoder().encode(JSON.stringify({ ...catalog.config, ...configPatch })),
    "voices/v.safetensors": voice
  });
}

function voiceWithLetterRate(rate: number): Uint8Array {
  const tensors = voiceTensors(catalog.voice);
  tensors["letter_rate"] = { shape: [1], data: Float32Array.of(rate) };
  return encodeSafetensors(tensors, { format: "inderun.articulino.voice/1" });
}

type Outputs = Record<string, SpeechTensor>;
interface ShapeOverrides {
  text?: (outputs: Outputs) => Outputs;
  dit_step?: (outputs: Outputs) => Outputs;
}

/**
 * Answers every graph call with outputs shaped by its inputs: `text` gives two feature channels
 * and a duration of 6 units per letter, `dit_step` a velocity pulling `x` towards 0.5, `decoder`
 * a sine of `samples_per_frame` samples per latent frame.
 */
function shapeFollowingExecutor(
  calls: RecordedCall[],
  overrides: ShapeOverrides = {},
  samplesPerFrame = config.samplesPerFrame
): SpeechGraphExecutor & { loads: number } {
  const executor = {
    loads: 0,
    async load() {
      executor.loads += 1;
    },
    async run(role: string, inputs: Record<string, SpeechTensor>): Promise<Outputs> {
      calls.push({ role, inputs });
      if (role === "text") {
        const n = inputs["text_ids"]?.shape[1] as number;
        const outputs: Outputs = {
          text_features: {
            shape: [1, n, 2],
            data: Float32Array.from({ length: n * 2 }, (_, i) => ((i % 7) - 3) / 10)
          },
          log_durations: { shape: [1, n], data: new Float32Array(n).fill(Math.log(6)) }
        };
        return overrides.text?.(outputs) ?? outputs;
      }
      if (role === "dit_step") {
        const x = inputs["x"] as SpeechTensor;
        const outputs: Outputs = {
          velocity: {
            shape: x.shape,
            data: Float32Array.from(x.data as Float32Array, (v) => 0.5 - v)
          }
        };
        return overrides.dit_step?.(outputs) ?? outputs;
      }
      const frames = inputs["latents"]?.shape[1] as number;
      const count = frames * samplesPerFrame;
      if (count > 1e7) throw new Error(`scripted decoder asked for ${count} samples`);
      return {
        waveform: {
          shape: [1, count],
          data: Float32Array.from({ length: count }, (_, i) => Math.sin(i / 3) * 0.3)
        }
      };
    }
  };
  return executor;
}

const constantNoise: NoiseSource = (count) => new Float32Array(count).fill(0.1);

function sentence(
  text: string,
  locale = "de-DE"
): Parameters<ReturnType<typeof createArticulinoRuntime>["synthesize"]>[0] {
  return { modelPackage: fixturePackage(), text, locale, voiceId: "v" };
}

describe("articulino runtime validation", () => {
  it("reads P from the voice, not from the config's prefix_frames", () => {
    expect(PROMPT_FRAMES).toBe(2);
    expect(config.prefixFrames).not.toBe(PROMPT_FRAMES);
  });

  it("refuses a config value out of range at prepare", async () => {
    const post = catalog.config["postprocess"] as Record<string, number>;
    const cases: [Record<string, unknown>, string][] = [
      [{ sample_rate: 1e20 }, "sample_rate must be an integer from 8000 to 192000"],
      [{ latent_dim: 0 }, "latent_dim must be an integer from 1 to 4096"],
      [{ samples_per_frame: 2.5 }, "samples_per_frame must be an integer from 1 to 65536"],
      [
        { duration_units_per_frame: 0 },
        "duration_units_per_frame must be an integer from 1 to 1000"
      ],
      [{ prefix_frames: -1 }, "prefix_frames must be an integer from 0 to 100000"],
      [
        { decoder_lead_in_frames: -1 },
        "decoder_lead_in_frames must be an integer from 0 to 100000"
      ],
      [{ max_duration_units: 0 }, "max_duration_units must be greater than 0 and at most 100000"],
      [{ times: [0, 1] }, "times[1] must be in [0, 1)"],
      [{ languages: { de: 0.5 } }, "languages.de must be an integer from 0 to 65535"],
      [{ postprocess: { ...post, peak: 1.5 } }, "postprocess.peak must be in (0, 1]"],
      [
        { postprocess: { ...post, shelf_slope: 0 } },
        "postprocess.shelf_slope must be greater than 0"
      ]
    ];
    for (const [patch, why] of cases) {
      const runtime = createArticulinoRuntime({
        executor: shapeFollowingExecutor([]),
        files: filesWith(patch)
      });
      expect((await runtime.prepare(fixturePackage())).reason, why).toBe(
        `pipeline config malformed: ${why}`
      );
    }
  });

  it("accepts a letter_rate of 0 and refuses one outside 1-100 at prepare", async () => {
    const prepare = async (rate: number) =>
      createArticulinoRuntime({
        executor: shapeFollowingExecutor([]),
        files: filesWith({}, voiceWithLetterRate(rate))
      }).prepare(fixturePackage());
    expect(await prepare(0)).toEqual({ available: true });
    expect(await prepare(100)).toEqual({ available: true });
    for (const rate of [1e-6, 0.5, 101, -1, Number.NaN]) {
      expect(await prepare(rate), String(rate)).toEqual({
        available: false,
        reason: "voice file malformed: v: letter_rate out of range"
      });
    }
  });

  it("bounds the frame count before allocating", async () => {
    const runtime = createArticulinoRuntime({
      executor: shapeFollowingExecutor(
        [],
        {
          text: (o) => ({
            ...o,
            log_durations: {
              shape: o["log_durations"]?.shape as number[],
              data: new Float32Array(o["log_durations"]?.data.length ?? 0).fill(Math.log(1e5))
            }
          })
        },
        65536
      ),
      files: filesWith({
        samples_per_frame: 65536,
        duration_units_per_frame: 1,
        max_duration_units: 100000
      }),
      noise: constantNoise
    });
    await expect(collect(runtime.synthesize(sentence("a.")))).rejects.toMatchObject({
      kind: "internal",
      message: expect.stringMatching(
        /^pipeline failed: text\.log_durations yields \d+ frames, more than \d+$/u
      )
    });
  });

  it("refuses non-finite log_durations, short text_features and a short velocity", async () => {
    const cases: [ShapeOverrides, string][] = [
      [
        {
          text: (o) => ({
            ...o,
            log_durations: { shape: [1, 3], data: Float32Array.of(0, Number.NaN, 1) }
          })
        },
        "pipeline failed: text.log_durations yields non-finite durations"
      ],
      [
        { text: (o) => ({ ...o, text_features: { shape: [1, 3, 2], data: new Float32Array(4) } }) },
        "pipeline failed: text.text_features has 4 elements, expected 6"
      ],
      [
        { dit_step: () => ({ velocity: { shape: [1, 1, 2], data: new Float32Array(1) } }) },
        "pipeline failed: dit_step.velocity has 1 elements, expected "
      ]
    ];
    for (const [overrides, message] of cases) {
      const runtime = createArticulinoRuntime({
        executor: shapeFollowingExecutor([], overrides),
        files: filesWith(),
        noise: constantNoise
      });
      const failure = collect(runtime.synthesize(sentence("ab")));
      await expect(failure, message).rejects.toMatchObject({ kind: "internal" });
      await expect(failure).rejects.toThrow(message);
    }
  });
});

describe("articulino runtime long sentence", () => {
  const split = catalog.cases.find((c) => c.id === "long_sentence_split") as FixtureCase;
  const pieces = split.expect.pieces as string[];
  const pauseMs = 1;
  const pause = Math.round((pauseMs / 1000) * config.sampleRate);

  async function speak(text: string, calls: RecordedCall[]): Promise<PcmChunk[]> {
    const runtime = createArticulinoRuntime({
      executor: shapeFollowingExecutor(calls),
      files: filesWith(),
      noise: constantNoise,
      pauseMs
    });
    return collect(runtime.synthesize(sentence(text)));
  }

  it("synthesizes each piece through the graphs and returns one chunk with one pause", async () => {
    expect(pieces).toHaveLength(2);
    const calls: RecordedCall[] = [];
    const chunks = await speak(split.text, calls);
    const roles = calls.map((c) => c.role);
    expect(roles.filter((r) => r === "text")).toHaveLength(2);
    expect(roles.filter((r) => r === "dit_step")).toHaveLength(2 * config.times.length);
    expect(roles.filter((r) => r === "decoder")).toHaveLength(2);
    expect(chunks).toHaveLength(1);
    expect(chunks[0]?.isLast).toBe(true);

    const alone = await Promise.all(
      pieces.map(async (piece) => (await speak(piece, []))[0]?.samples)
    );
    const bodies = alone.map((s) => Array.from(s ?? []).slice(0, (s?.length ?? 0) - pause));
    expect(bodies.every((b) => b.length > 0)).toBe(true);
    expect(Array.from(chunks[0]?.samples ?? [])).toEqual([
      ...(bodies[0] ?? []),
      ...(bodies[1] ?? []),
      ...new Array<number>(pause).fill(0)
    ]);
  });
});

describe("articulino runtime prepare", () => {
  it("returns the remembered outcome for the same package without loading again", async () => {
    const executor = shapeFollowingExecutor([]);
    const runtime = createArticulinoRuntime({ executor, files: filesWith() });
    expect(await runtime.prepare(fixturePackage())).toEqual({ available: true });
    expect(await runtime.prepare(fixturePackage())).toEqual({ available: true });
    expect(executor.loads).toBe(1);
    expect(await runtime.prepare({ ...fixturePackage(), version: "2" })).toEqual({
      available: true
    });
    expect(executor.loads).toBe(2);
  });

  it("loads again after a failed prepare", async () => {
    let attempts = 0;
    const executor: SpeechGraphExecutor = {
      async load() {
        attempts += 1;
        if (attempts === 1) throw new NeuralSpeechRuntimeError("unavailable", "not yet");
      },
      run: shapeFollowingExecutor([]).run
    };
    const runtime = createArticulinoRuntime({ executor, files: filesWith() });
    expect(await runtime.prepare(fixturePackage())).toEqual({
      available: false,
      reason: "not yet"
    });
    expect(await runtime.prepare(fixturePackage())).toEqual({ available: true });
    expect(await runtime.prepare(fixturePackage())).toEqual({ available: true });
    expect(attempts).toBe(2);
  });
});
