import {
  getModelPackageValidationIssues,
  type AudioOutputFormat,
  type AudioOutputSession,
  type ModelPackage,
  type ModelSourceType,
  type PlaybackTiming,
  type TaskOutput,
  type TaskRequest,
  type TaskResult
} from "@independo/inderun-contracts";
import {
  createCapabilityMismatch,
  createInternal,
  createTimeout,
  createUnavailable,
  toIndeRunException,
  type IndeRunException
} from "../../core/errors.js";
import type { HostServices } from "../../core/host.js";
import type {
  PreparableProviderAdapter,
  ProviderDescriptor,
  ProviderDynamicCapabilities,
  ProviderPrepareContext,
  ProviderStreamContext,
  ProviderStreamEvent,
  RunContext
} from "../../core/provider.js";
import { splitSentences } from "./frontend.js";
import {
  NeuralSpeechRuntimeError,
  type NeuralSpeechAvailability,
  type NeuralSpeechRuntime,
  type PcmChunk
} from "./runtime.js";
import { encodeWav, WAV_HEADER_BYTES } from "./wav.js";

/** Default provider id of the Web neural speech provider; an instance composes `<id>:<package id>`. */
export const DEFAULT_NEURAL_SPEECH_WEB_PROVIDER_ID = "local.onnx.speech.web";

/**
 * Model source types the Web neural speech provider can honor: browsers expose no arbitrary local
 * paths (`filesystem`), and hosts download `remote` files themselves and hand them over as one of
 * these.
 */
export const SUPPORTED_WEB_NEURAL_SPEECH_MODEL_SOURCE_TYPES: readonly ModelSourceType[] = [
  "registry",
  "bundled",
  "programmatic",
  "app_managed"
];

/**
 * Largest WAV artifact this provider writes. Duplicates the engine's default per-artifact limit
 * on purpose, as the system speech providers do, so synthesis stops at the cap instead of
 * producing audio the store would refuse.
 */
export const MAX_ARTIFACT_BYTES = 16 * 1024 * 1024;

const TASK = "text_to_speech";

type SpeechModelPackage = NonNullable<ModelPackage["speech"]>;
type PackageVoice = SpeechModelPackage["voices"][number];

/** Options for {@link NeuralSpeechWebProvider}. */
export interface NeuralSpeechProviderOptions {
  /** Defaults to `<DEFAULT_NEURAL_SPEECH_WEB_PROVIDER_ID>:<modelPackage.id>`. */
  id?: string;
  /** The speech model package: its `speech` block names the pipeline, graphs and voices. */
  modelPackage: ModelPackage;
  /** Executes the package. Required: no default runtime ships yet. */
  runtime: NeuralSpeechRuntime;
  /**
   * Bounds the synthesis until the run commits: the wait for the first chunk when playing, the
   * whole synthesis up to `finish()` when writing an artifact. A request's `constraints.timeoutMs`
   * wins; zero or less is unbounded.
   */
  timeoutMs?: number;
}

