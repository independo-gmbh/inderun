import type {
  SharedRoutePlan,
  SharedRoutePlannerInput,
  TaskOutput,
  TaskRequest
} from "@independo/inderun-contracts";
import { createCapabilityMismatch, createInternal, IndeRunException } from "./errors.js";

/** How a task's result reaches the application: `inline`, `playback` or `artifact`. */
export type OutputDelivery = NonNullable<TaskRequest["delivery"]>["mode"];
/** The provider-neutral voice a route candidate is bound to. */
export type BoundVoice = NonNullable<SharedRoutePlan["candidates"][number]["voice"]>;

/**
 * What the engine needs to know about one task kind (ADR 016). This table is the only
 * place the engine branches on `task.kind`: which kinds it executes, the projection onto
 * the planner's task requirements, and the output delivery a result must have. (Per-kind
 * request requirements are the schema's `if`/`then` branches, checked by the validator.) Everything else — routing, fallback, cancellation, provenance — is task-agnostic,
 * so a new task adds an entry here rather than a second execution path.
 *
 * The Swift (`TaskProfiles.swift`) and Kotlin (`TaskProfiles.kt`) engines keep the same
 * table; `contracts/fixtures/task-contracts/` holds the planner projection all three must
 * produce for each request.
 */
export interface TaskProfile {
  /** The `task.kind` this profile describes. */
  readonly kind: string;
  /** Projects the request onto the requirements the shared planner can check. */
  plannerTask(request: TaskRequest): SharedRoutePlannerInput["task"];
  /** The output delivery the request asks for: `inline` for text, else `delivery.mode`. */
  delivery(request: TaskRequest): OutputDelivery;
}

const textToText: TaskProfile = {
  kind: "text_to_text",
  plannerTask: () => ({ kind: "text_to_text", inputs: ["text"] }),
  delivery: () => "inline"
};

const textToSpeech: TaskProfile = {
  kind: "text_to_speech",
  plannerTask: (request) => {
    // The schema requires both for this kind; validation runs before projection.
    const speech = request.speech!;
    const delivery = request.delivery!;
    return {
      kind: "text_to_speech",
      inputs: ["text"],
      delivery: {
        mode: delivery.mode,
        ...(delivery.mediaTypes !== undefined ? { mediaTypes: [...delivery.mediaTypes] } : {})
      },
      locale: { tag: speech.locale, match: speech.localeMatch ?? "language" },
      ...(speech.voice !== undefined
        ? {
            voice: {
              ...(speech.voice.id !== undefined ? { id: speech.voice.id } : {}),
              ...(speech.voice.providerId !== undefined
                ? { providerId: speech.voice.providerId }
                : {}),
              ...(speech.voice.gender !== undefined ? { gender: speech.voice.gender } : {}),
              requirement: speech.voice.requirement ?? "preferred"
            }
          }
        : {}),
      ...controlRequirements(request)
    };
  },
  delivery: (request) => request.delivery!.mode
};

/** One requested speech control as the planner sees it: id, value and requirement. */
export type ControlRequirement = NonNullable<SharedRoutePlannerInput["task"]["controls"]>[number];
/** One entry of a candidate's control application plan (ADR 025 §3). */
export type ControlApplicationPlan = NonNullable<
  SharedRoutePlan["candidates"][number]["controls"]
>[number];
/** The speech section of a task output: locale, voice and control records. */
export type SpeechOutput = NonNullable<TaskOutput["speech"]>;
/** One record of `TaskOutput.speech.controls` (ADR 025 §4). */
export type SpeechControlOutcome = NonNullable<SpeechOutput["controls"]>[number];

/**
 * The request's speech controls in the planner's fixed order (rate, pitch, volume), or nothing
 * when it names none, so a request without controls projects exactly as before (ADR 025).
 */
function controlRequirements(request: TaskRequest): { controls?: ControlRequirement[] } {
  const controls = requestedControls(request);
  return controls.length > 0 ? { controls } : {};
}

