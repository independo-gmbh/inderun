import {
  IndeRunException,
  type GenerateSpeechOptions,
  type IndeRunApi,
  type SpeakOptions,
  type generateSpeech as sdkGenerateSpeech,
  type prepare as sdkPrepare,
  type speak as sdkSpeak
} from "@independo/inderun-web";

// The Voices lab's run of the shared speech benchmark corpus (#276). Each scenario handler mirrors the
// `setup` text of its scenario in contracts/fixtures/speech/utterance-corpus.json, and the report it
// builds is the one `speech-benchmark-report.schema.json` describes. A report carries utterance ids and
// measurements, never utterance text, and a browser family plus platform, never the user agent.

export const REPORT_SCHEMA = "inderun-speech-benchmark/1";

interface CorpusUtterance {
  id: string;
  locale: string;
  text: string;
  expect?: string;
}

export interface BenchmarkScenario {
  id: string;
  delivery: string;
  utteranceIds: string[];
  trials: number;
  cancelAfterMs?: number;
}

export interface BenchmarkCorpus {
  utterances: CorpusUtterance[];
  extendedUtterances?: CorpusUtterance[];
  benchmark: { scenarios: BenchmarkScenario[] };
}

/** The SDK calls a run makes, replaceable in tests. */
export interface VoicesLabBenchmarkApi {
  speak: typeof sdkSpeak;
  generateSpeech: typeof sdkGenerateSpeech;
  prepare: typeof sdkPrepare;
}

export interface ReportTarget {
  name: string;
  providerId: string;
  model?: string;
  variant?: string;
  checksums?: Record<string, string>;
  voiceId?: string;
}

/** An engine a cold-start trial owns: closed by the run when the trial ends. */
export interface BenchmarkEngine {
  engine: IndeRunApi;
  close(): Promise<void>;
}

export interface BenchmarkSample {
  scenario: string;
  step: string;
  utteranceId: string;
  requestedLocale: string;
  resolvedLocale?: string;
  metrics: Record<string, number>;
}

export interface RenderedAudio {
  utteranceId: string;
  voiceId: string;
  locale: string;
  mimeType: string;
  base64: string;
}

export interface BenchmarkRun {
  target: ReportTarget;
  samples: BenchmarkSample[];
  skipped: { scenario: string; reason: string }[];
  /** The last warm `render_speed` artifact of each utterance. */
  renders: RenderedAudio[];
}

export interface RunCorpusInput {
  api: VoicesLabBenchmarkApi;
  /** The engine the warm scenarios share. */
  engine: IndeRunApi;
  /** Model profile to route within; absent for the OS control. */
  profile?: string;
  voice?: SpeakOptions["voice"];
  corpus: BenchmarkCorpus;
  target: ReportTarget;
  now: () => number;
  /**
   * Builds a new engine holding the benchmarked target alone, so `prepare` readies nothing else;
   * one per cold trial and per warm scenario. Absent, the two cold scenarios are skipped.
   */
  newEngine?: () => BenchmarkEngine;
  sleep?: (ms: number) => Promise<void>;
  /** Called after each scenario with the number done and the total. */
  onProgress?: (done: number, total: number) => void;
}

/** Thrown inside a handler to move the scenario to `skipped`. */
class ScenarioSkipped extends Error {}

type Context = RunCorpusInput & {
  scenario: BenchmarkScenario;
  samples: BenchmarkSample[];
  renders: RenderedAudio[];
  sleep: (ms: number) => Promise<void>;
};

function utteranceAt(ctx: Context, index: number): CorpusUtterance {
  const id = ctx.scenario.utteranceIds[index]!;
  const found = [...ctx.corpus.utterances, ...(ctx.corpus.extendedUtterances ?? [])].find(
    (u) => u.id === id
  );
  if (found === undefined) throw new Error(`no utterance ${id}`);
  return found;
}