/**
 * Text-to-speech with a developer-supplied neural speech model, synthesized in-process by a
 * {@link NeuralSpeechRuntime} and played through the host's `audioOutput` or returned as an
 * `audio/wav` artifact.
 *
 * Playback: the provider takes its turn (one utterance at a time per instance, first in first
 * out; a call cancelled while waiting holds its place and plays nothing), checks the host has an
 * `audioOutput` (`audio_output_unavailable`) and that the bound voice is one of the package's
 * (`voice_not_available`), loads the model, splits the text into sentences and opens one output
 * session. It then synthesizes sentence by sentence and commits on the first chunk, immediately
 * before the first `write()`; a cancel before that point returns quietly with nothing written.
 * After commit, a cancel stops the session (buffered audio is discarded) and stops consuming the
 * runtime, and any error ends the run without fallback. A normal end drains, then stops. The
 * session is stopped on every exit. Chunks must carry the package's sample rate: it never
 * resamples.
 *
 * Artifact: the same checks without the audio output. PCM is buffered in memory; when the next
 * chunk would make the WAV exceed {@link MAX_ARTIFACT_BYTES}, synthesis stops and the run fails
 * uncommitted with `artifact_too_large`. Otherwise the WAV is written once and `finish()` commits.
 *
 * Timing: `firstChunkMs`, `firstAudioMs` and `durationMs` count from the moment the request
 * arrived (`receivedAt`), before the turn wait. `firstAudioMs` = (instant before `open()` was
 * called − `receivedAt`) + `session.firstAudioMs()`, which every host measures from the start of
 * its `open()`, so a slow open is counted once; it is absent when the session reports none.
 *
 * Cancellation is `hard`: audio stops at once; residual compute is bounded to the in-flight
 * sentence and is never audible. A cancel stops the session directly, also while a `write()` waits
 * on backpressure or `drain()` waits for buffered audio to play; the stream then ends quietly.
 *
 * Timeout: the budget (a request's `constraints.timeoutMs`, else `timeoutMs`; zero or less is
 * unbounded) bounds the time until the run commits, counted from the start of synthesis. Playback:
 * it bounds the wait for the first chunk only; after commit nothing times out, and a runtime that
 * stalls is ended only by a cancel, as with the system speech providers. Artifact: it bounds the
 * whole synthesis, across sentences, up to `finish()`: one absolute deadline, checked again before
 * the artifact is created and immediately before `finish()`; past it, the writer is aborted. Expiry
 * throws `Timeout` at once, without waiting for the runtime, and always before commit, so the run
 * can fall back.
 *
 * Interaction: implements {@link PreparableProviderAdapter} plus `stream()`. `run()` and
 * `stream()` both serve playback and artifact delivery; only `stream()` can be cancelled.
 */
export class NeuralSpeechWebProvider implements PreparableProviderAdapter {
  readonly id: string;
  private readonly modelPackage: ModelPackage;
  private readonly runtime: NeuralSpeechRuntime;
  private readonly timeoutMs: number | undefined;
  private loaded = false;
  private loadFailure: string | undefined;
  private loading: Promise<void> | undefined;
  private tail: Promise<void> = Promise.resolve();

  constructor(options: NeuralSpeechProviderOptions) {
    this.id = options.id ?? `${DEFAULT_NEURAL_SPEECH_WEB_PROVIDER_ID}:${options.modelPackage.id}`;
    this.modelPackage = options.modelPackage;
    this.runtime = options.runtime;
    this.timeoutMs = options.timeoutMs;
  }

  describe(): ProviderDescriptor {
    const locales = [
      ...new Set((this.modelPackage.speech?.voices ?? []).flatMap((voice) => voice.locales))
    ];
    return {
      id: this.id,
      type: "local",
      model: this.modelPackage.id,
      transport: "in_process",
      supports: {
        run: true,
        // Lifecycle only: the stream carries no audio, it is what `speak()` can cancel.
        streaming: true,
        realtime: false,
        tools: false,
        reasoningEvents: false,
        structuredOutput: false,
        multimodal: false
      },
      cancel: "hard",
      tasks: [TASK],
      taskCapabilities: [
        {
          kind: TASK,
          inputs: ["text"],
          interaction: { prepare: true, run: true, stream: true },
          cancel: "hard",
          outputs: [{ delivery: "playback" }, { delivery: "artifact", mediaTypes: ["audio/wav"] }],
          ...(locales.length > 0 ? { locales } : {}),
          privacy: { dataLeavesDevice: false }
        }
      ],
      privacy: { dataLeavesDevice: false }
    };
  }

