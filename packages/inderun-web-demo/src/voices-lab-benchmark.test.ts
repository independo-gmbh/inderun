import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { IndeRunException, type IndeRunApi } from "@independo/inderun-web";
import Ajv2020 from "ajv/dist/2020.js";
import { describe, expect, it, vi } from "vitest";
import {
  buildReport,
  describeBrowser,
  percentile,
  reportSdkVersion,
  runCorpus,
  withAudio,
  type BenchmarkCorpus,
  type BenchmarkRun,
  type ReportTarget,
  type VoicesLabBenchmarkApi
} from "./voices-lab-benchmark";
import { loadFixture } from "./fixtures.test-support";

const corpus = loadFixture<BenchmarkCorpus>("utterance-corpus.json");
const schema = JSON.parse(
  readFileSync(
    resolve(process.cwd(), "../../contracts/fixtures/speech/speech-benchmark-report.schema.json"),
    "utf8"
  )
) as object;
const Ajv = ((Ajv2020 as unknown as { default?: unknown }).default ?? Ajv2020) as typeof Ajv2020;
const validate = new Ajv({ allErrors: true, strict: true }).compile(schema);

const NEURAL = "local.onnx.speech.web:articulino-de-en-int8";
const neuralTarget: ReportTarget = {
  name: "articulino-de-en-int8",
  providerId: NEURAL,
  model: "articulino-de-en-int8",
  variant: "int8",
  checksums: { "text.onnx": `sha256:${"a".repeat(64)}` },
  voiceId: "de-at-m-1"
};
const META = {
  device: "Chrome macOS",
  os: "macOS",
  sdkVersion: "0.4.0",
  createdAt: "2026-11-09T10:00:00.000Z"
};

/** A clock that advances 10 ms per read. */
function steppingClock() {
  let t = 0;
  return () => (t += 10);
}

function fakes(over: { providerId?: string; speakError?: unknown; generateError?: unknown } = {}) {
  const providerId = over.providerId ?? NEURAL;
  const speak = vi.fn(async (_engine: IndeRunApi, options: { locale: string }) => {
    let cancelled = false;
    return {
      runId: "r",
      cancel: vi.fn(() => {
        cancelled = true;
      }),
      // Settles on a later macrotask, so a cancel issued right after speak() lands first.
      result: (async () => {
        await new Promise((done) => setTimeout(done, 0));
        if (over.speakError !== undefined) throw over.speakError;
        return {
          runId: "r",
          finishReason: cancelled ? "cancelled" : "stop",
          timing: { firstChunkMs: 5, firstAudioMs: 7, durationMs: 50 },
          speech: { locale: options.locale },
          provenance: { providerId }
        };
      })()
    };
  });
  const generateSpeech = vi.fn(async (_engine: IndeRunApi, options: { locale: string }) => {
    if (over.generateError !== undefined) throw over.generateError;
    return {
      artifact: { id: "art", mediaType: "audio/wav", byteLength: 4000, durationMs: 2000 },
      speech: { locale: options.locale },
      provenance: { providerId },
      finishReason: "stop"
    };
  });
  const prepare = vi.fn(async () => ({
    runId: "p",
    cancel: vi.fn(),
    result: Promise.resolve({ items: [] })
  }));
  const api = { speak, generateSpeech, prepare } as unknown as VoicesLabBenchmarkApi;
  const engine = {
    readArtifact: vi.fn(async () => ({
      artifactId: "art",
      offset: 0,
      bytes: new Uint8Array([1, 2, 3]),
      totalBytes: 3,
      done: true
    })),
    disposeArtifact: vi.fn(async () => undefined)
  } as unknown as IndeRunApi;
  const closeFresh = vi.fn(async () => undefined);
  const newEngine = vi.fn(() => ({ engine, close: closeFresh }));
  return { api, engine, speak, generateSpeech, prepare, newEngine, closeFresh };
}

