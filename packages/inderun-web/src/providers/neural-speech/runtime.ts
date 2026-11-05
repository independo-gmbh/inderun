import type { ModelPackage } from "@independo/inderun-contracts";

/**
 * One block of mono 16-bit PCM produced by a runtime.
 *
 * `sampleRate` must equal the package's `speech.sampleRate`; the provider never resamples and
 * treats any other rate as an internal error.
 */
export interface PcmChunk {
  samples: Int16Array;
  sampleRate: number;
  /** True on the final chunk of one sentence. */
  isLast: boolean;
}

/** A named tensor exchanged with a graph executor. */
export interface SpeechTensor {
  shape: number[];
  data: Float32Array | BigInt64Array;
}

/** Runs one graph of a package; implemented by the ORT and Core AI executors (PR 4, PR 5). */
export interface SpeechGraphExecutor {
  /**
   * Loads every graph, keyed by role. A load replaces what an earlier load left: the previous
   * graphs are released and only the ones given here can run. A pipeline runtime calls it once
   * per successful `prepare` of a package, and again only after a failed one.
   */
  load(graphs: Record<string, string>): Promise<void>;
  run(role: string, inputs: Record<string, SpeechTensor>): Promise<Record<string, SpeechTensor>>;
  close?(): Promise<void>;
}

/** Reads a package's files by the relative names a ModelPackage uses. */
export interface SpeechPackageFiles {
  read(file: string): Promise<Uint8Array>;
}

/**
 * Throws `model file name invalid: <file>` (capability) for a name a package file may not have:
 * empty, absolute (a leading `/` or `\`, or a URL scheme), or with a `..` component, so a package
 * cannot reach outside its directory. Every package file reader and graph executor applies it.
 */
export function checkPackageFileName(file: string): void {
  if (
    file.length === 0 ||
    /^[/\\]/u.test(file) ||
    /^[a-z][a-z0-9+.-]*:/iu.test(file) ||
    file.split(/[/\\]/u).includes("..")
  ) {
    throw new NeuralSpeechRuntimeError("capability", `model file name invalid: ${file}`);
  }
}

/** Availability snapshot reported by a neural speech runtime. */
export interface NeuralSpeechAvailability {
  available: boolean;
  /** Human-readable detail; the provider surfaces it verbatim when `available` is false. */
  reason?: string;
}

/** One sentence handed to a neural speech runtime. */
export interface NeuralSpeechSynthesisInput {
  modelPackage: ModelPackage;
  text: string;
  locale: string;
  voiceId: string;
  /** When aborted, the iteration ends without throwing. */
  signal?: AbortSignal;
}

/**
 * Executes a speech model package.
 *
 * `availability` is also where an unknown `pipeline` is refused, with the reason verbatim. The
 * Web SDK has no host memory API, so no web runtime refuses `limits.memBytes`; the composed ONNX
 * runtimes of the Swift and Kotlin SDKs do. `prepare` loads the model and is idempotent on success:
 * the same package (`id@version`) prepared again returns the remembered outcome; only a failed
 * prepare is retried. `synthesize` is called once per sentence; an aborted `signal` ends the
 * iteration without throwing. On a timeout the provider aborts the signal and leaves the iteration
 * without waiting for it, so compute still running must stay bounded to that sentence.
 *
 * The provider consumes (copies or hands to the host) a chunk's samples before the yield returns,
 * so a runtime may reuse its buffer afterwards.
 *
 * `synthesize` may be called concurrently: artifact runs do not wait for the playback turn, and two
 * providers may share one runtime instance. A runtime must serialize or isolate its own sessions.
 */
export interface NeuralSpeechRuntime {
  availability(pkg: ModelPackage): Promise<NeuralSpeechAvailability>;
  prepare(pkg: ModelPackage): Promise<NeuralSpeechAvailability>;
  synthesize(input: NeuralSpeechSynthesisInput): AsyncIterable<PcmChunk>;
}

/**
 * Failure category a runtime signals so the provider maps it onto the IndeRun error taxonomy.
 * Anything else a runtime throws is normalized to `Internal`.
 */
export type NeuralSpeechRuntimeErrorKind = "capability" | "unavailable" | "timeout" | "internal";

/** Error type neural speech runtimes throw to steer IndeRun error normalization. */
export class NeuralSpeechRuntimeError extends Error {
  readonly kind: NeuralSpeechRuntimeErrorKind;
  readonly originalError?: unknown;

  constructor(kind: NeuralSpeechRuntimeErrorKind, message: string, originalError?: unknown) {
    super(message);
    this.name = "NeuralSpeechRuntimeError";
    this.kind = kind;
    if (originalError !== undefined) this.originalError = originalError;

    Object.setPrototypeOf(this, NeuralSpeechRuntimeError.prototype);
  }
}