  /** Never loads the model: a cold provider reports `readiness: "cold"` until it is loaded. */
  async capabilities(_host: HostServices): Promise<ProviderDynamicCapabilities> {
    const pkg = this.modelPackage;
    const issues = getModelPackageValidationIssues(pkg);
    if (issues.length > 0) {
      const summary = issues.map((issue) => `${issue.path} ${issue.message}`).join("; ");
      return { available: false, reason: `model package malformed: ${summary}` };
    }

    const tasks = Array.isArray(pkg.tasks) ? pkg.tasks : [];
    if (!tasks.includes(TASK) || pkg.speech === undefined) {
      return {
        available: false,
        reason: `unsupported task: the model package declares ${tasks.join(", ") || "no tasks"} and no speech pipeline for '${TASK}'.`
      };
    }

    const channels = pkg.speech.channels;
    if (channels !== undefined && channels !== 1) {
      return { available: false, reason: `unsupported channels: ${channels}` };
    }

    const sourceType = pkg.source?.sourceType;
    if (
      sourceType !== undefined &&
      !SUPPORTED_WEB_NEURAL_SPEECH_MODEL_SOURCE_TYPES.includes(sourceType)
    ) {
      return {
        available: false,
        reason: `model source unavailable: '${sourceType}' model sources are unsupported on Web; supply model files as ${SUPPORTED_WEB_NEURAL_SPEECH_MODEL_SOURCE_TYPES.join(", ")}.`
      };
    }

    const platforms = pkg.runtime?.platforms;
    if (Array.isArray(platforms) && platforms.length > 0 && !platforms.includes("web")) {
      return {
        available: false,
        reason: `platform unsupported: the model package targets ${platforms.join(", ")} and does not list 'web'.`
      };
    }

    let availability: NeuralSpeechAvailability;
    try {
      availability = await this.runtime.availability(pkg);
    } catch (error) {
      // A throwing runtime must not take routing down for every other provider.
      return { available: false, reason: `runtime availability failed: ${messageOf(error)}` };
    }
    if (!availability.available) {
      return {
        available: false,
        reason: availability.reason ?? "The neural speech runtime cannot run this package."
      };
    }
    if (this.loadFailure !== undefined) return { available: false, reason: this.loadFailure };

    // Until the provider has loaded the model, the runtime's hint (when it gives one) wins over `cold`.
    const readiness = this.loaded ? undefined : (availability.readiness ?? "cold");
    const voiceReadiness =
      this.loaded || availability.readiness === undefined
        ? {}
        : { readiness: availability.readiness };
    return {
      available: true,
      taskCapabilities: [
        {
          kind: TASK,
          voices: pkg.speech.voices.map((voice) => ({
            ...toListedVoice(voice),
            ...voiceReadiness
          })),
          ...(readiness === undefined ? {} : { readiness })
        }
      ]
    };
  }

  /** Loads the model ahead of the first run. Nothing is downloaded: the host supplies the files. */
  async *prepare(context: ProviderPrepareContext): AsyncIterable<{ fractionCompleted?: number }> {
    yield {};
    await this.ensureLoaded(context.runId);
  }

  async run(request: TaskRequest, context: RunContext): Promise<TaskResult> {
    const output =
      request.delivery?.mode === "artifact"
        ? await this.writeArtifact(request, context)
        : await this.play(request, context);
    if (output === undefined) {
      throw createUnavailable("The run ended before playback could start.", {
        runId: context.runId,
        providerId: this.id
      });
    }
    return {
      schemaVersion: "1.0",
      runId: context.runId,
      output,
      finishReason: "stop",
      telemetry: { providerUsed: this.id, totalMs: 0 }
    };
  }

  /**
   * The stream carries no audio: it is only the run's lifecycle. It ends with a `result` event, or
   * quietly when stopped, because the engine owns the `cancelled` terminal.
   */
  async *stream(
    request: TaskRequest,
    context: ProviderStreamContext
  ): AsyncIterable<ProviderStreamEvent> {
    const output =
      request.delivery?.mode === "artifact"
        ? await this.writeArtifact(request, context, context.signal)
        : await this.play(request, context, context.signal);
    if (output !== undefined) yield { kind: "result", output, finishReason: "stop" };
  }

