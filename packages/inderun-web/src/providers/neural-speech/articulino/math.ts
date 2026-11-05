// Adapted from eigenhand/articulino-onnx, Apache License 2.0
// (https://huggingface.co/eigenhand/Articulino-DE-EN-Realtime-Stream-TTS-ONNX).
//
// The Articulino host math between the ONNX graphs. Pure functions over typed arrays: no I/O, no
// model package. The behaviour is pinned by contracts/fixtures/speech/articulino-pipeline.json,
// generated from tools/neural-speech/articulino_math.py; float32 rounding follows that reference.

import type { ArticulinoConfig } from "./config.js";

/** Returns `count` standard-normal float32 values. */
export type NoiseSource = (count: number) => Float32Array;

/** Box-Muller over `Math.random`; the default when a caller injects no noise. */
export const gaussianNoise: NoiseSource = (count) => {
  const out = new Float32Array(count);
  for (let i = 0; i < count; i += 2) {
    const u = 1 - Math.random();
    const v = Math.random();
    const radius = Math.sqrt(-2 * Math.log(u));
    out[i] = radius * Math.cos(2 * Math.PI * v);
    if (i + 1 < count) out[i + 1] = radius * Math.sin(2 * Math.PI * v);
  }
  return out;
};

const REPLACE: Record<string, string> = {
  "’": "'",
  "‘": "'",
  "`": "'",
  "´": "'",
  "“": '"',
  "”": '"',
  "„": '"',
  "«": '"',
  "»": '"',
  "–": "-",
  "—": "-",
  "…": ".",
  ø: "ö",
  æ: "ä",
  ð: "d",
  þ: "th"
};
const KEPT = "äöüß";
const SPLIT_CHARS = [",", ";", ":", "-", " "];
const f = Math.fround;

/**
 * Lowercases, applies the replacement map, NFKD-decomposes code points outside the charset
 * (dropping combining marks), drops what is still outside it, and collapses whitespace.
 */
export function normalizeLetters(text: string, charset: string): string {
  let out = "";
  for (const original of text.toLowerCase()) {
    let c = REPLACE[original] ?? original;
    if (!charset.includes(c) && !KEPT.includes(c)) {
      c = c.normalize("NFKD").replace(/\p{Mn}/gu, "");
    }
    for (const x of c) {
      if (charset.includes(x)) out += x;
      else if (/\s/u.test(x)) out += " ";
    }
  }
  return out.replace(/\s+/gu, " ").trim();
}

/** Letter ids (1 + charset index; 0 is the prompt placeholder) and the language id per letter. */
export function encodeLetters(
  text: string,
  language: string,
  config: Pick<ArticulinoConfig, "charset" | "languages">
): { ids: number[]; languages: number[] } {
  const ids: number[] = [];
  for (const c of normalizeLetters(text, config.charset)) ids.push(1 + config.charset.indexOf(c));
  const languageId = config.languages[language] ?? 0;
  return { ids, languages: ids.map(() => languageId) };
}

/** Letters and digits count for the speaking rate; the placeholder, spaces and punctuation do not. */
export function isLetter(id: number, charset: string): boolean {
  return id > 0 && /^[\p{L}\p{N}]$/u.test(charset[id - 1] ?? "");
}

/**
 * Durations in 10 ms units: `min(exp(logDurations) * mask, maxUnits) / speed`, float32.
 * `mask` is the model's int64 text mask (0/1).
 */
export function clampDurations(
  logDurations: Float32Array,
  mask: BigInt64Array,
  speed: number,
  maxUnits: number
): Float32Array {
  const d = new Float32Array(logDurations.length);
  const limit = f(maxUnits);
  const divisor = f(speed);
  for (let i = 0; i < d.length; i += 1) {
    const scaled = f(f(Math.exp(logDurations[i] as number)) * Number(mask[i]));
    d[i] = f(Math.min(scaled, limit) / divisor);
  }
  return d;
}

