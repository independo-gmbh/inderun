import type {
  ExecutionProvenance,
  MediaArtifact,
  PlaybackTiming,
  ProviderReadiness,
  ProviderCapabilitySnapshot,
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
/** Relative speaking rate and pitch (ADR 025). */
export type SpeechControls = NonNullable<SpeechInput["controls"]>;
/** Playback-only settings of one utterance (ADR 025). */
export type SpeechPlaybackControls = NonNullable<Delivery["playback"]>;

/** The same policy object as the text API, so a constraint means the same in both. */
export type SpeechExecutionOptions = TextExecutionOptions;

/**
 * What every speech call takes: the text, its locale, the voice, the synthesis controls and the
 * execution policy. {@link SpeakOptions} adds playback-only settings; {@link GenerateSpeechOptions}
 * adds the artifact's. Swift and Kotlin have the same three types.
 */
export interface SpeechOptions {
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
   * Relative speaking rate and pitch. Each is preferred unless marked `"required"`; a required
   * one is met or the call is refused. `output.speech.controls` reports what was applied.
   */
  controls?: SpeechControls;
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
export interface SpeakOptions extends SpeechOptions {
  /** Playback volume of this utterance, 0 to 1. Never the device volume. */
  playback?: SpeechPlaybackControls;
}

/** Options for {@link generateSpeech}. */
export interface GenerateSpeechOptions extends SpeechOptions {
  /** Acceptable media types; always a hard requirement. Absent lets the provider choose. */
  mediaTypes?: string[];
  /** Opaque application destination, resolved by the host. Never a path or URL. */
  destinationRef?: string;
  /**
   * Never valid: an artifact is not played, so it has no playback volume. Typed `never` so a
   * {@link SpeakOptions} value with `playback` does not type-check here; a JavaScript caller that
   * passes one anyway gets the request's validation error, never a silently dropped control.
   */
  playback?: never;
}

/** How a {@link speak} run ended, when it did not fail. */
export interface SpokenSpeech {
  /** `"cancelled"` when playback was stopped; otherwise as the provider reported it. */
  finishReason?: TaskResult["finishReason"];
  /** What the provider measured, see `PlaybackTiming`. */
  timing?: PlaybackTiming;
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

type SnapshotTask = NonNullable<
  ProviderCapabilitySnapshot["descriptor"]["taskCapabilities"]
>[number];
type SpeechControlDeclaration = NonNullable<SnapshotTask["controls"]>[number];
type SpeechControlId = SpeechControlDeclaration["id"];
type SpeechControlPhase = SpeechControlDeclaration["phase"];
type ControlDelivery = SpeechControlDeclaration["deliveries"][number];
type SpeechControlRange = NonNullable<
  NonNullable<
    NonNullable<
      ProviderCapabilitySnapshot["capabilities"]["taskCapabilities"]
    >[number]["controlStates"]
  >[number]["range"]
>;

/** Options for {@link listVoices}. */
export interface ListVoicesOptions {
  /** Keep only voices that can serve this BCP 47 tag. */
  locale?: string;
  /** How `locale` compares, with the same meaning as on a request. Defaults to `"language"`. */
  localeMatch?: SpeechInput["localeMatch"];
  /**
   * Add each voice's per-request controls ({@link SpeechVoiceInfo.controls}), read from the same
   * capability snapshot. Defaults to `false`.
   */
  includeControls?: boolean;
  /**
   * Also list the voices of providers and tasks that are unavailable, with what is known of them
   * and `available: false`. Defaults to `false`. Nothing is prepared, downloaded, loaded or
   * synthesized to find them.
   */
  includeUnavailable?: boolean;
}

/**
 * One speech control as a voice offers it on one delivery: the merged state of the task's and the
 * voice's `controlStates`, reported as declared and never decided. A field the provider has not
 * reported stays absent, and absent is not support.
 */
export interface SpeechVoiceControl {
  id: SpeechControlId;
  delivery: ControlDelivery;
  phase: SpeechControlPhase;
  /** Whether the control works here. Absent when unknown. */
  available?: boolean;
  /** Why the control does not work, when `available` is `false`. */
  reason?: string;
  /** The values it accepts. Absent when unknown, or when the control is unavailable. */
  range?: SpeechControlRange;
}

/**
 * A voice a registered provider offers right now. Pass the entry as `voice` to speak with it.
 * `id` is opaque and meaningful only on `providerId` on this device: read it, store it, but never
 * write one by hand.
 */
export interface SpeechVoiceInfo {
  providerId: string;
  /**
   * `"model"` when the provider names the model that speaks, so the voice belongs to that model;
   * `"platform"` when it names none (a system voice, or any provider without a model id).
   */
  kind: "platform" | "model";
  /** The model that speaks this voice. Present exactly when `kind` is `"model"`. */
  model?: string;
  /** Absent when the provider cannot address single voices. */
  id?: string;
  /** Label for showing the voice to a person. Not unique, so never compare it. */
  name?: string;
  /** The voice's primary BCP 47 tag. */
  locale: string;
  /** Every BCP 47 tag the voice speaks. Absent when it speaks only `locale`. */
  locales?: string[];
  gender?: SpeechVoice["gender"];
  /** `true` when the voice sends text off the device. Absent inherits the provider's posture. */
  networkRequired?: boolean;
  /** `"not_prepared"` and `"preparing"` mean "not yet". Absent means ready. See `prepare()`. */
  readiness?: ProviderReadiness;
  /**
   * The per-request controls of this voice, one per declared control and delivery. Present only
   * with `includeControls`.
   */
  controls?: SpeechVoiceControl[];
  /** `false` for a voice of an unavailable provider or task. Present only with `includeUnavailable`. */
  available?: boolean;
}

/** The canonical `TaskRequest` a speech call compiles to. */
export function toSpeechRequest(
  options: SpeechOptions,
  delivery: Delivery["mode"] | Delivery
): TaskRequest {
  const speech: SpeechInput = { text: options.text, locale: options.locale };
  if (options.localeMatch !== undefined) speech.localeMatch = options.localeMatch;
  if (options.voice !== undefined) speech.voice = toRequestVoice(options.voice);
  if (options.controls !== undefined) speech.controls = options.controls;

  const request: TaskRequest = {
    schemaVersion: "1.1",
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
function toRequestVoice(voice: NonNullable<SpeechOptions["voice"]>): SpeechVoice {
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
  const delivery: Delivery = { mode: "playback" };
  if (options.playback !== undefined) delivery.playback = options.playback;
  const run = await inderun.stream(toSpeechRequest(options, delivery));
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
  // Forwarded, not dropped: the canonical request then fails validation the same way on every
  // SDK (delivery.playback is only valid with playback delivery, ADR 025).
  const playback = (options as { playback?: unknown }).playback;
  if (playback !== undefined) delivery.playback = playback as NonNullable<Delivery["playback"]>;

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
 * A provider that is unavailable contributes none (unless `includeUnavailable`); one that cannot
 * enumerate its voices contributes none either, and can still serve a request. A projection of
 * `checkCapabilities()` and nothing more: it never prepares, downloads, loads or synthesizes.
 */
export async function listVoices(
  inderun: IndeRunApi,
  options: ListVoicesOptions = {}
): Promise<SpeechVoiceInfo[]> {
  const voices: SpeechVoiceInfo[] = [];
  for (const { providerId, descriptor, capabilities } of await inderun.checkCapabilities()) {
    const task = capabilities.taskCapabilities?.find((entry) => entry.kind === "text_to_speech");
    if (task === undefined) continue;
    const unavailable = !capabilities.available || task.available === false;
    if (unavailable && options.includeUnavailable !== true) continue;
    const declarations = descriptor?.taskCapabilities?.find(
      (entry) => entry.kind === "text_to_speech"
    )?.controls;
    for (const voice of task.voices ?? []) {
      if (options.locale !== undefined && !localeMatches(voice, options)) continue;
      const model = descriptor?.model;
      voices.push({
        providerId,
        kind: model !== undefined ? "model" : "platform",
        ...(model !== undefined ? { model } : {}),
        ...(voice.id !== undefined ? { id: voice.id } : {}),
        ...(voice.name !== undefined ? { name: voice.name } : {}),
        locale: voice.locale,
        ...(voice.locales !== undefined ? { locales: voice.locales } : {}),
        ...(voice.gender !== undefined ? { gender: voice.gender } : {}),
        ...(voice.networkRequired !== undefined ? { networkRequired: voice.networkRequired } : {}),
        ...(voice.readiness !== undefined ? { readiness: voice.readiness } : {}),
        ...(options.includeControls === true
          ? { controls: voiceControls(declarations, task.controlStates, voice, unavailable) }
          : {}),
        ...(unavailable ? { available: false } : {})
      });
    }
  }
  return voices;
}

type ControlStates = NonNullable<ProviderVoice["controlStates"]>;

/**
 * The listed controls of one voice: each `lifetime: utterance` declaration times each delivery it
 * lists, in declaration order. The merge is the route planner's: the voice's state for
 * `(id, delivery)` overlays the task's, field by field, and a state for an undeclared delivery is
 * never read. An id declared twice, a declaration that breaks its id's invariant
 * ({@link keepsInvariant}), or two states for one `(id, delivery)` at one level, are
 * contradictory and read `available: false`. Unknown stays absent.
 */
function voiceControls(
  declarations: SpeechControlDeclaration[] | undefined,
  taskStates: ControlStates | undefined,
  voice: ProviderVoice,
  unavailable: boolean
): SpeechVoiceControl[] {
  const controls: SpeechVoiceControl[] = [];
  const listed = new Set<SpeechControlId>();
  for (const declaration of declarations ?? []) {
    if (declaration.lifetime !== "utterance" || listed.has(declaration.id)) continue;
    listed.add(declaration.id);
    const contradictory =
      declarations!.filter((entry) => entry.id === declaration.id).length > 1 ||
      !keepsInvariant(declaration);
    for (const delivery of declaration.deliveries) {
      const control = { id: declaration.id, delivery, phase: declaration.phase };
      if (unavailable) {
        controls.push({ ...control, available: false });
        continue;
      }
      const taskMatches = statesFor(taskStates, declaration.id, delivery);
      const voiceMatches = statesFor(voice.controlStates, declaration.id, delivery);
      if (contradictory || taskMatches.length > 1 || voiceMatches.length > 1) {
        controls.push({ ...control, available: false, reason: "contradictory declaration" });
        continue;
      }
      const [task] = taskMatches;
      const [bound] = voiceMatches;
      const available = bound?.available ?? task?.available;
      const reason = bound?.reason ?? task?.reason;
      const range = bound?.range ?? task?.range;
      controls.push({
        ...control,
        ...(available !== undefined ? { available } : {}),
        ...(reason !== undefined ? { reason } : {}),
        ...(range !== undefined ? { range } : {})
      });
    }
  }
  return controls;
}

/**
 * The route planner's declaration invariant (`declaration_keeps_invariant` in the route core), the
 * schema's `allOf` on a control declaration: rate and pitch are `number` controls of the
 * `synthesis` phase, volume a `number` control of the `playback` phase, and a `playback`-phase
 * control lists only the `playback` delivery. A typed declaration can break it without the schema.
 */
function keepsInvariant(declaration: SpeechControlDeclaration): boolean {
  return (
    declaration.valueKind === "number" &&
    declaration.phase === requiredPhase(declaration.id) &&
    (declaration.phase !== "playback" ||
      declaration.deliveries.every((delivery) => delivery === "playback"))
  );
}

/**
 * The phase a shared control id requires. Exhaustive, so a new id must choose one; an id outside
 * the enum (an untyped caller) requires no phase it can meet, so its declaration is contradictory.
 */
function requiredPhase(id: SpeechControlId): SpeechControlPhase | undefined {
  switch (id) {
    case "speech.speakingRate":
    case "speech.pitch":
      return "synthesis";
    case "playback.volume":
      return "playback";
    default: {
      const unknown: never = id;
      void unknown;
      return undefined;
    }
  }
}

function statesFor(
  states: ControlStates | undefined,
  id: SpeechControlId,
  delivery: ControlDelivery
): ControlStates {
  return (states ?? []).filter((state) => state.id === id && state.delivery === delivery);
}

type ProviderVoice = NonNullable<
  NonNullable<ProviderCapabilitySnapshot["capabilities"]["taskCapabilities"]>[number]["voices"]
>[number];

/**
 * Case-insensitive BCP 47 comparison, the same one the route planner applies, against the voice's
 * `locale` and every entry of its `locales`.
 */
function localeMatches(voice: ProviderVoice, options: ListVoicesOptions): boolean {
  const want = options.locale!.toLowerCase();
  return [voice.locale, ...(voice.locales ?? [])].some((available) => {
    const have = available.toLowerCase();
    if (options.localeMatch === "exact") return have === want;
    return have.split(/[-_]/)[0] === want.split(/[-_]/)[0];
  });
}

function settle(outcome: StreamTerminalOutcome): SpokenSpeech {
  const base = {
    runId: outcome.runId,
    ...(outcome.provenance !== undefined ? { provenance: outcome.provenance } : {}),
    outcome
  };
  const { output } = outcome;
  const reported = {
    ...(output?.playback?.timing !== undefined ? { timing: output.playback.timing } : {}),
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