  /** @returns The output, or `undefined` when cancelled (before or after commit). */
  private async play(
    request: TaskRequest,
    context: RunContext,
    signal?: AbortSignal
  ): Promise<TaskOutput | undefined> {
    // The origin of every timing: before the turn wait, voice check and commit.
    const receivedAt = Date.now();
    const speech = this.validated(request, context, "playback");

    return this.inTurn(signal, async () => {
      const audioOutput = context.hostServices.audioOutput;
      if (audioOutput === undefined) {
        throw createCapabilityMismatch("The host offers no audio output to play speech.", {
          runId: context.runId,
          providerId: this.id,
          details: { code: "audio_output_unavailable" }
        });
      }
      const { voice, locale, spokenLocale, speechPackage } = this.resolveVoice(speech, context);
      await this.ensureLoaded(context.runId);
      const sentences = await this.sentencesOf(speech.text, spokenLocale, context, signal);
      if (sentences === undefined) return undefined;

      const format: AudioOutputFormat = {
        sampleRate: speechPackage.sampleRate,
        channels: 1,
        encoding: "pcm_s16le"
      };
      // The session measures firstAudioMs() from the start of its own open(), so the shift to the
      // request-received origin counts from the instant before the call, not from its return.
      const openStartedAt = Date.now();
      let session: AudioOutputSession;
      try {
        session = await audioOutput.open(format, signal);
      } catch (error) {
        if (cancelled(signal)) return undefined;
        throw error;
      }
      // A cancel stops the output at once, also while a write waits on backpressure or drain()
      // waits for the buffered audio to play.
      const stopOnCancel = () => session.stop();
      signal?.addEventListener("abort", stopOnCancel, { once: true });
      const budget = createBudget(this.budgetMs(request));

      try {
        const playing = await this.playSentences(session, sentences, {
          budget,
          context,
          voiceId: voice.id,
          locale,
          budgetEndsAtFirstChunk: true,
          ...(signal !== undefined ? { signal } : {})
        });
        if (playing === undefined) return undefined;
        await session.drain();
        if (cancelled(signal)) return undefined;
        const sessionFirstAudio = session.firstAudioMs();

        const timing: PlaybackTiming = {
          firstChunkMs: playing.firstChunkAt - receivedAt,
          durationMs: (playing.frames / format.sampleRate) * 1000,
          // The session counts from the start of open(); shift it to the request-received origin.
          ...(sessionFirstAudio !== undefined
            ? { firstAudioMs: openStartedAt - receivedAt + sessionFirstAudio }
            : {})
        };
        return {
          type: "playback",
          playback: { timing },
          speech: { locale, voice: { id: voice.id, name: voice.name } }
        };
      } catch (error) {
        if (cancelled(signal)) return undefined;
        throw error;
      } finally {
        budget.end();
        signal?.removeEventListener("abort", stopOnCancel);
        session.stop();
      }
    });
  }

  /**
   * Writes every sentence's chunks to `session`, committing immediately before the first write.
   * @returns When the first chunk arrived and how many frames were written, or `undefined` when
   *   cancelled; the caller stops the session either way.
   */
  private async playSentences(
    session: AudioOutputSession,
    sentences: string[],
    synthesis: SynthesisRequest
  ): Promise<{ firstChunkAt: number; frames: number } | undefined> {
    const { context, signal } = synthesis;
    let firstChunkAt: number | undefined;
    let frames = 0;
    for await (const chunk of this.synthesize(sentences, synthesis)) {
      if (firstChunkAt === undefined) {
        firstChunkAt = Date.now();
        if (cancelled(signal) || !context.commit()) return undefined;
      }
      frames += chunk.samples.length;
      await session.write(chunk.samples);
      if (cancelled(signal)) return undefined;
    }
    if (cancelled(signal)) return undefined;
    if (firstChunkAt === undefined) throw this.noAudio(context.runId);
    return { firstChunkAt, frames };
  }

  /** @returns The artifact output, or `undefined` when cancelled. */
  private async writeArtifact(
    request: TaskRequest,
    context: RunContext,
    signal?: AbortSignal
  ): Promise<TaskOutput | undefined> {
    const speech = this.validated(request, context, "artifact");
    const { voice, locale, spokenLocale, speechPackage } = this.resolveVoice(speech, context);
    await this.ensureLoaded(context.runId);
    const sentences = await this.sentencesOf(speech.text, spokenLocale, context, signal);
    if (sentences === undefined) return undefined;

    // One absolute deadline for the whole artifact: synthesis, then the checks before create()
    // and finish().
    const budget = createBudget(this.budgetMs(request));
    try {
      const chunks: Int16Array[] = [];
      let frames = 0;
      for await (const chunk of this.synthesize(sentences, {
        budget,
        context,
        voiceId: voice.id,
        locale,
        budgetEndsAtFirstChunk: false,
        ...(signal !== undefined ? { signal } : {})
      })) {
        // Leaving the loop ends the runtime's iteration, so synthesis stops at the cap.
        if (WAV_HEADER_BYTES + 2 * (frames + chunk.samples.length) > MAX_ARTIFACT_BYTES) {
          throw createUnavailable("The synthesized audio exceeds the artifact size limit.", {
            runId: context.runId,
            providerId: this.id,
            details: { code: "artifact_too_large" }
          });
        }
        // Copied on receipt: the runtime may refill the same buffer for its next chunk.
        chunks.push(chunk.samples.slice());
        frames += chunk.samples.length;
      }
      if (cancelled(signal)) return undefined;
      if (frames === 0) throw this.noAudio(context.runId);

      const samples = new Int16Array(frames);
      let offset = 0;
      for (const chunk of chunks) {
        samples.set(chunk, offset);
        offset += chunk.length;
      }
      if (budget.passed()) throw this.timedOut(context.runId);
      const writer = context.artifacts.create({
        mediaType: "audio/wav",
        durationMs: (frames / speechPackage.sampleRate) * 1000
      });
      try {
        writer.write(encodeWav(samples, speechPackage.sampleRate));
        if (budget.passed()) throw this.timedOut(context.runId);
        const artifact = writer.finish();
        return {
          type: "artifact",
          artifact,
          speech: { locale, voice: { id: voice.id, name: voice.name } }
        };
      } catch (error) {
        writer.abort();
        if (cancelled(signal)) return undefined;
        throw error;
      }
    } finally {
      budget.end();
    }
  }