function optionsFor(ctx: Context, utterance: CorpusUtterance): SpeakOptions {
  return {
    text: utterance.text,
    locale: utterance.locale,
    ...(ctx.profile !== undefined ? { model: ctx.profile } : {}),
    ...(ctx.voice !== undefined ? { voice: ctx.voice } : {})
  };
}

function record(
  ctx: Context,
  step: string,
  utterance: CorpusUtterance,
  metrics: Record<string, number | undefined>,
  resolvedLocale?: string
): void {
  const values: Record<string, number> = {};
  for (const [name, value] of Object.entries(metrics))
    if (value !== undefined) values[name] = value;
  ctx.samples.push({
    scenario: ctx.scenario.id,
    step,
    utteranceId: utterance.id,
    requestedLocale: utterance.locale,
    ...(resolvedLocale !== undefined ? { resolvedLocale } : {}),
    metrics: values
  });
}

/** A neural request answered by another provider would measure the wrong thing. */
function requireTarget(ctx: Context, servedBy: string | undefined): void {
  if (servedBy !== undefined && servedBy !== ctx.target.providerId) {
    throw new ScenarioSkipped(`served by ${servedBy}, not ${ctx.target.providerId}`);
  }
}

async function speakOnce(
  ctx: Context,
  engine: IndeRunApi,
  utterance: CorpusUtterance,
  step: string
): Promise<void> {
  const started = ctx.now();
  const playback = await ctx.api.speak(engine, optionsFor(ctx, utterance));
  const done = await playback.result;
  const wallMs = ctx.now() - started;
  requireTarget(ctx, done.provenance?.providerId);
  record(
    ctx,
    step,
    utterance,
    {
      firstChunkMs: done.timing?.firstChunkMs,
      firstAudioMs: done.timing?.firstAudioMs,
      wallMs,
      durationMs: done.timing?.durationMs
    },
    done.speech?.locale
  );
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

async function readAll(engine: IndeRunApi, artifactId: string): Promise<Uint8Array> {
  const parts: Uint8Array[] = [];
  let offset = 0;
  for (;;) {
    const chunk = await engine.readArtifact({ artifactId, offset });
    parts.push(chunk.bytes);
    offset += chunk.bytes.length;
    if (chunk.done || chunk.bytes.length === 0) break;
  }
  const all = new Uint8Array(offset);
  let at = 0;
  for (const part of parts) {
    all.set(part, at);
    at += part.length;
  }
  return all;
}

/** Renders once, records the render, keeps the bytes of a warm render, and disposes the artifact. */
async function renderOnce(
  ctx: Context,
  engine: IndeRunApi,
  utterance: CorpusUtterance,
  step: string
): Promise<void> {
  const started = ctx.now();
  const options: GenerateSpeechOptions = optionsFor(ctx, utterance);
  const speech = await ctx.api.generateSpeech(engine, options);
  const renderMs = ctx.now() - started;
  try {
    requireTarget(ctx, speech.provenance?.providerId);
    const { artifact } = speech;
    const audioMs = artifact.durationMs;
    record(
      ctx,
      step,
      utterance,
      {
        renderMs,
        audioMs,
        realTimeFactor: audioMs !== undefined && audioMs > 0 ? renderMs / audioMs : undefined,
        bytes: artifact.byteLength
      },
      speech.speech?.locale
    );
    if (step === "warm") {
      const bytes = await readAll(engine, artifact.id);
      const entry: RenderedAudio = {
        utteranceId: utterance.id,
        voiceId: ctx.target.voiceId ?? "automatic",
        locale: speech.speech?.locale ?? utterance.locale,
        mimeType: artifact.mediaType,
        base64: bytesToBase64(bytes)
      };
      const at = ctx.renders.findIndex((r) => r.utteranceId === utterance.id);
      if (at >= 0) ctx.renders[at] = entry;
      else ctx.renders.push(entry);
    }
  } finally {
    await engine.disposeArtifact(speech.artifact);
  }
}

/** Runs `body` on a new engine and closes it afterwards, whatever happens. */
async function withNewEngine(
  ctx: Context,
  body: (engine: IndeRunApi) => Promise<void>
): Promise<void> {
  if (ctx.newEngine === undefined) throw new ScenarioSkipped("no fresh engine available");
  const fresh = ctx.newEngine();
  try {
    await body(fresh.engine);
  } finally {
    await fresh.close();
  }
}

/**
 * Runs a warm scenario on its own fresh engine, as the Swift and Kotlin harnesses do, so one
 * scenario never inherits another's warmth. Without a fresh-engine source (the OS control) it uses
 * the shared engine, and that report says so by carrying the OS provider as its target.
 */
async function withScenarioEngine(
  ctx: Context,
  body: (engine: IndeRunApi) => Promise<void>
): Promise<void> {
  if (ctx.newEngine === undefined) return body(ctx.engine);
  return withNewEngine(ctx, body);
}

const firstOrNew = (trial: number) => (trial === 0 ? "first in process" : "new instance");

const handlers: Record<string, (ctx: Context) => Promise<void>> = {
  async first_call_cold(ctx) {
    for (let trial = 0; trial < ctx.scenario.trials; trial += 1) {
      await withNewEngine(ctx, (engine) =>
        speakOnce(ctx, engine, utteranceAt(ctx, 0), firstOrNew(trial))
      );
    }
  },
  async first_call_after_prepare(ctx) {
    for (let trial = 0; trial < ctx.scenario.trials; trial += 1) {
      await withNewEngine(ctx, async (engine) => {
        const utterance = utteranceAt(ctx, 0);
        const started = ctx.now();
        const preparation = await ctx.api.prepare(engine, {
          tasks: ["text_to_speech"],
          locale: utterance.locale
        });
        await preparation.result;
        record(
          ctx,
          trial === 0 ? "prepare, first in process" : "prepare, new instance",
          utterance,
          { prepareMs: ctx.now() - started }
        );
        await speakOnce(ctx, engine, utterance, firstOrNew(trial));
      });
    }
  },
  async repeat_same_voice(ctx) {
    await withScenarioEngine(ctx, async (engine) => {
      for (let call = 1; call <= ctx.scenario.trials; call += 1) {
        await speakOnce(ctx, engine, utteranceAt(ctx, 0), `call ${call}`);
      }
    });
  },
  async switch_language(ctx) {
    await withScenarioEngine(ctx, async (engine) => {
      for (let index = 0; index < ctx.scenario.utteranceIds.length; index += 1) {
        const utterance = utteranceAt(ctx, index);
        await speakOnce(ctx, engine, utterance, `call ${index + 1} (${utterance.locale})`);
      }
    });
  },
  async speak_after_stop(ctx) {
    await withScenarioEngine(ctx, async (engine) => {
      await speakOnce(ctx, engine, utteranceAt(ctx, 1), "warm-up");
      for (let trial = 0; trial < ctx.scenario.trials; trial += 1) {
        const long = utteranceAt(ctx, 0);
        const playback = await ctx.api.speak(engine, optionsFor(ctx, long));
        await ctx.sleep(ctx.scenario.cancelAfterMs ?? 1500);
        const stopIssued = ctx.now();
        playback.cancel("benchmark stop");
        const stopped = await playback.result;
        const stopLatencyMs = ctx.now() - stopIssued;
        requireTarget(ctx, stopped.provenance?.providerId);
        // Playback that ended before the stop has no stop latency to report.
        if (stopped.finishReason === "cancelled") {
          record(ctx, "stop", long, { stopLatencyMs }, stopped.speech?.locale);
        }
        await speakOnce(ctx, engine, utteranceAt(ctx, 1), "next after stop");
      }
    });
  },
  async text_length(ctx) {
    await withScenarioEngine(ctx, async (engine) => {
      await speakOnce(ctx, engine, utteranceAt(ctx, 0), "warm-up");
      for (let index = 0; index < ctx.scenario.utteranceIds.length; index += 1) {
        await speakOnce(ctx, engine, utteranceAt(ctx, index), index === 0 ? "short" : "long");
      }
    });
  },
  async render_speed(ctx) {
    await withScenarioEngine(ctx, async (engine) => {
      for (let index = 0; index < ctx.scenario.utteranceIds.length; index += 1) {
        const utterance = utteranceAt(ctx, index);
        for (let trial = 0; trial <= ctx.scenario.trials; trial += 1) {
          await renderOnce(ctx, engine, utterance, trial === 0 ? "cold" : "warm");
        }
      }
      // A neural target renders its extended sentences once each, on the warmed engine.
      if (ctx.target.model !== undefined) {
        for (const utterance of ctx.corpus.extendedUtterances ?? []) {
          await renderOnce(ctx, engine, utterance, "extended");
        }
      }
    });
  }
};

function skipReason(error: unknown): string | undefined {
  if (error instanceof ScenarioSkipped) return error.message;
  if (error instanceof IndeRunException && error.errorClass === "CapabilityMismatch") {
    // The error class and code only: an error message can echo request text.
    const code = error.details?.["code"];
    return typeof code === "string" ? `CapabilityMismatch: ${code}` : "CapabilityMismatch";
  }
  return undefined;
}

/**
 * Runs every scenario in the corpus against one target. A scenario the target cannot serve goes to
 * `skipped` with a reason and keeps none of its samples; any other failure rejects the run.
 */
export async function runCorpus(input: RunCorpusInput): Promise<BenchmarkRun> {
  const scenarios = input.corpus.benchmark.scenarios;
  const samples: BenchmarkSample[] = [];
  const renders: RenderedAudio[] = [];
  const skipped: BenchmarkRun["skipped"] = [];
  const sleep = input.sleep ?? ((ms) => new Promise<void>((done) => setTimeout(done, ms)));
  let done = 0;
  for (const scenario of scenarios) {
    const handler = handlers[scenario.id];
    if (handler === undefined) {
      skipped.push({ scenario: scenario.id, reason: "no handler for this scenario" });
    } else {
      const ctx: Context = { ...input, scenario, samples: [], renders: [], sleep };
      try {
        await handler(ctx);
        samples.push(...ctx.samples);
        renders.push(...ctx.renders);
      } catch (error) {
        const reason = skipReason(error);
        if (reason === undefined) throw error;
        skipped.push({ scenario: scenario.id, reason });
      }
    }
    done += 1;
    input.onProgress?.(done, scenarios.length);
  }
  return { target: input.target, samples, skipped, renders };
}

// --- Report ------------------------------------------------------------------------------

export interface Percentile {
  scenario: string;
  step: string;
  utteranceId: string;
  metrics: Record<string, number>;
}

export type ReportSample = Omit<BenchmarkSample, "metrics"> & Record<string, string | number>;

export interface SpeechBenchmarkReport {
  schema: typeof REPORT_SCHEMA;
  harness: "web_voices_lab";
  createdAt: string;
  device: string;
  os: string;
  sdkVersion: string;
  target: ReportTarget;
  requestedLocale: string[];
  resolvedLocale: string[];
  locality: "on_device";
  samples: ReportSample[];
  skipped: { scenario: string; reason: string }[];
  p50: Percentile[];
  p95: Percentile[];
  audio?: RenderedAudio[];
}

/** Nearest rank: index `ceil(q * n) - 1` of the ascending values. `sorted` must not be empty. */
export function percentile(sorted: number[], q: number): number {
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.ceil(q * sorted.length) - 1))]!;
}

