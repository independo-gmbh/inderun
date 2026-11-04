import type {
  AbortSignalLike,
  AudioOutputFormat,
  AudioOutputService,
  AudioOutputSession
} from "@independo/inderun-contracts";

import { createCapabilityMismatch, type IndeRunException } from "../core/errors.js";

export interface FixtureAudioOutputSession extends AudioOutputSession {
  readonly format: AudioOutputFormat;
  readonly writes: Int16Array[];
  readonly writtenFrames: number;
  readonly playedFrames: number;
  readonly discardedFrames: number;
  readonly playing: boolean;
  readonly stopped: boolean;
  /**
   * Ends the session the way the system does (an interruption): buffered audio is discarded,
   * and every later `write()` and `drain()` throws `error`. After `stop()` they return instead.
   */
  interrupt(error: IndeRunException): void;
}

export interface FixtureAudioOutput {
  service: AudioOutputService;
  sessions: FixtureAudioOutputSession[];
  /** Virtual milliseconds; advanced only by drain(). */
  now(): number;
}

interface Clock {
  ms: number;
}

class FixtureSession implements FixtureAudioOutputSession {
  readonly writes: Int16Array[] = [];
  private written = 0;
  private played = 0;
  private discarded = 0;
  private isPlaying = false;
  private isStopped = false;
  private endError: IndeRunException | undefined;
  private firstAudio: number | undefined;
  private readonly openedAt: number;

  constructor(
    readonly format: AudioOutputFormat,
    private readonly clock: Clock
  ) {
    this.openedAt = clock.ms;
  }

  get writtenFrames(): number {
    return this.written;
  }
  get playedFrames(): number {
    return this.played;
  }
  get discardedFrames(): number {
    return this.discarded;
  }
  get playing(): boolean {
    return this.isPlaying;
  }
  get stopped(): boolean {
    return this.isStopped;
  }

  async write(samples: Int16Array): Promise<void> {
    if (this.endError) throw this.endError;
    if (this.isStopped) return;
    this.writes.push(samples);
    this.written += samples.length;
    if (this.firstAudio === undefined) {
      this.firstAudio = this.clock.ms - this.openedAt;
      this.isPlaying = true;
    }
  }

  async drain(): Promise<void> {
    if (this.endError) throw this.endError;
    if (this.isStopped) return;
    const pending = this.written - this.played;
    this.clock.ms += (pending * 1000) / this.format.sampleRate;
    this.played = this.written;
  }

  stop(): void {
    this.end(undefined);
  }

  interrupt(error: IndeRunException): void {
    this.end(error);
  }

  private end(error: IndeRunException | undefined): void {
    if (this.isStopped) return;
    this.isStopped = true;
    this.endError = error;
    this.isPlaying = false;
    this.discarded += this.written - this.played;
  }

  firstAudioMs(): number | undefined {
    return this.firstAudio;
  }
}

/**
 * A recording audio output with a virtual clock: `now()` starts at 0 and only `drain()`
 * advances it, by the duration of the frames not yet played. `write()` resolves at once.
 */
export function createFixtureAudioOutput(): FixtureAudioOutput {
  const clock: Clock = { ms: 0 };
  const sessions: FixtureAudioOutputSession[] = [];
  const service: AudioOutputService = {
    async open(format: AudioOutputFormat, signal?: AbortSignalLike): Promise<AudioOutputSession> {
      if (
        format.channels !== 1 ||
        format.encoding !== "pcm_s16le" ||
        format.sampleRate < 8000 ||
        format.sampleRate > 48000
      ) {
        throw createCapabilityMismatch("The audio output does not support this format.", {
          details: { code: "audio_format_unsupported" }
        });
      }
      if (signal?.aborted) {
        throw new DOMException("Opening the audio output was cancelled.", "AbortError");
      }
      const session = new FixtureSession(format, clock);
      sessions.push(session);
      return session;
    }
  };
  return { service, sessions, now: () => clock.ms };
}