  /**
   * Synthesizes the sentences in order. Each runtime call gets its own abort signal, fired by the
   * caller's cancel. The caller's budget, created at the start of synthesis, races every pull from
   * the runtime until it ends: at the first chunk when `budgetEndsAtFirstChunk`, else when the
   * caller ends it. On expiry it throws `Timeout` at once and leaves the runtime's iteration
   * without waiting for it. A cancel ends the iteration quietly; a chunk at another sample rate
   * throws `Internal`.
   */
  private async *synthesize(
    sentences: string[],
    synthesis: SynthesisRequest
  ): AsyncGenerator<PcmChunk> {
    const { budget, context, signal, voiceId, locale, budgetEndsAtFirstChunk } = synthesis;
    const sampleRate = this.modelPackage.speech!.sampleRate;

    for (const text of sentences) {
      if (cancelled(signal)) return;
      const controller = new AbortController();
      const onCancel = () => controller.abort();
      signal?.addEventListener("abort", onCancel, { once: true });
      const chunks = this.runtime
        .synthesize({
          modelPackage: this.modelPackage,
          text,
          locale,
          voiceId,
          signal: controller.signal
        })
        [Symbol.asyncIterator]();
      let timedOut = false;
      let exhausted = false;
      try {
        while (true) {
          const step = await budget.race(chunks.next());
          if (step === EXPIRED) {
            timedOut = true;
            break;
          }
          if (step.done === true) {
            exhausted = true;
            break;
          }
          if (controller.signal.aborted) break;
          const chunk = step.value;
          if (chunk.sampleRate !== sampleRate) {
            throw createInternal(
              `The runtime produced ${chunk.sampleRate} Hz audio for a ${sampleRate} Hz package; the provider never resamples.`,
              { runId: context.runId, providerId: this.id }
            );
          }
          if (budgetEndsAtFirstChunk) budget.end();
          yield chunk;
        }
      } catch (error) {
        if (cancelled(signal)) return;
        throw this.mapRuntimeError(error, context.runId);
      } finally {
        signal?.removeEventListener("abort", onCancel);
        controller.abort();
        // Not awaited: a runtime stuck in a step must not hold up the timeout or the cancel.
        if (!exhausted) void chunks.return?.().catch(() => undefined);
      }
      if (timedOut) throw this.timedOut(context.runId);
    }
  }

  /** A request's `constraints.timeoutMs`, else the option; zero or less is unbounded. */
  private budgetMs(request: TaskRequest): number | undefined {
    const timeoutMs = request.constraints?.timeoutMs ?? this.timeoutMs;
    return timeoutMs !== undefined && timeoutMs > 0 ? timeoutMs : undefined;
  }

  private validated(
    request: TaskRequest,
    context: RunContext,
    mode: "playback" | "artifact"
  ): NonNullable<TaskRequest["speech"]> {
    const { speech, delivery } = request;
    if (speech === undefined || delivery?.mode !== mode) {
      throw createCapabilityMismatch(
        "Neural speech can only play or write text-to-speech requests.",
        { runId: context.runId, providerId: this.id }
      );
    }
    return speech;
  }