/**
 * The speech controls the request names, in the planner's fixed order (rate, pitch, volume),
 * with the requirement defaulted to `preferred`. Empty for a request that names none. Every
 * control check below compares against this list, so all of them read the request the same way
 * the planner does.
 */
export function requestedControls(request: TaskRequest): ControlRequirement[] {
  const named: Array<
    [
      ControlRequirement["id"],
      { value: number; requirement?: ControlRequirement["requirement"] } | undefined
    ]
  > = [
    ["speech.speakingRate", request.speech?.controls?.speakingRate],
    ["speech.pitch", request.speech?.controls?.pitch],
    ["playback.volume", request.delivery?.playback?.volume]
  ];
  return named.flatMap(([id, control]) =>
    control === undefined
      ? []
      : [{ id, value: control.value, requirement: control.requirement ?? "preferred" }]
  );
}

const taskProfiles = new Map<string, TaskProfile>([
  [textToText.kind, textToText],
  [textToSpeech.kind, textToSpeech]
]);

/**
 * Adds a task profile. Internal and not exported from the package: a real task needs its
 * schema kind and payload first (ADR 016). It exists so a test can prove a third task runs
 * through routing, execution and output normalization without changing the engine.
 * @internal
 */
export function registerTaskProfile(profile: TaskProfile): void {
  taskProfiles.set(profile.kind, profile);
}

/** The profile for `kind`, or `undefined` when this engine cannot execute the task. */
export function taskProfileFor(kind: string): TaskProfile | undefined {
  return taskProfiles.get(kind);
}

/**
 * Re-checks, immediately before an attempt, that the voice the plan bound for this
 * provider still satisfies the request's privacy policy. The planner already chose the
 * voice inside that policy; repeating the check here keeps privacy enforceable at the
 * last point before data reaches the provider, independent of how the plan was produced.
 * A violation fails the attempt before commit, so the run may fall back.
 *
 * @returns The exception to fail the attempt with, or `undefined` when the voice is allowed.
 */
export function recheckBoundVoice(
  request: TaskRequest,
  providerId: string,
  voice: BoundVoice | undefined
): IndeRunException | undefined {
  if (voice?.networkRequired !== true || request.constraints?.privacy !== "local_required") {
    return undefined;
  }
  return createCapabilityMismatch(
    `Provider '${providerId}' was bound to a voice that sends data off the device, which privacy=local_required forbids.`,
    { providerId, details: { code: "privacy_recheck_failed" } }
  );
}

/**
 * Checks, after planning and before the first attempt, the control application plan of every
 * candidate, fallbacks included, against the request (ADR 025 §3). The planner boundary carries
 * no version, so a route core built without plans would return candidates with none, and a
 * required control would silently vanish: a missing plan is not an empty request.
 *
 * @returns `Internal` with `details.code: control_plan_mismatch` for the first candidate whose
 *   plan does not match, or `undefined` when every plan does. No attempt may follow a mismatch.
 */
export function checkControlPlans(
  request: TaskRequest,
  candidates: ReadonlyArray<{ providerId: string; controls?: readonly ControlApplicationPlan[] }>
): IndeRunException | undefined {
  const requested = requestedControls(request);
  const mismatched = candidates.find(
    (candidate) => !controlPlanMatches(requested, candidate.controls)
  );
  if (mismatched === undefined) return undefined;
  return createInternal(
    `The route plan for provider '${mismatched.providerId}' does not match the request's speech controls.`,
    { details: { code: "control_plan_mismatch" } }
  );
}

/**
 * Whether `plan` is consistent with `requested`: one entry per requested control, in request
 * order, with the request's id, value and requirement, a known decision, and `apply` for every
 * required one. An `omit` entry carries its reason, which becomes the outcome record's reason, and
 * an `apply` entry carries none. Absent and empty plans are the same, so they match only a request
 * without controls, and any entry on a request without controls is a mismatch.
 */
