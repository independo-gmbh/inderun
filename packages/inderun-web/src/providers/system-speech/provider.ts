import type {
  PlaybackTiming,
  TaskOutput,
  TaskRequest,
  TaskResult
} from "@independo/inderun-contracts";
import { createCapabilityMismatch, createInternal, createUnavailable } from "../../core/errors.js";
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
import { createBrowserSpeechRuntime } from "./browser-runtime.js";
import {
  SystemSpeechRuntimeError,
  type SystemSpeechRuntime,
  type SystemSpeechVoice
} from "./runtime.js";

export const DEFAULT_SYSTEM_SPEECH_WEB_PROVIDER_ID = "web_system_speech";

const TASK = "text_to_speech";

type ListedVoice = NonNullable<RunContext["voice"]>;

/** Options for {@link SystemSpeechWebProvider}. */
export interface SystemSpeechProviderOptions {
  /** Defaults to {@link DEFAULT_SYSTEM_SPEECH_WEB_PROVIDER_ID}. */
  id?: string;
  /** Defaults to {@link createBrowserSpeechRuntime}. */
  runtime?: SystemSpeechRuntime;
}

/**
 * Browser text-to-speech over `speechSynthesis`: managed playback only. The browser offers no
 * standard way to retrieve the audio, so this provider never declares `artifact` delivery and
 * routing refuses `generateSpeech()` here.
 *
 * Playback commits immediately before `speak()`, so a failure after that ends the run rather than
 * speaking the text twice. `speak()` uses `stream`, whose abort signal stops the audio; `run` has
 * no cancellation channel.
 *
 * Utterances play one at a time per provider instance, first in first out, and an utterance
 * commits only at its turn, once other speech on the page has ended, so one cancelled while
 * waiting never plays and stops nothing else. The bound voice is checked at that same point.
 *
 * `SpeechSynthesisVoice.localService` is unreliable and absent in places, and a browser may send
 * text to a remote service regardless. So the task declares that data may leave the device,
 * `local_required` is always refused, and provenance reports `unknown` locality. `localService`
 * only orders the voices and removes known network voices while offline.
 */
export class SystemSpeechWebProvider implements PreparableProviderAdapter {
  private readonly id: string;
  private readonly runtime: SystemSpeechRuntime;
  private tail: Promise<void> = Promise.resolve();
  /** Set once a preparation found no voices, so "not yet" does not stay the answer forever. */
  private voicesNeverListed = false;

  constructor(options: SystemSpeechProviderOptions = {}) {
    this.id = options.id ?? DEFAULT_SYSTEM_SPEECH_WEB_PROVIDER_ID;
    this.runtime = options.runtime ?? createBrowserSpeechRuntime();
  }