function run(f: ReturnType<typeof fakes>, over: Partial<Parameters<typeof runCorpus>[0]> = {}) {
  return runCorpus({
    api: f.api,
    engine: f.engine,
    profile: "voices-lab:articulino-de-en-int8",
    corpus,
    target: neuralTarget,
    now: steppingClock(),
    sleep: async () => undefined,
    newEngine: f.newEngine,
    ...over
  });
}

const countOf = (r: BenchmarkRun, scenario: string) =>
  r.samples.filter((s) => s.scenario === scenario).length;

describe("runCorpus", () => {
  it("handles each of the seven scenarios", async () => {
    const f = fakes();
    const result = await run(f);
    const ids = corpus.benchmark.scenarios.map((s) => s.id);
    expect(ids).toHaveLength(7);
    expect(result.skipped).toEqual([]);
    expect(countOf(result, "first_call_cold")).toBe(3);
    expect(countOf(result, "first_call_after_prepare")).toBe(6);
    expect(countOf(result, "repeat_same_voice")).toBe(5);
    expect(countOf(result, "switch_language")).toBe(3);
    expect(countOf(result, "speak_after_stop")).toBe(1 + 3 * 2);
    expect(countOf(result, "text_length")).toBe(3);
    // 2 utterances x (cold + 3 warm), then each extended sentence once for a neural target.
    expect(countOf(result, "render_speed")).toBe(8 + (corpus.extendedUtterances?.length ?? 0));
    expect(new Set(result.samples.map((s) => s.scenario))).toEqual(new Set(ids));
    // A new engine per trial for the two cold scenarios, one per other scenario, each closed.
    expect(f.newEngine).toHaveBeenCalledTimes(6 + 5);
    expect(f.closeFresh).toHaveBeenCalledTimes(6 + 5);
  });

  it("gives every warm scenario its own fresh engine, never the shared one", async () => {
    for (const id of [
      "repeat_same_voice",
      "switch_language",
      "speak_after_stop",
      "text_length",
      "render_speed"
    ]) {
      const f = fakes();
      const only: BenchmarkCorpus = {
        ...corpus,
        benchmark: { scenarios: corpus.benchmark.scenarios.filter((s) => s.id === id) }
      };
      const result = await run(f, { corpus: only });
      expect(result.skipped, id).toEqual([]);
      expect(f.newEngine, id).toHaveBeenCalledTimes(1);
      expect(f.closeFresh, id).toHaveBeenCalledTimes(1);
    }
  });

  it("closes a scenario's fresh engine when the scenario fails", async () => {
    const f = fakes({ speakError: new Error("boom") });
    await expect(run(f)).rejects.toThrow("boom");
    expect(f.closeFresh).toHaveBeenCalledTimes(f.newEngine.mock.calls.length);
  });

  it("keeps the shared engine for every scenario when no fresh engine is available", async () => {
    const f = fakes();
    const result = await run(f, { newEngine: undefined });
    expect(countOf(result, "repeat_same_voice")).toBe(5);
    expect(f.newEngine).not.toHaveBeenCalled();
  });

  it("records the metrics each scenario defines", async () => {
    const result = await run(fakes());
    const first = result.samples.find((s) => s.scenario === "first_call_cold")!;
    expect(first.step).toBe("first in process");
    expect(first.metrics).toEqual({ firstChunkMs: 5, firstAudioMs: 7, durationMs: 50, wallMs: 10 });
    expect(first.resolvedLocale).toBe("de-DE");
    const stop = result.samples.find((s) => s.step === "stop")!;
    expect(stop.metrics).toEqual({ stopLatencyMs: 10 });
    const prep = result.samples.find((s) => s.step === "prepare, first in process")!;
    expect(prep.metrics).toEqual({ prepareMs: 10 });
    const warm = result.samples.find((s) => s.scenario === "render_speed" && s.step === "warm")!;
    expect(warm.metrics).toEqual({
      renderMs: 10,
      audioMs: 2000,
      realTimeFactor: 0.005,
      bytes: 4000
    });
    expect(result.samples.some((s) => "peakRssDeltaBytes" in s.metrics)).toBe(false);
  });

  it("keeps the last warm render of each utterance as audio and disposes every artifact", async () => {
    const f = fakes();
    const result = await run(f);
    expect(result.renders.map((r) => r.utteranceId)).toEqual(["de_de_short", "de_de_long"]);
    expect(result.renders[0]).toMatchObject({
      voiceId: "de-at-m-1",
      mimeType: "audio/wav",
      base64: "AQID"
    });
    expect(f.engine.disposeArtifact).toHaveBeenCalledTimes(
      8 + (corpus.extendedUtterances?.length ?? 0)
    );
  });

  it("skips a scenario the target cannot serve and drops its samples", async () => {
    const f = fakes({
      generateError: new IndeRunException({
        errorClass: "CapabilityMismatch",
        message: "no artifact delivery"
      })
    });
    const result = await run(f);
    expect(result.skipped).toEqual([{ scenario: "render_speed", reason: "CapabilityMismatch" }]);
    expect(countOf(result, "render_speed")).toBe(0);
    expect(countOf(result, "first_call_cold")).toBe(3);
  });

  it("skips a scenario another provider answered, and rethrows other failures", async () => {
    const other = await run(fakes({ providerId: "web_system_speech" }));
    expect(other.skipped).toHaveLength(7);
    expect(other.samples).toEqual([]);
    await expect(run(fakes({ speakError: new Error("boom") }))).rejects.toThrow("boom");
  });

  it("skips the two cold scenarios when no fresh engine is available", async () => {
    const result = await run(fakes(), { newEngine: undefined });
    expect(result.skipped.map((s) => s.scenario)).toEqual([
      "first_call_cold",
      "first_call_after_prepare"
    ]);
  });

  it("reports progress per scenario", async () => {
    const onProgress = vi.fn();
    await run(fakes(), { onProgress });
    expect(onProgress.mock.calls.at(-1)).toEqual([7, 7]);
  });
});

