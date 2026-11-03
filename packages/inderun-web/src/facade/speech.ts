import type {
  ExecutionProvenance,
  MediaArtifact,
  ProviderReadiness,
  StreamTerminalOutcome,
  TaskOutput,
  TaskRequest,
  TaskResult
} from "@independo/inderun-contracts";
import { IndeRunException } from "../core/errors.js";
import type { IndeRunApi } from "../core/generated/inderun-api.js";
import { AUTO_MODEL_PROFILE } from "../core/model-profiles.js";
import { applyEnvelopeOptions, exceptionFromOutcome, type TextExecutionOptions } from "./text.js";

/**
 * The primary speech API: `speak()`, `generateSpeech()` and `listVoices()`.
 *
 * Translation only, like the text API. Each speaking call compiles to exactly one canonical
 * `text_to_speech` `TaskRequest` ({@link toSpeechRequest}); `listVoices()` reads
 * `checkCapabilities()`. `speak()` is written over `stream()` because a stream is the only
 * execution a caller can cancel, and stopping audio is the point of a playback handle.
 * See ADR 018 and `docs/architecture/api-layering.md`.
 */

type SpeechInput = NonNullable<TaskRequest["speech"]>;
type SpeechVoice = NonNullable<SpeechInput["voice"]>;
type Delivery = NonNullable<TaskRequest["delivery"]>;

/** The same policy object as the text API, so a constraint means the same in both. */
export type SpeechExecutionOptions = TextExecutionOptions;

interface SpeechCommonOptions {
  /** The text to speak. Plain text; markup such as SSML is out of scope. */
  text: string;
  /** BCP 47 tag, e.g. `"de-AT"`. */
  locale: string;
  /**
   * `"language"` (default) requires the language and prefers the region, so `de-AT` may be
   * served by `de-DE`. `"exact"` requires the whole tag.
   */
  localeMatch?: SpeechInput["localeMatch"];
  /**
   * The voice: an entry from {@link listVoices}, or provider-neutral traits. A voice left
   * `"preferred"` falls back to its traits when it is gone or another provider serves the run;
   * a `"required"` one never relaxes silently.
   */
  voice?: SpeechVoice | (SpeechVoiceInfo & Pick<SpeechVoice, "requirement">);
  /**
   * Model profile to route within, as configured on the engine. Omitted or `"auto"` routes
   * across every registered target. Never a vendor model or voice id.
   */
  model?: string;
  execution?: SpeechExecutionOptions;
  /** Secure-storage slot for provider credentials. Never a raw secret. */
  authContextRef?: string;
  telemetry?: TaskRequest["telemetry"];
  /** Fixes the run id, for correlation. */
  requestId?: string;
}

/** Options for {@link speak}. */
export type SpeakOptions = SpeechCommonOptions;

/** Options for {@link generateSpeech}. */
export interface GenerateSpeechOptions extends SpeechCommonOptions {
  /** Acceptable media types; always a hard requirement. Absent lets the provider choose. */
  mediaTypes?: string[];
  /** Opaque application destination, resolved by the host. Never a path or URL. */
  destinationRef?: string;
}

/** How a {@link speak} run ended, when it did not fail. */
export interface SpokenSpeech {
  /** `"cancelled"` when playback was stopped; otherwise as the provider reported it. */
  finishReason?: TaskResult["finishReason"];
  /** How long the audio played, where the provider knows it. */
  durationMs?: number;
  /**
   * From the provider handing the text to the platform to the platform's first audible-output
   * callback, where the platform reports one. See `PlaybackOutput.firstAudioMs`.
   */
  firstAudioMs?: number;
  /** The locale and voice actually used, so an unmet preference is visible. */
  speech?: TaskOutput["speech"];
  runId: string;
  provenance?: ExecutionProvenance;
  /** The canonical terminal outcome. */
  outcome: StreamTerminalOutcome;
}

/** What {@link speak} returns: a handle on playback in progress. */
export interface SpeechPlayback {
  runId: string;
  /**
   * Settles with the run's ending: resolves when playback finishes or is stopped, rejects with
   * the run's `IndeRunException` on failure.
   */
  result: Promise<SpokenSpeech>;
  /** Stops playback; idempotent. */
  cancel(reason?: string): void;
}

