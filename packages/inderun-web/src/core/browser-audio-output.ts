import type {
  AbortSignalLike,
  AudioOutputFormat,
  AudioOutputService,
  AudioOutputSession
} from "./host.js";
import { createCapabilityMismatch, createUnavailable, type IndeRunException } from "./errors.js";

/** The slice of AudioContext the service uses; a real AudioContext satisfies it. */
export interface WebAudioContextLike {
  readonly state: "suspended" | "running" | "closed" | "interrupted";
  readonly currentTime: number;
  readonly sampleRate: number;
  readonly baseLatency?: number;
  readonly outputLatency?: number;
  readonly destination: unknown;
  /** Where present, the service listens for `statechange` through it. */
  addEventListener?(type: "statechange", listener: () => void): void;
  /** The `statechange` handler, used where `addEventListener` is missing. */
  onstatechange?: (() => void) | null;
  resume(): Promise<void>;
  createBuffer(numberOfChannels: number, length: number, sampleRate: number): WebAudioBufferLike;
  createBufferSource(): WebAudioSourceLike;
}

/** The slice of AudioBuffer the service uses. */
export interface WebAudioBufferLike {
  readonly duration: number;
  readonly sampleRate: number;
  getChannelData(channel: number): Float32Array;
}

/** The slice of AudioBufferSourceNode the service uses. */
export interface WebAudioSourceLike {
  buffer: WebAudioBufferLike | null;
  onended: (() => void) | null;
  connect(destination: unknown): unknown;
  start(when?: number): void;
  stop(when?: number): void;
}

export interface CreateWebAudioOutputServiceOptions {
  /** Defaults to `() => new AudioContext()`; called once, on the first open(). */
  audioContext?: () => WebAudioContextLike;
  /** Scheduled audio a write() may run ahead of currentTime before it waits. Default 1.0. */
  maxLeadSeconds?: number;
  /** How long open() waits for resume() before reporting audio_not_allowed. Default 500. */
  resumeTimeoutMs?: number;
}

const MIN_SAMPLE_RATE = 8000;
const MAX_SAMPLE_RATE = 48000;
/** Head start given to the first source of a burst so scheduling never lands in the past. */
const START_LEAD_SECONDS = 0.02;

/** Wall-clock milliseconds: `performance.now()` where present, else `Date.now()`. */
function wallClockMs(): number {
  return typeof performance !== "undefined" && typeof performance.now === "function"
    ? performance.now()
    : Date.now();
}

function abortError(): Error {
  const message = "The audio output was aborted.";
  return typeof DOMException === "undefined"
    ? Object.assign(new Error(message), { name: "AbortError" })
    : new DOMException(message, "AbortError");
}

function interrupted(): IndeRunException {
  return createUnavailable("Audio output was interrupted by the system.", {
    details: { code: "audio_output_interrupted" }
  });
}

function assertSupportedFormat(format: AudioOutputFormat): void {
  const { sampleRate, channels, encoding } = format;
  if (
    channels !== 1 ||
    encoding !== "pcm_s16le" ||
    !Number.isFinite(sampleRate) ||
    sampleRate < MIN_SAMPLE_RATE ||
    sampleRate > MAX_SAMPLE_RATE
  ) {
    throw createCapabilityMismatch("Audio output requires mono pcm_s16le at 8000 to 48000 Hz.", {
      details: { code: "audio_format_unsupported", sampleRate, channels, encoding }
    });
  }
}

/**
 * One session on the service's shared context. It ends once: by `stop()`, after which `write`
 * and `drain` return at once, or the system way (`endBySystem`, when the context stops running),
 * after which they throw the ending error.
 */
class WebAudioOutputSession implements AudioOutputSession {
  private readonly live = new Set<WebAudioSourceLike>();
  private readonly waiters = new Set<() => void>();
  private nextStartTime = 0;
  private firstStart: number | undefined;
  private lastSource: WebAudioSourceLike | undefined;
  private stopped = false;
  private endError: IndeRunException | undefined;