const distinct = (values: (string | undefined)[]): string[] => [
  ...new Set(values.filter((v): v is string => v !== undefined))
];

/** Per `(scenario, step, utterance)`, so a cold call is never pooled with warm ones. */
function percentiles(samples: BenchmarkSample[], q: number): Percentile[] {
  const groups = new Map<string, BenchmarkSample[]>();
  for (const sample of samples) {
    const key = JSON.stringify([sample.scenario, sample.step, sample.utteranceId]);
    const group = groups.get(key);
    if (group === undefined) groups.set(key, [sample]);
    else group.push(sample);
  }
  return [...groups.values()].map((group) => {
    const metrics: Record<string, number> = {};
    for (const name of new Set(group.flatMap((s) => Object.keys(s.metrics)))) {
      const values = group
        .map((s) => s.metrics[name])
        .filter((v): v is number => v !== undefined)
        .sort((a, b) => a - b);
      if (values.length > 0) metrics[name] = percentile(values, q);
    }
    const { scenario, step, utteranceId } = group[0]!;
    return { scenario, step, utteranceId, metrics };
  });
}

/** A vite dev server build is not the published SDK, and the report says so. */
export function reportSdkVersion(version: string, dev: boolean): string {
  return dev ? `${version}+dev` : version;
}

export function buildReport(
  run: BenchmarkRun,
  meta: { device: string; os: string; sdkVersion: string; createdAt: string }
): SpeechBenchmarkReport {
  return {
    schema: REPORT_SCHEMA,
    harness: "web_voices_lab",
    createdAt: meta.createdAt,
    device: meta.device,
    os: meta.os,
    sdkVersion: meta.sdkVersion,
    target: run.target,
    requestedLocale: distinct(run.samples.map((s) => s.requestedLocale)),
    resolvedLocale: distinct(run.samples.map((s) => s.resolvedLocale)),
    locality: "on_device",
    samples: run.samples.map(({ metrics, ...rest }) => ({ ...rest, ...metrics })),
    skipped: run.skipped,
    p50: percentiles(run.samples, 0.5),
    p95: percentiles(run.samples, 0.95)
  };
}