/** What {@link generateSpeech} returns. */
export interface GeneratedSpeech {
  /** A reference to the audio. Read it with `readArtifact()`, release it with `disposeArtifact()`. */
  artifact: MediaArtifact;
  /** The locale and voice actually used, so an unmet preference is visible. */
  speech?: TaskOutput["speech"];
  finishReason: TaskResult["finishReason"];
  runId: string;
  provenance?: ExecutionProvenance;
  /** The canonical result, for anything the summary above leaves out. */
  taskResult: TaskResult;
}

/** Options for {@link listVoices}. */
export interface ListVoicesOptions {
  /** Keep only voices that can serve this BCP 47 tag. */
  locale?: string;
  /** How `locale` compares, with the same meaning as on a request. Defaults to `"language"`. */
  localeMatch?: SpeechInput["localeMatch"];
}

/**
 * A voice a registered provider offers right now. Pass the entry as `voice` to speak with it.
 * `id` is opaque and meaningful only on `providerId` on this device: read it, store it, but never
 * write one by hand.
 */
export interface SpeechVoiceInfo {
  providerId: string;
  /** Absent when the provider cannot address single voices. */
  id?: string;
  /** Label for showing the voice to a person. Not unique, so never compare it. */
  name?: string;
  locale: string;
  gender?: SpeechVoice["gender"];
  /** `true` when the voice sends text off the device. Absent inherits the provider's posture. */
  networkRequired?: boolean;
  /** `"not_prepared"` and `"preparing"` mean "not yet". Absent means ready. See `prepare()`. */
  readiness?: ProviderReadiness;
}

/** The canonical `TaskRequest` a speech call compiles to. */
export function toSpeechRequest(
  options: SpeechCommonOptions,
  delivery: Delivery["mode"] | Delivery
): TaskRequest {
  const speech: SpeechInput = { text: options.text, locale: options.locale };
  if (options.localeMatch !== undefined) speech.localeMatch = options.localeMatch;
  if (options.voice !== undefined) speech.voice = toRequestVoice(options.voice);

  const request: TaskRequest = {
    schemaVersion: "1.0",
    task: { kind: "text_to_speech" },
    speech,
    delivery: typeof delivery === "string" ? { mode: delivery } : delivery
  };
  if (options.model !== undefined && options.model !== AUTO_MODEL_PROFILE) {
    request.modelProfile = options.model;
  }
  applyEnvelopeOptions(request, options);
  return request;
}

/** Keeps what a request can carry, so a {@link SpeechVoiceInfo} can be passed as it is. */
function toRequestVoice(voice: NonNullable<SpeechCommonOptions["voice"]>): SpeechVoice {
  const { id, providerId, gender, requirement } = voice;
  return {
    ...(id !== undefined ? { id } : {}),
    ...(providerId !== undefined ? { providerId } : {}),
    ...(gender !== undefined ? { gender } : {}),
    ...(requirement !== undefined ? { requirement } : {})
  };
}

/**
 * Speaks through the device: `stream()` over a `playback` request. The audible effect is
 * managed by the provider; the application gets a completion and a way to stop it, never bytes.
 * @throws {IndeRunException} Exactly as `stream()` does: validation and routing refusals reject
 *   here, before any audio could start.
 */
export async function speak(inderun: IndeRunApi, options: SpeakOptions): Promise<SpeechPlayback> {
  const run = await inderun.stream(toSpeechRequest(options, "playback"));
  const runId = run.handle.runId;

  const result = (async (): Promise<SpokenSpeech> => {
    // As in streamText: the terminal event settles the run, and a source that stays open after
    // it must not hold the result back.
    const events = run.events[Symbol.asyncIterator]();
    for (let next = await events.next(); next.done !== true; next = await events.next()) {
      if (next.value.type === "terminal") {
        void events.return?.()?.catch(() => undefined);
        return settle(next.value.payload as unknown as StreamTerminalOutcome);
      }
    }
    throw new IndeRunException({
      errorClass: "Internal",
      message: `Run ${runId} ended without a terminal event.`,
      runId
    });
  })();
  // A caller that only ever cancels must not leave an unhandled rejection behind.
  result.catch(() => undefined);

  return { runId, result, cancel: (reason?: string) => run.cancel(reason) };
}

