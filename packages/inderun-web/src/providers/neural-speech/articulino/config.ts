import { NeuralSpeechRuntimeError } from "../runtime.js";

/** The constants of the upstream Articulino `config.json` the pipeline needs. */
export interface ArticulinoConfig {
  sampleRate: number;
  latentDim: number;
  samplesPerFrame: number;
  durationUnitsPerFrame: number;
  prefixFrames: number;
  decoderLeadInFrames: number;
  maxDurationUnits: number;
  times: number[];
  charset: string;
  languages: Record<string, number>;
  postprocess: { lowShelfDb: number; lowShelfHz: number; shelfSlope: number; peak: number };
}

function malformed(why: string): NeuralSpeechRuntimeError {
  return new NeuralSpeechRuntimeError("capability", `pipeline config malformed: ${why}`);
}

function missing(key: string): NeuralSpeechRuntimeError {
  return malformed(`missing '${key}'`);
}

/**
 * Upper bound of `max_duration_units`. With the voice's `letter_rate` held to 1-100 and `speed`
 * to at least 0.7, it bounds every duration and so the frame count of a sentence.
 */
const MAX_DURATION_UNITS_CAP = 100000;

/** `value` as an exact integer within `lo..hi`, or a malformed-config error naming `key`. */
function integerIn(value: number, key: string, lo: number, hi: number): number {
  if (!Number.isInteger(value) || value < lo || value > hi) {
    throw malformed(`${key} must be an integer from ${lo} to ${hi}`);
  }
  return value;
}

function field<T>(
  source: Record<string, unknown>,
  key: string,
  valid: (value: unknown) => value is T,
  path = key
): T {
  const value = source[key];
  if (!valid(value)) throw missing(path);
  return value;
}

const isNumber = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
const isString = (v: unknown): v is string => typeof v === "string" && v.length > 0;
const isObject = (v: unknown): v is Record<string, unknown> =>
  typeof v === "object" && v !== null && !Array.isArray(v);
const isNumberArray = (v: unknown): v is number[] =>
  Array.isArray(v) && v.length > 0 && v.every(isNumber);

/**
 * Parses the package's `config.json` (snake_case keys, as upstream ships it) and range-checks every
 * value the pipeline computes with, so a malformed config refuses at `prepare` instead of
 * allocating absurd buffers later.
 */
export function parseArticulinoConfig(bytes: Uint8Array): ArticulinoConfig {
  let root: unknown;
  try {
    root = JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw new NeuralSpeechRuntimeError("capability", "pipeline config malformed: not valid JSON");
  }
  if (!isObject(root)) {
    throw new NeuralSpeechRuntimeError("capability", "pipeline config malformed: not an object");
  }
  const post = field(root, "postprocess", isObject);
  const languages = field(root, "languages", isObject);
  for (const [lang, id] of Object.entries(languages)) {
    if (!isNumber(id)) throw missing(`languages.${lang}`);
    integerIn(id, `languages.${lang}`, 0, 65535);
  }
  const integer = (key: string, lo: number, hi: number): number =>
    integerIn(field(root, key, isNumber), key, lo, hi);
  const parsed: ArticulinoConfig = {
    sampleRate: integer("sample_rate", 8000, 192000),
    latentDim: integer("latent_dim", 1, 4096),
    samplesPerFrame: integer("samples_per_frame", 1, 65536),
    durationUnitsPerFrame: integer("duration_units_per_frame", 1, 1000),
    prefixFrames: integer("prefix_frames", 0, 100000),
    decoderLeadInFrames: integer("decoder_lead_in_frames", 0, 100000),
    maxDurationUnits: field(root, "max_duration_units", isNumber),
    times: field(root, "times", isNumberArray),
    charset: field(root, "charset", isString),
    languages: languages as Record<string, number>,
    postprocess: {
      lowShelfDb: field(post, "low_shelf_db", isNumber, "postprocess.low_shelf_db"),
      lowShelfHz: field(post, "low_shelf_hz", isNumber, "postprocess.low_shelf_hz"),
      shelfSlope: field(post, "shelf_slope", isNumber, "postprocess.shelf_slope"),
      peak: field(post, "peak", isNumber, "postprocess.peak")
    }
  };
  if (!(parsed.maxDurationUnits > 0 && parsed.maxDurationUnits <= MAX_DURATION_UNITS_CAP)) {
    throw malformed(
      `max_duration_units must be greater than 0 and at most ${MAX_DURATION_UNITS_CAP}`
    );
  }
  parsed.times.forEach((t, k) => {
    if (!(t >= 0 && t < 1)) throw malformed(`times[${k}] must be in [0, 1)`);
  });
  const { peak, shelfSlope } = parsed.postprocess;
  if (!(peak > 0 && peak <= 1)) throw malformed("postprocess.peak must be in (0, 1]");
  if (!(shelfSlope > 0)) throw malformed("postprocess.shelf_slope must be greater than 0");
  return parsed;
}