  /**
   * Picks the package voice that speaks. A voice the plan bound must be one of the package's,
   * else the run is refused before commit so it can still fall back. Unbound, the request's voice
   * id is honoured when the package has it, then the first voice for the request's language,
   * then the first voice.
   */
  private resolveVoice(
    speech: NonNullable<TaskRequest["speech"]>,
    context: RunContext
  ): {
    voice: PackageVoice;
    locale: string;
    spokenLocale: string;
    speechPackage: SpeechModelPackage;
  } {
    const speechPackage = this.modelPackage.speech;
    if (speechPackage === undefined) {
      throw createCapabilityMismatch("The model package has no speech pipeline.", {
        runId: context.runId,
        providerId: this.id
      });
    }
    const voices = speechPackage.voices;
    const bound = context.voice?.id;
    let voice: PackageVoice | undefined;
    if (bound !== undefined) {
      voice = voices.find((candidate) => candidate.id === bound);
      if (voice === undefined) {
        throw createCapabilityMismatch(`The model package has no voice '${bound}'.`, {
          runId: context.runId,
          providerId: this.id,
          details: { code: "voice_not_available" }
        });
      }
    } else {
      const requested = speech.voice?.id;
      voice =
        voices.find((candidate) => requested !== undefined && candidate.id === requested) ??
        voices.find((candidate) =>
          candidate.locales.some((tag: string) => sameLanguage(tag, speech.locale))
        ) ??
        voices[0];
    }
    const locale = localeFor(voice, speech.locale);
    // The tag the text is spoken in: the request's own (de-AT) while the voice speaks its
    // language, else the voice's first locale.
    const spokenLocale = voice.locales.some((tag: string) => sameLanguage(tag, speech.locale))
      ? speech.locale
      : (voice.locales[0] ?? locale);
    return { voice, locale, spokenLocale, speechPackage };
  }

  /** @returns The sentences to speak, or `undefined` when the run was cancelled meanwhile. */
  private async sentencesOf(
    text: string,
    spokenLocale: string,
    context: RunContext,
    signal: AbortSignal | undefined
  ): Promise<string[] | undefined> {
    let normalized: string;
    try {
      normalized =
        (await this.runtime.normalizeText?.(this.modelPackage, text, spokenLocale)) ?? text;
    } catch (error) {
      if (cancelled(signal)) return undefined;
      throw this.mapRuntimeError(error, context.runId);
    }
    if (cancelled(signal)) return undefined;
    const sentences = splitSentences(normalized);
    if (sentences.length === 0) {
      throw createCapabilityMismatch("The text has nothing to say.", {
        runId: context.runId,
        providerId: this.id
      });
    }
    return sentences;
  }

  /**
   * Loads the model once; concurrent callers share one load. A failed load is remembered, so
   * routing stops choosing this provider instead of every call retrying it; it refuses before any
   * output, so the run can fall back.
   */
  private async ensureLoaded(runId: string): Promise<void> {
    if (this.loaded) return;
    if (this.loadFailure === undefined) {
      this.loading ??= this.runtime
        .prepare(this.modelPackage)
        .then((result) => {
          if (result.available) this.loaded = true;
          else this.loadFailure = result.reason ?? "The speech model failed to load.";
        })
        .finally(() => {
          this.loading = undefined;
        });
      try {
        await this.loading;
      } catch (error) {
        throw this.mapRuntimeError(error, runId);
      }
    }
    if (!this.loaded) {
      throw createCapabilityMismatch(this.loadFailure ?? "The speech model failed to load.", {
        providerId: this.id,
        runId
      });
    }
  }

  /**
   * Runs `task` once every earlier call has ended, or not at all when `signal` fires first. A call
   * that leaves early still holds its place, so the order of those behind it does not change.
   */
  private async inTurn<T>(
    signal: AbortSignal | undefined,
    task: () => Promise<T | undefined>
  ): Promise<T | undefined> {
    const previous = this.tail;
    let release!: () => void;
    this.tail = new Promise((resolve) => {
      release = resolve;
    });
    const aborted = await untilTurnOrAbort(previous, signal);
    if (aborted) {
      void previous.then(release);
      return undefined;
    }
    try {
      return await task();
    } finally {
      release();
    }
  }