describe("buildReport", () => {
  it("report validates against the schema", async () => {
    const report = buildReport(await run(fakes()), META);
    expect(validate(report), JSON.stringify(validate.errors)).toBe(true);
    expect(report.harness).toBe("web_voices_lab");
    expect(report.requestedLocale.slice(0, 2)).toEqual(["de-DE", "en-US"]);
    expect(report.resolvedLocale).toEqual(report.requestedLocale);
  });

  it("takes nearest-rank percentiles per scenario, step and utterance", () => {
    expect(percentile([1, 2, 3, 4], 0.5)).toBe(2);
    expect(percentile([1, 2, 3, 4], 0.95)).toBe(4);
    const mk = (v: number) => ({
      scenario: "repeat_same_voice",
      step: "call",
      utteranceId: "de_de_short",
      requestedLocale: "de-DE",
      metrics: { wallMs: v }
    });
    const report = buildReport(
      { target: neuralTarget, samples: [mk(40), mk(10), mk(30), mk(20)], skipped: [], renders: [] },
      META
    );
    expect(report.p50[0]!.metrics["wallMs"]).toBe(20);
    expect(report.p95[0]!.metrics["wallMs"]).toBe(40);
  });

  it("a single sample gives p50 == p95", () => {
    const report = buildReport(
      {
        target: neuralTarget,
        samples: [
          {
            scenario: "s",
            step: "x",
            utteranceId: "u",
            requestedLocale: "de-DE",
            metrics: { wallMs: 7 }
          }
        ],
        skipped: [],
        renders: []
      },
      META
    );
    expect(report.p50[0]!.metrics["wallMs"]).toBe(7);
    expect(report.p95[0]!.metrics["wallMs"]).toBe(7);
  });

  it("an empty run gives empty percentiles and locale lists", () => {
    const report = buildReport(
      {
        target: neuralTarget,
        samples: [],
        skipped: [{ scenario: "render_speed", reason: "n/a" }],
        renders: []
      },
      META
    );
    expect(report.p50).toEqual([]);
    expect(report.p95).toEqual([]);
    expect(report.requestedLocale).toEqual([]);
    expect(report.skipped).toEqual([{ scenario: "render_speed", reason: "n/a" }]);
    expect(validate(report), JSON.stringify(validate.errors)).toBe(true);
  });

  it("a skipped scenario serializes in skipped and has no percentiles", async () => {
    const f = fakes({
      generateError: new IndeRunException({ errorClass: "CapabilityMismatch", message: "x" })
    });
    const report = buildReport(await run(f), META);
    expect(report.skipped.map((s) => s.scenario)).toEqual(["render_speed"]);
    expect(report.p50.some((p) => p.scenario === "render_speed")).toBe(false);
    expect(report.p95.some((p) => p.scenario === "render_speed")).toBe(false);
    expect(validate(report), JSON.stringify(validate.errors)).toBe(true);
  });

  it("never contains utterance text", async () => {
    const f = fakes();
    const json = JSON.stringify(withAudio(buildReport(await run(f), META), (await run(f)).renders));
    for (const u of [...corpus.utterances, ...(corpus.extendedUtterances ?? [])]) {
      expect(json.includes(u.text), u.id).toBe(false);
    }
  });
});