function median(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = sorted.length >> 1;
  return sorted.length % 2 === 1
    ? (sorted[mid] as number)
    : f(((sorted[mid - 1] as number) + (sorted[mid] as number)) / 2);
}

/**
 * Rescales, in place, the durations of the letters at index `start` onward (`ids` are the model's
 * text ids, placeholder included) so they speak at exactly `target` letters per second. Single
 * overlong letters count at most three times the median; nothing changes without letters.
 */
export function equalizeLetterRate(
  d: Float32Array,
  ids: number[],
  charset: string,
  start: number,
  target: number
): void {
  const letters: number[] = [];
  for (let i = start; i < ids.length; i += 1) {
    if (isLetter(ids[i] as number, charset)) letters.push(i);
  }
  if (letters.length === 0 || !(target > 0)) return;
  const floored = letters.map((i) => Math.max(d[i] as number, 0.5));
  const cap = f(3 * median(floored));
  const x = floored.map((v) => Math.min(v, cap));
  const sum = x.reduce((a, b) => a + b, 0);
  const rate = letters.length / (f(sum) / 100);
  const scale = f(rate / target);
  letters.forEach((index, k) => {
    d[index] = f((x[k] as number) * scale);
  });
}

/** Number of audio frames the durations span: `ceil(sum(d) / units)`, summed in float32. */
export function frameCount(d: Float32Array, units: number): number {
  let sum = 0;
  for (const v of d) sum = f(sum + v);
  return Math.ceil(sum / units);
}

/**
 * Per new frame `j = first .. frames-1`, the overlap-weighted sum of the letter features `h`
 * (flat, `hStride` values per letter) over the frame's `units`-wide window.
 */
export function frameCondition(
  h: Float32Array,
  hStride: number,
  d: Float32Array,
  first: number,
  frames: number,
  units: number
): Float32Array {
  const end = new Float32Array(d.length);
  let running = 0;
  for (let l = 0; l < d.length; l += 1) {
    running = f(running + (d[l] as number));
    end[l] = running;
  }
  const out = new Float32Array(Math.max(0, frames - first) * hStride);
  for (let j = first; j < frames; j += 1) {
    const lo = f(j * units);
    const hi = f(lo + units);
    const row = (j - first) * hStride;
    for (let l = 0; l < d.length; l += 1) {
      const stop = end[l] as number;
      const begin = f(stop - (d[l] as number));
      const w = f(Math.max(Math.min(stop, hi) - Math.max(begin, lo), 0) / units);
      if (w === 0) continue;
      for (let c = 0; c < hStride; c += 1) {
        out[row + c] = f((out[row + c] as number) + f(w * (h[l * hStride + c] as number)));
      }
    }
  }
  return out;
}

/**
 * One flow step: `x1 = x + (1 - t) * velocity`. With `nextT` and `nextNoise` it also returns the
 * next input `(1 - nextT) * nextNoise + nextT * x1`.
 */
export function flowStep(
  x: Float32Array,
  t: number,
  velocity: Float32Array,
  nextT?: number,
  nextNoise?: Float32Array
): { x1: Float32Array; next?: Float32Array } {
  const x1 = new Float32Array(x.length);
  const scale = f(1 - t);
  for (let i = 0; i < x.length; i += 1) {
    x1[i] = f((x[i] as number) + f(scale * (velocity[i] as number)));
  }
  if (nextT === undefined || nextNoise === undefined) return { x1 };
  const keep = f(1 - nextT);
  const blend = f(nextT);
  const next = new Float32Array(x.length);
  for (let i = 0; i < x.length; i += 1) {
    next[i] = f(f(keep * (nextNoise[i] as number)) + f(blend * (x1[i] as number)));
  }
  return { x1, next };
}