  private noAudio(runId: string): IndeRunException {
    return createInternal("The neural speech runtime produced no audio.", {
      runId,
      providerId: this.id
    });
  }

  private timedOut(runId: string): IndeRunException {
    return createTimeout("Neural speech synthesis timed out.", { runId, providerId: this.id });
  }

  private mapRuntimeError(error: unknown, runId: string): IndeRunException {
    const extra = { providerId: this.id, runId };

    if (error instanceof NeuralSpeechRuntimeError) {
      const details =
        error.originalError !== undefined
          ? { details: { originalError: getErrorSummary(error.originalError) } }
          : {};

      switch (error.kind) {
        case "capability":
          return createCapabilityMismatch(error.message, { ...extra, ...details });
        case "unavailable":
          return createUnavailable(error.message, { ...extra, ...details });
        case "timeout":
          return createTimeout(error.message, { ...extra, ...details });
        default:
          return createInternal(error.message, { ...extra, ...details });
      }
    }

    return toIndeRunException(error, extra);
  }
}

interface SynthesisRequest {
  /** Created by the caller at the start of synthesis; the caller ends it. */
  budget: Budget;
  context: RunContext;
  voiceId: string;
  locale: string;
  /** True for playback, which commits on the first chunk; false for an artifact. */
  budgetEndsAtFirstChunk: boolean;
  signal?: AbortSignal;
}

function toListedVoice(voice: PackageVoice) {
  return {
    id: voice.id,
    name: voice.name,
    locale: voice.locales[0],
    locales: [...voice.locales],
    ...(voice.gender !== undefined ? { gender: voice.gender } : {}),
    networkRequired: false
  };
}

function sameLanguage(a: string, b: string): boolean {
  return a.toLowerCase().split(/[-_]/)[0] === b.toLowerCase().split(/[-_]/)[0];
}

/** The voice's tag for the requested locale: exact first, then by language, else the request's. */
function localeFor(voice: PackageVoice, requested: string): string {
  return (
    voice.locales.find((tag: string) => tag.toLowerCase() === requested.toLowerCase()) ??
    voice.locales.find((tag: string) => sameLanguage(tag, requested)) ??
    requested
  );
}

const EXPIRED: unique symbol = Symbol("expired");

type Budget = ReturnType<typeof createBudget>;

/**
 * One absolute deadline `timeoutMs` from its creation; `undefined` is unbounded. `race` settles
 * with the step, or with `EXPIRED` once the deadline has passed, without waiting for the step.
 * `passed` reads the deadline against the clock, for work that is not a pull. `end` lifts it.
 */
function createBudget(timeoutMs: number | undefined) {
  let deadline = timeoutMs === undefined ? undefined : Date.now() + timeoutMs;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let expired =
    timeoutMs === undefined
      ? undefined
      : new Promise<typeof EXPIRED>((resolve) => {
          timer = setTimeout(() => resolve(EXPIRED), timeoutMs);
        });
  return {
    race<T>(step: Promise<T>): Promise<T | typeof EXPIRED> {
      return expired === undefined ? step : Promise.race([step, expired]);
    },
    passed(): boolean {
      return deadline !== undefined && Date.now() >= deadline;
    },
    end() {
      clearTimeout(timer);
      expired = undefined;
      deadline = undefined;
    }
  };
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** Read through a call, so a check after an `await` is not narrowed away by an earlier one. */
function cancelled(signal: AbortSignal | undefined): boolean {
  return signal?.aborted === true;
}

async function untilTurnOrAbort(turn: Promise<void>, signal?: AbortSignal): Promise<boolean> {
  if (signal === undefined) {
    await turn;
    return false;
  }
  if (signal.aborted) return true;
  return new Promise((resolve) => {
    const onAbort = () => resolve(true);
    signal.addEventListener("abort", onAbort, { once: true });
    void turn.then(() => {
      signal.removeEventListener("abort", onAbort);
      resolve(false);
    });
  });
}

function getErrorSummary(error: unknown): Record<string, unknown> {
  if (error instanceof Error) {
    return { name: error.name, message: error.message, stack: error.stack };
  }
  return { message: String(error) };
}
