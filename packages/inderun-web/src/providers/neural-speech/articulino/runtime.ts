import type { ModelPackage } from "@independo/inderun-contracts";
import { normalizeSpeechText } from "@independo/inderun-route-core-wasm";

import {
  NeuralSpeechRuntimeError,
  type NeuralSpeechAvailability,
  type NeuralSpeechRuntime,
  type NeuralSpeechSynthesisInput,
  type PcmChunk,
  type SpeechGraphExecutor,
  type SpeechPackageFiles,
  type SpeechTensor
} from "../runtime.js";
import { parseSafetensors } from "../safetensors.js";
import { parseArticulinoConfig, type ArticulinoConfig } from "./config.js";
import {
  clampDurations,
  encodeLetters,
  equalizeLetterRate,
  flowStep,
  frameCondition,
  frameCount,
  gaussianNoise,
  normalizeLetters,
  padSilence,
  shapeWaveform,
  splitLongSentence,
  toInt16,
  type NoiseSource
} from "./math.js";

export interface ArticulinoRuntimeOptions {
  executor: SpeechGraphExecutor;
  files: SpeechPackageFiles;
  /** Default `gaussianNoise`. */
  noise?: NoiseSource;
  /** Default 1.0, clamped to 0.7..1.6. */
  speed?: number;
  /** Silence appended after the sentence. Default 150. */
  pauseMs?: number;
  /** Sentences with more letters are split before synthesis. Default 180. */
  maxLetters?: number;
}

const PIPELINE = "articulino";
const ROLES = ["text", "dit_step", "decoder"] as const;
const VOICE_FORMAT = "inderun.articulino.voice/1";
const VOICE_RANKS: Record<string, number> = {
  voice_tokens: 3,
  voice_vector: 2,
  voice_cache: 6,
  prompt_latents: 3,
  letter_rate: 1
};

interface Voice {
  voiceTokens: SpeechTensor;
  voiceVector: SpeechTensor;
  voiceCache: SpeechTensor;
  promptLatents: SpeechTensor;
  letterRate: number;
  /** Prompt frames P, read from `voice_cache`'s shape. */
  promptFrames: number;
}

interface Prepared {
  config: ArticulinoConfig;
  voices: Map<string, Voice>;
}

/** What the last `prepare` of a package left behind: the loaded state, or why it failed. */
interface PrepareState {
  key: string;
  prepared?: Prepared;
  reason?: string;
}

function packageKey(pkg: ModelPackage): string {
  return `${pkg.id}@${pkg.version ?? ""}`;
}

/** The slowest `speed` and smallest non-zero voice `letter_rate` the runtime accepts. */
const MIN_SPEED = 0.7;
const MIN_LETTER_RATE = 1;
const MAX_LETTER_RATE = 100;
/** Largest element count of one tensor a pipeline allocates (the Kotlin array limit, on every SDK). */
const MAX_TENSOR_ELEMENTS = 2147483647;

/**
 * The most frames a piece of `letters` letters can span once config and voice are range-checked:
 * every duration is at most `max(max_duration_units, 100 / letter_rate) / speed`, plus the prompt
 * placeholder; and no tensor of the piece may outgrow `MAX_TENSOR_ELEMENTS`.
 */
function maxFrames(
  letters: number,
  promptFrames: number,
  lead: number,
  stride: number,
  config: ArticulinoConfig
): number {
  const perLetter = Math.max(config.maxDurationUnits, 100 / MIN_LETTER_RATE) / MIN_SPEED;
  const byDurations =
    promptFrames + Math.ceil((letters * perLetter) / config.durationUnitsPerFrame) + 1;
  const widest = Math.max(config.samplesPerFrame, config.latentDim, stride, 1);
  const byBuffers = promptFrames - lead + Math.floor(MAX_TENSOR_ELEMENTS / widest);
  return Math.min(byDurations, byBuffers);
}

class VoiceError extends Error {}