/** RBJ cookbook low shelf (z = -1), normalized by a0: `[b0, b1, b2, a1, a2]`. */
export function lowShelfCoefficients(
  f0: number,
  db: number,
  sampleRate: number,
  slope: number
): [number, number, number, number, number] {
  const A = 10 ** (db / 40);
  const w = (2 * Math.PI * f0) / sampleRate;
  const c = Math.cos(w);
  const q = 2 * Math.sqrt(A) * (Math.sin(w) / 2) * Math.sqrt((A + 1 / A) * (1 / slope - 1) + 2);
  const z = -1;
  const b0 = A * (A + 1 + z * (A - 1) * c + q);
  const b1 = -2 * z * A * (A - 1 + z * (A + 1) * c);
  const b2 = A * (A + 1 + z * (A - 1) * c - q);
  const a0 = A + 1 - z * (A - 1) * c + q;
  const a1 = 2 * z * (A - 1 - z * (A + 1) * c);
  const a2 = A + 1 - z * (A - 1) * c - q;
  return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0];
}

/** Direct form II transposed in float64 over the whole signal. */
export function applyBiquad(
  samples: Float32Array,
  coeffs: readonly [number, number, number, number, number]
): Float32Array {
  const [b0, b1, b2, a1, a2] = coeffs;
  const out = new Float32Array(samples.length);
  let z1 = 0;
  let z2 = 0;
  for (let i = 0; i < samples.length; i += 1) {
    const v = samples[i] as number;
    const o = b0 * v + z1;
    z1 = b1 * v - a1 * o + z2;
    z2 = b2 * v - a2 * o;
    out[i] = o;
  }
  return out;
}

/** Scales `samples` in place so that no value exceeds `peak` in magnitude. */
export function limitPeak(samples: Float32Array, peak: number): void {
  let max = 0;
  for (const v of samples) max = Math.max(max, Math.abs(v));
  if (max <= peak) return;
  const scale = f(peak / max);
  for (let i = 0; i < samples.length; i += 1) samples[i] = f((samples[i] as number) * scale);
}

/**
 * Decoder waveform to speech: low shelf over the whole waveform (lead-in included), cut the
 * lead-in, limit to the configured peak.
 */
export function shapeWaveform(
  waveform: Float32Array,
  leadSamples: number,
  config: Pick<ArticulinoConfig, "sampleRate" | "postprocess">
): Float32Array {
  const p = config.postprocess;
  const shelf = lowShelfCoefficients(p.lowShelfHz, p.lowShelfDb, config.sampleRate, p.shelfSlope);
  const out = applyBiquad(waveform, shelf).slice(leadSamples);
  limitPeak(out, p.peak);
  return out;
}

/** `samples` followed by `pauseMs` of silence. */
export function padSilence(
  samples: Float32Array,
  pauseMs: number,
  sampleRate: number
): Float32Array {
  const out = new Float32Array(
    samples.length + Math.max(0, Math.round((pauseMs / 1000) * sampleRate))
  );
  out.set(samples);
  return out;
}

/** `round(clamp(x, -1, 1) * 32767)`. */
export function toInt16(samples: Float32Array): Int16Array {
  const out = new Int16Array(samples.length);
  for (let i = 0; i < samples.length; i += 1) {
    out[i] = Math.round(Math.min(1, Math.max(-1, samples[i] as number)) * 32767);
  }
  return out;
}

/**
 * Pieces of at most `maxLetters` code points where possible: cut at the last `, ; : -` (after the
 * separator) or space between index `minSplit` and `maxLetters`. A run without any of them stays
 * whole. Expects normalized text.
 */
export function splitLongSentence(text: string, maxLetters = 180, minSplit = 60): string[] {
  const pieces: string[] = [];
  let rest = Array.from(text);
  while (rest.length > maxLetters) {
    let at = -1;
    for (let i = Math.min(maxLetters, rest.length) - 1; i >= minSplit; i -= 1) {
      if (SPLIT_CHARS.includes(rest[i] as string)) {
        at = i;
        break;
      }
    }
    if (at < 0) break;
    const cut = rest[at] === " " ? at : at + 1;
    pieces.push(rest.slice(0, cut).join("").trim());
    rest = Array.from(rest.slice(cut).join("").trim());
  }
  pieces.push(rest.join(""));
  return pieces;
}