/**
 * Synthesizes retrievable audio: `run()` over an `artifact` request. Silent, and not cancellable
 * for the same reason `run()` is not. A provider that can only play audio is refused by routing.
 * @throws {IndeRunException} Exactly as `run()` does.
 */
export async function generateSpeech(
  inderun: IndeRunApi,
  options: GenerateSpeechOptions
): Promise<GeneratedSpeech> {
  const delivery: Delivery = { mode: "artifact" };
  // An empty list is the engine's to reject, with the same validation error as run().
  if (options.mediaTypes !== undefined) {
    delivery.mediaTypes = options.mediaTypes as NonNullable<Delivery["mediaTypes"]>;
  }
  if (options.destinationRef !== undefined) delivery.destinationRef = options.destinationRef;

  const taskResult = await inderun.run(toSpeechRequest(options, delivery));
  const { output } = taskResult;
  return {
    // The engine checks the output against the requested delivery before it returns.
    artifact: output.artifact!,
    ...(output.speech !== undefined ? { speech: output.speech } : {}),
    finishReason: taskResult.finishReason,
    runId: taskResult.runId,
    ...(taskResult.provenance !== undefined ? { provenance: taskResult.provenance } : {}),
    taskResult
  };
}

/**
 * Lists the voices the registered providers offer right now, in registration and provider order.
 * A provider that is unavailable contributes none; one that cannot enumerate its voices
 * contributes none either, and can still serve a request.
 */
export async function listVoices(
  inderun: IndeRunApi,
  options: ListVoicesOptions = {}
): Promise<SpeechVoiceInfo[]> {
  const voices: SpeechVoiceInfo[] = [];
  for (const { providerId, capabilities } of await inderun.checkCapabilities()) {
    if (!capabilities.available) continue;
    const task = capabilities.taskCapabilities?.find((entry) => entry.kind === "text_to_speech");
    if (task === undefined || task.available === false) continue;
    for (const voice of task.voices ?? []) {
      if (options.locale !== undefined && !localeMatches(voice.locale, options)) continue;
      voices.push({
        providerId,
        ...(voice.id !== undefined ? { id: voice.id } : {}),
        ...(voice.name !== undefined ? { name: voice.name } : {}),
        locale: voice.locale,
        ...(voice.gender !== undefined ? { gender: voice.gender } : {}),
        ...(voice.networkRequired !== undefined ? { networkRequired: voice.networkRequired } : {}),
        ...(voice.readiness !== undefined ? { readiness: voice.readiness } : {})
      });
    }
  }
  return voices;
}

/** Case-insensitive BCP 47 comparison, the same one the route planner applies. */
function localeMatches(available: string, options: ListVoicesOptions): boolean {
  const have = available.toLowerCase();
  const want = options.locale!.toLowerCase();
  if (options.localeMatch === "exact") return have === want;
  return have.split(/[-_]/)[0] === want.split(/[-_]/)[0];
}

function settle(outcome: StreamTerminalOutcome): SpokenSpeech {
  const base = {
    runId: outcome.runId,
    ...(outcome.provenance !== undefined ? { provenance: outcome.provenance } : {}),
    outcome
  };
  const { output } = outcome;
  const reported = {
    ...(output?.playback?.durationMs !== undefined
      ? { durationMs: output.playback.durationMs }
      : {}),
    ...(output?.playback?.firstAudioMs !== undefined
      ? { firstAudioMs: output.playback.firstAudioMs }
      : {}),
    ...(output?.speech !== undefined ? { speech: output.speech } : {})
  };
  switch (outcome.outcome) {
    case "completed":
      return {
        ...(outcome.finishReason !== undefined ? { finishReason: outcome.finishReason } : {}),
        ...reported,
        ...base
      };
    case "cancelled":
      return { finishReason: "cancelled", ...reported, ...base };
    case "error":
      throw exceptionFromOutcome(outcome);
  }
}