export function controlPlanMatches(
  requested: readonly ControlRequirement[],
  plan: readonly ControlApplicationPlan[] | undefined
): boolean {
  const entries = plan ?? [];
  if (entries.length !== requested.length) return false;
  return requested.every((control, index) => {
    const entry = entries[index]!;
    return (
      entry.id === control.id &&
      entry.value === control.value &&
      entry.requirement === control.requirement &&
      (entry.decision === "apply"
        ? entry.reason === undefined
        : entry.decision === "omit" && entry.reason !== undefined) &&
      (control.requirement !== "required" || entry.decision === "apply")
    );
  });
}

/** How the run a provider's control records belong to ended. */
export type ControlOutcomeEnding = "completed" | "cancelled";

const NOT_APPLIED_REASONS: ReadonlySet<string> = new Set([
  "unsupported",
  "out_of_range",
  "range_unknown",
  "availability_unknown",
  "provider_rejected",
  "not_reported"
]);

/**
 * The method an applied control must report: volume attenuates playback, rate and pitch are
 * synthesized (ADR 025 §4).
 */
export function controlMethodFor(id: ControlRequirement["id"]): SpeechControlOutcome["method"] {
  return id === "playback.volume" ? "playback_attenuation" : "platform_synthesis";
}

/**
 * Validates the control records a provider reported and completes them (ADR 025 §4). The
 * result has one record per requested control, in request order: the provider's record where it
 * reported one, otherwise `not_applied` with `not_reported`. Application is never inferred
 * from the request.
 *
 * Refused, for any ending: a duplicate record, a record for a control the request did not name,
 * a `requested` value that is not the request's, an `applied` record whose method does not
 * match the control's phase, a `not_applied` record without a known reason, an unknown status.
 * Refused only for a `completed` ending: a required control without an `applied` record. A
 * `cancelled` ending keeps what was reported, because a stop is an ending, not a failure.
 *
 * @returns The completed records, or `Internal` with `details.code: output_mismatch`.
 */
export function completeControlOutcomes(
  request: TaskRequest,
  reported: readonly SpeechControlOutcome[] | undefined,
  ending: ControlOutcomeEnding,
  providerId: string
): SpeechControlOutcome[] | IndeRunException {
  const mismatch = (problem: string) =>
    createInternal(`Provider '${providerId}' reported speech control records ${problem}.`, {
      providerId,
      details: { code: "output_mismatch" }
    });
  const requested = requestedControls(request);
  const records = new Map<string, SpeechControlOutcome>();
  for (const record of reported ?? []) {
    const control = requested.find((candidate) => candidate.id === record.id);
    if (control === undefined)
      return mismatch(`for '${record.id}', which the request did not name`);
    if (records.has(record.id)) return mismatch(`with '${record.id}' twice`);
    if (record.requested !== control.value) {
      return mismatch(`with '${record.id}' requested at ${record.requested}, not ${control.value}`);
    }
    if (record.status === "applied") {
      if (record.method !== controlMethodFor(control.id)) {
        return mismatch(`with '${record.id}' applied by '${String(record.method)}'`);
      }
    } else if (record.status === "not_applied") {
      if (record.reason === undefined || !NOT_APPLIED_REASONS.has(record.reason)) {
        return mismatch(`with '${record.id}' not applied for no known reason`);
      }
    } else {
      return mismatch(`with '${record.id}' in an unknown status`);
    }
    records.set(record.id, record);
  }
  if (ending === "completed") {
    const unmet = requested.find(
      (control) =>
        control.requirement === "required" && records.get(control.id)?.status !== "applied"
    );
    if (unmet !== undefined) return mismatch(`without required '${unmet.id}' applied`);
  }
  return requested.map(
    (control) =>
      records.get(control.id) ?? {
        id: control.id,
        requested: control.value,
        status: "not_applied",
        reason: "not_reported"
      }
  );
}