function parseVoice(bytes: Uint8Array, latentDim: number): Voice {
  const { tensors, metadata } = parseSafetensors(bytes);
  if (metadata.format !== VOICE_FORMAT) {
    throw new VoiceError(`unexpected format '${metadata.format ?? ""}'`);
  }
  for (const [name, rank] of Object.entries(VOICE_RANKS)) {
    const tensor = tensors[name];
    if (tensor === undefined) throw new VoiceError(`missing tensor '${name}'`);
    if (!(tensor.data instanceof Float32Array)) throw new VoiceError(`tensor '${name}' is not f32`);
    if (tensor.shape.length !== rank) {
      throw new VoiceError(`tensor '${name}' has rank ${tensor.shape.length}, expected ${rank}`);
    }
  }
  const get = (name: string): SpeechTensor => tensors[name] as SpeechTensor;
  const promptLatents = get("prompt_latents");
  const voiceCache = get("voice_cache");
  if (promptLatents.shape[2] !== latentDim) {
    throw new VoiceError(`tensor 'prompt_latents' does not have ${latentDim} latent channels`);
  }
  if (get("letter_rate").data.length !== 1)
    throw new VoiceError("tensor 'letter_rate' is not a scalar");
  const letterRate = Number(get("letter_rate").data[0]);
  if (letterRate !== 0 && !(letterRate >= MIN_LETTER_RATE && letterRate <= MAX_LETTER_RATE)) {
    throw new VoiceError("letter_rate out of range");
  }
  return {
    voiceTokens: get("voice_tokens"),
    voiceVector: get("voice_vector"),
    voiceCache,
    promptLatents,
    letterRate,
    promptFrames: voiceCache.shape[4] as number
  };
}

/** The f32 elements of the output `what` of `role`, which must number `count`. */
function requireFloats(
  tensor: SpeechTensor | undefined,
  role: string,
  what: string,
  count: number
): Float32Array {
  if (tensor === undefined || !(tensor.data instanceof Float32Array)) {
    throw new NeuralSpeechRuntimeError(
      "internal",
      `pipeline failed: ${role}.${what} is not an f32 tensor`
    );
  }
  if (tensor.data.length !== count) {
    throw new NeuralSpeechRuntimeError(
      "internal",
      `pipeline failed: ${role}.${what} has ${tensor.data.length} elements, expected ${count}`
    );
  }
  return tensor.data;
}

/**
 * The Articulino text-to-PCM pipeline over a `SpeechGraphExecutor`: letters, the `text` graph,
 * durations, the four `dit_step` flow steps, the `decoder` and the post-processing, one
 * `PcmChunk` per sentence. The math lives in `math.ts`; this file holds the state (config,
 * voices) and the per-sentence orchestration.
 */