describe("withAudio", () => {
  it("export without audio has no audio key", async () => {
    const report = buildReport(await run(fakes()), META);
    expect("audio" in report).toBe(false);
  });

  it("export with audio carries base64 and mimeType", async () => {
    const result = await run(fakes());
    const report = withAudio(buildReport(result, META), result.renders);
    expect(report.audio).toHaveLength(2);
    expect(report.audio![0]).toMatchObject({
      mimeType: "audio/wav",
      base64: "AQID",
      locale: "de-DE"
    });
    expect(validate(report), JSON.stringify(validate.errors)).toBe(true);
  });
});

describe("reportSdkVersion", () => {
  it("marks a vite dev server build with +dev", () => {
    expect(reportSdkVersion("0.4.0", true)).toBe("0.4.0+dev");
    expect(reportSdkVersion("0.4.0", false)).toBe("0.4.0");
  });
});

describe("describeBrowser", () => {
  it("uses userAgentData when present", () => {
    const nav = {
      userAgentData: {
        brands: [{ brand: "Not A;Brand" }, { brand: "Chromium" }, { brand: "Google Chrome" }],
        platform: "macOS"
      },
      userAgent: "Mozilla/5.0 (Macintosh; secret) Chrome/130",
      platform: "MacIntel"
    } as unknown as Navigator;
    expect(describeBrowser(nav)).toEqual({ device: "Chrome macOS", os: "macOS" });
  });

  it("strips the vendor prefix only at the start of a brand", () => {
    const nav = {
      userAgentData: { brands: [{ brand: "Microsoft Edge" }], platform: "Windows" }
    } as unknown as Navigator;
    expect(describeBrowser(nav).device).toBe("Edge Windows");
    const odd = {
      userAgentData: { brands: [{ brand: "Foo Google Bar" }], platform: "Linux" }
    } as unknown as Navigator;
    expect(describeBrowser(odd).device).toBe("Foo Google Bar Linux");
  });

  it("scans the user agent when userAgentData is absent, and never returns it", () => {
    const ua =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0 Safari/537.36 Edg/130.0";
    const result = describeBrowser({ userAgent: ua, platform: "Win32" } as unknown as Navigator);
    expect(result).toEqual({ device: "Edge Win32", os: "Win32" });
    expect(JSON.stringify(result)).not.toContain("Mozilla");
    expect(describeBrowser({ userAgent: "weird", platform: "" } as unknown as Navigator)).toEqual({
      device: "unknown browser unknown",
      os: "unknown"
    });
  });
});