  describe(): ProviderDescriptor {
    return {
      id: this.id,
      type: "local",
      transport: "system_service",
      supports: {
        run: true,
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
          interaction: { run: true, stream: true, prepare: true },
          cancel: "hard",
          outputs: [{ delivery: "playback" }],
          privacy: { dataLeavesDevice: true }
        }
      ]
    };
  }

  async capabilities(host: HostServices): Promise<ProviderDynamicCapabilities> {
    const availability = this.runtime.availability();
    if (availability.kind !== "available") {
      return { available: false, reason: availability.reason };
    }
    const online = await host.connectivity.isOnline();
    const voices = (await this.runtime.voices()).filter(
      (voice) => online || voice.localService !== false
    );
    if (voices.length === 0) {
      const loading = online && !this.voicesNeverListed;
      return {
        available: false,
        reason: !online
          ? "The browser offers only network speech voices, and the device is offline."
          : loading
            ? "The browser has not listed its speech voices yet."
            : "The browser offers no speech voices.",
        // Browsers fill the list late, and an empty one cannot say whether it ever will be.
        ...(loading ? { taskCapabilities: [{ kind: TASK, readiness: "preparing" as const }] } : {})
      };
    }
    return {
      available: true,
      taskCapabilities: [{ kind: TASK, voices: voices.map(toListedVoice) }]
    };
  }

  /** Waits for the browser to list its voices. Nothing is loaded here: the browser decides that. */
  async *prepare(context: ProviderPrepareContext): AsyncIterable<{ fractionCompleted?: number }> {
    yield {};
    if (await this.runtime.whenVoicesListed(context.signal)) return;
    if (context.signal.aborted) return;
    this.voicesNeverListed = true;
    throw createUnavailable("The browser listed no speech voices in time.", {
      runId: context.runId,
      providerId: this.id,
      details: { code: "voices_not_listed" }
    });
  }

  async run(request: TaskRequest, context: RunContext): Promise<TaskResult> {
    const output = await this.play(request, context);
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
    const output = await this.play(request, context, context.signal);
    if (output !== undefined) yield { kind: "result", output, finishReason: "stop" };
  }

  /** @returns The output, or `undefined` when nothing played or playback was stopped. */
  private async play(
    request: TaskRequest,
    context: RunContext,
    signal?: AbortSignal
  ): Promise<TaskOutput | undefined> {
    // The origin of `firstAudioMs`: before the turn wait, voice lookup and commit.
    const receivedAt = Date.now();
    const { speech, delivery } = request;
    if (speech === undefined || delivery?.mode !== "playback") {
      throw createCapabilityMismatch("Browser speech can only play text-to-speech requests.", {
        runId: context.runId,
        providerId: this.id
      });
    }

    return this.inTurn(signal, async () => {
      await this.runtime.whenIdle(signal);
      const voice = await this.resolveVoice(context);
      // Committed only now: a call that waited its turn has made no sound, and may have been
      // cancelled meanwhile.
      if (signal?.aborted === true || !context.commit()) return undefined;
      const locale = voice?.locale ?? speech.locale;
      try {
        const handoffAt = Date.now();
        const ending = await this.runtime.speak(
          { text: speech.text, locale, ...(voice !== undefined ? { voice } : {}) },
          signal
        );
        if (ending.stopped === true) return undefined;
        // The runtime counts from the handoff; add what this provider spent before it.
        const timing: PlaybackTiming = {
          ...(ending.durationMs !== undefined ? { durationMs: ending.durationMs } : {}),
          ...(ending.firstAudioMs !== undefined
            ? { firstAudioMs: ending.firstAudioMs + (handoffAt - receivedAt) }
            : {})
        };
        return {
          type: "playback",
          playback: Object.keys(timing).length > 0 ? { timing } : {},
          speech: { locale, ...(voice !== undefined ? { voice: toUsedVoice(voice) } : {}) }
        };
      } catch (error) {
        throw this.normalized(error, context.runId);
      }
    });
  }

  /**
   * Re-finds the voice the plan bound, at the turn that will use it. A voice removed since
   * planning is refused before commit, so the run can still fall back.
   */
  private async resolveVoice(context: RunContext): Promise<SystemSpeechVoice | undefined> {
    const bound = context.voice;
    if (bound === undefined) return undefined;
    const voices = await this.runtime.voices();
    const match = voices.find((voice) => voice.uri === bound.id);
    if (match === undefined) {
      throw createCapabilityMismatch(`No browser voice can speak locale '${bound.locale}'.`, {
        runId: context.runId,
        providerId: this.id,
        details: { code: "voice_not_available" }
      });
    }
    return match;
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

  private normalized(error: unknown, runId: string) {
    if (error instanceof SystemSpeechRuntimeError) {
      return createUnavailable(error.message, {
        runId,
        providerId: this.id,
        details: {
          code: error.kind === "not_allowed" ? "speech_not_allowed" : "speech_synthesis_failed"
        }
      });
    }
    return createInternal("Browser speech failed.", { runId, providerId: this.id });
  }
}

function toListedVoice(voice: SystemSpeechVoice): ListedVoice {
  // Only `false` carries information: `true` is not evidence enough to claim on-device, so the
  // voice inherits the task's posture.
  return {
    id: voice.uri,
    ...(voice.name !== undefined ? { name: voice.name } : {}),
    locale: voice.locale,
    ...(voice.localService === false ? { networkRequired: true } : {})
  };
}

function toUsedVoice(voice: SystemSpeechVoice) {
  return { id: voice.uri, ...(voice.name !== undefined ? { name: voice.name } : {}) };
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