  constructor(
    private readonly context: WebAudioContextLike,
    private readonly format: AudioOutputFormat,
    private readonly maxLeadSeconds: number,
    private readonly openedAtContextTime: number,
    /** Wall-clock milliseconds `open()` had spent before this session existed, resume wait included. */
    private readonly openOverheadMs: number,
    private readonly onEnded: (session: WebAudioOutputSession) => void
  ) {}

  /** Whether a source of this session is scheduled or playing. */
  get hasLiveSources(): boolean {
    return this.live.size > 0;
  }

  async write(samples: Int16Array): Promise<void> {
    this.throwIfEnded();
    if (this.stopped || samples.length === 0) {
      return;
    }
    // Audio scheduled on a context that is not running never plays and never ends.
    if (this.context.state !== "running") {
      this.endBySystem(interrupted());
      this.throwIfEnded();
    }

    const floats = new Float32Array(samples.length);
    for (let i = 0; i < samples.length; i += 1) {
      floats[i] = samples[i]! / 32768;
    }
    const buffer = this.context.createBuffer(1, samples.length, this.format.sampleRate);
    buffer.getChannelData(0).set(floats);

    const source = this.context.createBufferSource();
    source.buffer = buffer;
    source.connect(this.context.destination);
    source.onended = () => {
      this.live.delete(source);
      this.notify();
    };

    const startAt = Math.max(this.nextStartTime, this.context.currentTime + START_LEAD_SECONDS);
    this.nextStartTime = startAt + buffer.duration;
    this.firstStart ??= startAt;
    this.live.add(source);
    this.lastSource = source;
    source.start(startAt);

    // Waits until the scheduled lead has fallen to the limit: woken by a source ending, by stop(),
    // or by a timer set for the moment the lead should reach the limit. The timer matters when one
    // chunk is longer than the limit: waiting for that source to end would leave nothing scheduled,
    // and the next write would start START_LEAD_SECONDS after it, an audible gap. The lead is
    // re-read after every wake-up, so a late timer (a throttled tab) only waits again.
    while (!this.stopped && this.leadSeconds() > this.maxLeadSeconds) {
      await this.nextChange((this.leadSeconds() - this.maxLeadSeconds) * 1000);
    }
    this.throwIfEnded();
  }

  /** How far the scheduled audio runs ahead of the context's clock. */
  private leadSeconds(): number {
    return this.nextStartTime - this.context.currentTime;
  }

  async drain(): Promise<void> {
    this.throwIfEnded();
    const last = this.lastSource;
    while (!this.stopped && last !== undefined && this.live.has(last)) {
      await this.nextChange();
    }
    this.throwIfEnded();
  }

  stop(): void {
    this.end(undefined);
  }

  /** Ends the session the system way: pending and later `write`/`drain` calls throw `error`. */
  endBySystem(error: IndeRunException): void {
    this.end(error);
  }

  private end(error: IndeRunException | undefined): void {
    if (this.stopped) {
      return;
    }
    this.stopped = true;
    this.endError = error;
    // A first start the context had not reached never rendered.
    if (this.firstStart !== undefined && this.context.currentTime < this.firstStart) {
      this.firstStart = undefined;
    }
    for (const source of this.live) {
      source.onended = null;
      try {
        source.stop();
      } catch {
        // A source that already ended throws InvalidStateError; it is stopped either way.
      }
    }
    this.live.clear();
    this.onEnded(this);
    this.notify();
  }

  private throwIfEnded(): void {
    if (this.endError !== undefined) {
      throw this.endError;
    }
  }

  /**
   * Counted from the start of `open()`. The web value is the time `open()` spent before the
   * session existed (wall clock, the resume wait included, because a suspended context's
   * `currentTime` does not advance) plus the scheduled start and the output latency the context
   * reports (context clock). It is not a frame observed leaving the output; Web Audio exposes no
   * such observation.
   */
  firstAudioMs(): number | undefined {
    if (this.firstStart === undefined || this.context.currentTime < this.firstStart) {
      return undefined;
    }
    const latency = this.context.outputLatency ?? this.context.baseLatency ?? 0;
    return this.openOverheadMs + (this.firstStart + latency - this.openedAtContextTime) * 1000;
  }