export function createArticulinoRuntime(options: ArticulinoRuntimeOptions): NeuralSpeechRuntime {
  const { executor, files } = options;
  const noise = options.noise ?? gaussianNoise;
  const speed = Math.min(1.6, Math.max(0.7, options.speed ?? 1));
  const pauseMs = options.pauseMs ?? 150;
  const maxLetters = options.maxLetters ?? 180;

  let state: PrepareState | undefined;
  /** Serializes prepares, so concurrent sentences load the graphs and voices once. */
  let queue: Promise<unknown> = Promise.resolve();

  function availability(pkg: ModelPackage): NeuralSpeechAvailability {
    const speech = pkg.speech;
    if (speech?.pipeline !== PIPELINE) {
      return { available: false, reason: `unsupported pipeline '${speech?.pipeline ?? ""}'` };
    }
    if (speech.frontend?.assets?.config === undefined) {
      return { available: false, reason: "pipeline config missing: speech.frontend.assets.config" };
    }
    for (const role of ROLES) {
      if (speech.graphs[role] === undefined)
        return { available: false, reason: `graph missing: ${role}` };
    }
    for (const voice of speech.voices) {
      if (voice.file === undefined)
        return { available: false, reason: `voice file missing: ${voice.id}` };
    }
    return { available: true };
  }

  async function doPrepare(pkg: ModelPackage): Promise<NeuralSpeechAvailability> {
    const key = packageKey(pkg);
    const check = availability(pkg);
    if (!check.available) return fail(key, check.reason ?? "unavailable");
    const speech = pkg.speech as NonNullable<ModelPackage["speech"]>;
    try {
      const config = parseArticulinoConfig(
        await files.read(speech.frontend?.assets?.config as string)
      );
      await executor.load(
        Object.fromEntries(ROLES.map((role) => [role, speech.graphs[role] as string]))
      );
      const voices = new Map<string, Voice>();
      for (const voice of speech.voices) {
        const bytes = await files.read(voice.file as string);
        try {
          voices.set(voice.id, parseVoice(bytes, config.latentDim));
        } catch (error) {
          if (error instanceof VoiceError) {
            return fail(key, `voice file malformed: ${voice.id}: ${error.message}`);
          }
          if (error instanceof NeuralSpeechRuntimeError) {
            const why = error.message.replace(/^voice file malformed: /u, "");
            return fail(
              key,
              error.message.startsWith("voice file malformed: ")
                ? `voice file malformed: ${voice.id}: ${why}`
                : `${error.message} (voice '${voice.id}')`
            );
          }
          throw error;
        }
      }
      state = { key, prepared: { config, voices } };
      return { available: true };
    } catch (error) {
      return fail(key, error instanceof Error ? error.message : String(error));
    }
  }

  function fail(key: string, reason: string): NeuralSpeechAvailability {
    state = { key, reason };
    return { available: false, reason };
  }

  /** Idempotent on success: a package already prepared is not loaded again; a failed one is. */
  function prepare(pkg: ModelPackage): Promise<NeuralSpeechAvailability> {
    const key = packageKey(pkg);
    const run = queue.then(() =>
      state?.key === key && state.prepared !== undefined ? { available: true } : doPrepare(pkg)
    );
    queue = run;
    return run;
  }

  async function ensurePrepared(pkg: ModelPackage): Promise<Prepared> {
    const key = packageKey(pkg);
    const run = queue.then(async () => {
      if (state?.key !== key) await doPrepare(pkg);
    });
    queue = run;
    await run;
    if (state?.prepared !== undefined && state.key === key) return state.prepared;
    throw new NeuralSpeechRuntimeError("unavailable", state?.reason ?? "pipeline not prepared");
  }

  async function* synthesize(input: NeuralSpeechSynthesisInput): AsyncGenerator<PcmChunk> {
    const { config, voices } = await ensurePrepared(input.modelPackage);
    const language = (input.locale.split(/[-_]/u)[0] ?? "").toLowerCase();
    if (config.languages[language] === undefined) {
      throw new NeuralSpeechRuntimeError("capability", `locale unsupported: ${input.locale}`);
    }
    const voice = voices.get(input.voiceId);
    if (voice === undefined) {
      throw new NeuralSpeechRuntimeError("capability", `voice not found: ${input.voiceId}`);
    }

    const aborted = (): boolean => input.signal?.aborted === true;
    const normalized = normalizeLetters(input.text, config.charset);
    const parts: Float32Array[] = [];
    try {
      for (const piece of normalized.length === 0
        ? []
        : splitLongSentence(normalized, maxLetters)) {
        if (aborted()) return;
        const audio = await synthesizePiece(piece, language, config, voice, aborted);
        if (audio === undefined) return;
        parts.push(audio);
      }
    } catch (error) {
      if (error instanceof NeuralSpeechRuntimeError) throw error;
      throw new NeuralSpeechRuntimeError(
        "internal",
        `pipeline failed: ${error instanceof Error ? error.message : String(error)}`,
        error
      );
    }
    if (aborted()) return;

    const body = new Float32Array(parts.reduce((n, p) => n + p.length, 0));
    let at = 0;
    for (const part of parts) {
      body.set(part, at);
      at += part.length;
    }
    yield {
      samples: toInt16(padSilence(body, pauseMs, config.sampleRate)),
      sampleRate: config.sampleRate,
      isLast: true
    };
  }

  /** One piece through the graphs; `undefined` when aborted between graph calls. */
  async function synthesizePiece(
    text: string,
    language: string,
    config: ArticulinoConfig,
    voice: Voice,
    aborted: () => boolean
  ): Promise<Float32Array | undefined> {
    const { ids, languages } = encodeLetters(text, language, config);
    if (ids.length === 0) return new Float32Array(0);
    const n = ids.length + 1;
    const textIds = [0, ...ids];
    const mask = BigInt64Array.from(textIds, (_, i) => (i === 0 ? 0n : 1n));

    if (aborted()) return undefined;
    const encoded = await executor.run("text", {
      text_ids: { shape: [1, n], data: BigInt64Array.from(textIds, BigInt) },
      language: {
        shape: [1, n],
        data: BigInt64Array.from([languages[0] ?? 0, ...languages], BigInt)
      },
      text_mask: { shape: [1, n], data: mask },
      voice_vector: voice.voiceVector
    });
    const stride = encoded.text_features?.shape.at(-1) ?? 0;
    const h = requireFloats(encoded.text_features, "text", "text_features", n * stride);
    const logDurations = requireFloats(encoded.log_durations, "text", "log_durations", n);

    const units = config.durationUnitsPerFrame;
    const d = clampDurations(logDurations, mask, speed, config.maxDurationUnits);
    if (voice.letterRate > 0) {
      equalizeLetterRate(d, textIds, config.charset, 1, voice.letterRate * speed);
    }
    d[0] = units * voice.promptFrames;
    if (!d.every(Number.isFinite)) {
      throw new NeuralSpeechRuntimeError(
        "internal",
        "pipeline failed: text.log_durations yields non-finite durations"
      );
    }
    const lead = Math.min(voice.promptLatents.shape[1] as number, config.decoderLeadInFrames);
    const frames = frameCount(d, units);
    const limit = maxFrames(ids.length, voice.promptFrames, lead, stride, config);
    if (!(frames <= limit)) {
      throw new NeuralSpeechRuntimeError(
        "internal",
        `pipeline failed: text.log_durations yields ${frames} frames, more than ${limit}`
      );
    }
    const newFrames = frames - voice.promptFrames;
    if (newFrames <= 0) return new Float32Array(0);
    const cond = frameCondition(h, stride, d, voice.promptFrames, frames, units);
    const frameCond: SpeechTensor = { shape: [1, newFrames, stride], data: cond };

    const latentShape = [1, newFrames, config.latentDim];
    const latentCount = newFrames * config.latentDim;
    let x = noise(latentCount);
    let x1 = x;
    for (let k = 0; k < config.times.length; k += 1) {
      if (aborted()) return undefined;
      const t = config.times[k] as number;
      const out = await executor.run("dit_step", {
        x: { shape: latentShape, data: x },
        t: { shape: [1], data: Float32Array.of(t) },
        frame_cond: frameCond,
        voice_tokens: voice.voiceTokens,
        voice_vector: voice.voiceVector,
        voice_cache: voice.voiceCache
      });
      const hasNext = k + 1 < config.times.length;
      const step = flowStep(
        x,
        t,
        requireFloats(out.velocity, "dit_step", "velocity", latentCount),
        hasNext ? (config.times[k + 1] as number) : undefined,
        hasNext ? noise(latentCount) : undefined
      );
      x1 = step.x1;
      if (step.next !== undefined) x = step.next;
    }

    const prompt = voice.promptLatents.data as Float32Array;
    const z = new Float32Array((lead + newFrames) * config.latentDim);
    z.set(prompt.subarray(prompt.length - lead * config.latentDim));
    z.set(x1, lead * config.latentDim);

    if (aborted()) return undefined;
    const decoded = await executor.run("decoder", {
      latents: { shape: [1, lead + newFrames, config.latentDim], data: z }
    });
    const samples = requireFloats(
      decoded.waveform,
      "decoder",
      "waveform",
      (lead + newFrames) * config.samplesPerFrame
    );
    return shapeWaveform(samples, lead * config.samplesPerFrame, config);
  }

  return {
    availability: async (pkg) => availability(pkg),
    prepare,
    synthesize,
    async normalizeText(pkg, text, locale) {
      if (pkg.speech?.frontend?.kind !== "grapheme" || !hasSpeechTextFrontend(locale)) return text;
      try {
        return await normalizeSpeechText(text, locale);
      } catch (error) {
        // The speech text module failed to load or start: nothing has been output yet, so the
        // run is unavailable (and may fall back), not an internal error.
        throw new NeuralSpeechRuntimeError(
          "unavailable",
          `speech text frontend unavailable: ${error instanceof Error ? error.message : String(error)}`,
          error
        );
      }
    }
  };
}

/** True when the language subtag of `locale` is `de` or `en` (case-insensitive, `-` or `_` separated). */
function hasSpeechTextFrontend(locale: string): boolean {
  const language = (locale.split(/[-_]/)[0] ?? "").toLowerCase();
  return language === "de" || language === "en";
}