/** The report with the warm renders attached for listening; the caller decides whether to ask. */
export function withAudio(
  report: SpeechBenchmarkReport,
  renders: RenderedAudio[]
): SpeechBenchmarkReport {
  return { ...report, audio: renders };
}

// --- Browser ----------------------------------------------------------------------------

const UA_FAMILIES: [marker: string, family: string][] = [
  // Order matters: Edge and Chrome UAs also say Chrome and Safari.
  ["Edg/", "Edge"],
  ["Firefox/", "Firefox"],
  ["Chrome/", "Chrome"],
  ["Safari/", "Safari"]
];
const UA_PLATFORMS: [marker: string, platform: string][] = [
  ["Windows", "Windows"],
  ["Android", "Android"],
  ["iPhone", "iOS"],
  ["Mac", "macOS"],
  ["Linux", "Linux"]
];

interface NavigatorWithBrands extends Navigator {
  userAgentData?: { brands?: { brand: string }[]; platform?: string };
}

/**
 * A browser family and a platform, never the user agent. Prefers `userAgentData`; otherwise looks
 * for known markers in the user agent with `indexOf`.
 */
export function describeBrowser(nav: Navigator): { device: string; os: string } {
  const data = (nav as NavigatorWithBrands).userAgentData;
  const ua = nav.userAgent ?? "";
  let family: string | undefined;
  const brands = data?.brands?.map((b) => b.brand) ?? [];
  if (brands.length > 0) {
    family =
      brands.find((b) => !b.startsWith("Not") && b !== "Chromium") ??
      brands.find((b) => b === "Chromium");
    for (const vendor of ["Google ", "Microsoft "]) {
      if (family?.startsWith(vendor)) family = family.slice(vendor.length);
    }
  }
  family ??= UA_FAMILIES.find(([marker]) => ua.indexOf(marker) >= 0)?.[1];
  const platform =
    data?.platform ||
    nav.platform ||
    UA_PLATFORMS.find(([marker]) => ua.indexOf(marker) >= 0)?.[1] ||
    "unknown";
  return { device: `${family ?? "unknown browser"} ${platform}`, os: platform };
}