  /** Resolves on the next `notify()`, or after `timeoutMs` when given; the timer never outlives it. */
  private nextChange(timeoutMs?: number): Promise<void> {
    return new Promise((resolve) => {
      let timer: ReturnType<typeof setTimeout> | undefined;
      const wake = (): void => {
        clearTimeout(timer);
        this.waiters.delete(wake);
        resolve();
      };
      this.waiters.add(wake);
      if (timeoutMs !== undefined) {
        timer = setTimeout(wake, Math.max(0, timeoutMs));
      }
    });
  }

  private notify(): void {
    const waiting = [...this.waiters];
    this.waiters.clear();
    for (const resolve of waiting) {
      resolve();
    }
  }
}

/**
 * Plays PCM through Web Audio. The AudioContext is created on the first `open()`, once per
 * service, and never closed; building the service touches no browser global.
 *
 * The service listens for the context's `statechange`: when the context stops running after an
 * `open()` (the browser suspends or interrupts it), every session with audio scheduled or playing
 * ends with `Unavailable` `audio_output_interrupted`, since that audio would neither play nor
 * end. A session with nothing scheduled is left alone; its next `write` ends it the same way if
 * the context is still not running.
 */
export function createWebAudioOutputService(
  options: CreateWebAudioOutputServiceOptions = {}
): AudioOutputService {
  const maxLeadSeconds = options.maxLeadSeconds ?? 1.0;
  const resumeTimeoutMs = options.resumeTimeoutMs ?? 500;
  const createContext = options.audioContext ?? (() => new AudioContext() as WebAudioContextLike);
  let shared: WebAudioContextLike | undefined;
  const sessions = new Set<WebAudioOutputSession>();
  const onStateChange = (): void => {
    if (shared === undefined || shared.state === "running") {
      return;
    }
    for (const session of [...sessions]) {
      if (session.hasLiveSources) {
        session.endBySystem(interrupted());
      }
    }
  };

  return {
    async open(format: AudioOutputFormat, signal?: AbortSignalLike): Promise<AudioOutputSession> {
      // The session's firstAudioMs() counts from here, the start of open().
      const openStartedAt = wallClockMs();
      assertSupportedFormat(format);
      if (signal?.aborted) {
        throw abortError();
      }

      if (shared === undefined) {
        let created: WebAudioContextLike;
        try {
          created = createContext();
        } catch (error) {
          throw createUnavailable("The browser audio context could not be created.", {
            details: {
              code: "audio_output_failed",
              reason: error instanceof Error ? error.message : String(error)
            }
          });
        }
        if (typeof created.addEventListener === "function") {
          created.addEventListener("statechange", onStateChange);
        } else {
          created.onstatechange = onStateChange;
        }
        shared = created;
      }
      const context = shared;

      if (context.state !== "running") {
        await resumeOrFail(context, resumeTimeoutMs, signal);
      }

      const session = new WebAudioOutputSession(
        context,
        format,
        maxLeadSeconds,
        context.currentTime,
        wallClockMs() - openStartedAt,
        (ended) => sessions.delete(ended)
      );
      sessions.add(session);
      return session;
    }
  };
}

async function resumeOrFail(
  context: WebAudioContextLike,
  timeoutMs: number,
  signal: AbortSignalLike | undefined
): Promise<void> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  let onAbort: (() => void) | undefined;
  const gate = new Promise<void>((resolve, reject) => {
    timer = setTimeout(resolve, timeoutMs);
    if (signal) {
      onAbort = () => reject(abortError());
      signal.addEventListener("abort", onAbort, { once: true });
    }
  });

  try {
    await Promise.race([context.resume().catch(() => undefined), gate]);
  } finally {
    clearTimeout(timer);
    if (signal && onAbort) {
      signal.removeEventListener("abort", onAbort);
    }
  }

  if (context.state !== "running") {
    throw createUnavailable("The browser did not allow audio playback to start.", {
      details: { code: "audio_not_allowed" }
    });
  }
}