/**
 * Completes the control records of a completed run's output (see
 * {@link completeControlOutcomes}). A request without controls leaves the output as it is, and
 * refuses one that carries records. Records live only in the output's `speech` section, so an
 * output without one has none. For a request whose controls are all preferred it passes
 * unchanged, with no section and no records, because the engine never invents the locale a
 * section states; with a required control it is refused, since nothing says it was applied.
 *
 * @returns The output to deliver, or `Internal` with `details.code: output_mismatch`.
 */
export function completeOutputControls(
  request: TaskRequest,
  output: TaskOutput,
  providerId: string
): TaskOutput | IndeRunException {
  const reported = output.speech?.controls;
  const requested = requestedControls(request);
  if (requested.length === 0) {
    const records = completeControlOutcomes(request, reported, "completed", providerId);
    return records instanceof IndeRunException ? records : output;
  }
  if (output.speech === undefined) {
    if (requested.every((control) => control.requirement !== "required")) return output;
    return createInternal(
      `Provider '${providerId}' reported no speech outcome for a request with a required speech control.`,
      { providerId, details: { code: "output_mismatch" } }
    );
  }
  const controls = completeControlOutcomes(request, reported, "completed", providerId);
  if (controls instanceof IndeRunException) return controls;
  return { ...output, speech: { ...output.speech, controls } };
}

/**
 * The speech section of a cancelled terminal outcome, from what the attempt reported through
 * `RunContext.reportSpeech` before the stop: the reported records are kept and every other
 * requested control becomes `not_applied` / `not_reported`. A report that breaks the record
 * rules cannot fail a cancelled run, so none of its records is trusted: every requested control
 * is then `not_reported`. Without a report there is no section, since nothing says which locale
 * was spoken.
 */
export function cancelledSpeechOutcome(
  request: TaskRequest,
  reported: SpeechOutput | undefined,
  providerId: string
): SpeechOutput | undefined {
  if (reported === undefined) return undefined;
  const { controls: reportedControls, ...speech } = reported;
  const kept = completeControlOutcomes(request, reportedControls, "cancelled", providerId);
  const controls =
    kept instanceof IndeRunException
      ? (completeControlOutcomes(
          request,
          undefined,
          "cancelled",
          providerId
        ) as SpeechControlOutcome[])
      : kept;
  return controls.length > 0 ? { ...speech, controls } : speech;
}

/**
 * Checks a provider's output against the delivery the request asked for: inline text for
 * `inline`, a playback completion for `playback`, a media artifact for `artifact` whose
 * media type is one the request accepts. A provider never substitutes one for another
 * (ADR 016 §4), so a mismatch is a provider fault, not a result.
 *
 * @returns The exception to fail the attempt with, or `undefined` when the output matches.
 */
export function checkOutput(
  request: TaskRequest,
  delivery: OutputDelivery,
  output: TaskOutput | undefined,
  providerId: string
): IndeRunException | undefined {
  const expected = { inline: "text", playback: "playback", artifact: "artifact" }[delivery];
  const matches =
    output?.type === expected &&
    (expected === "text"
      ? typeof output.text === "string"
      : expected === "playback"
        ? output.playback !== undefined
        : output.artifact !== undefined && acceptsMediaType(request, output.artifact.mediaType));
  if (matches) return undefined;
  return createInternal(
    `Provider '${providerId}' returned ${output === undefined ? "no output" : `a '${output.type}' output`} for a '${delivery}' request.`,
    { providerId, details: { code: "output_mismatch" } }
  );
}

/** Whether `mediaType` (parameters ignored, case-insensitive) is one the request accepts. */
function acceptsMediaType(request: TaskRequest, mediaType: string): boolean {
  const accepted = request.delivery?.mediaTypes;
  if (accepted === undefined) return true;
  const base = (type: string) => type.split(";")[0]!.trim().toLowerCase();
  return accepted.some((type) => base(type) === base(mediaType));
}
