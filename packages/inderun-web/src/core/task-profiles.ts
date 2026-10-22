import type {
  SharedRoutePlan,
  SharedRoutePlannerInput,
  TaskRequest
} from "@independo/inderun-contracts";
import { createCapabilityMismatch, type IndeRunException } from "./errors.js";

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
              ...(speech.voice.gender !== undefined ? { gender: speech.voice.gender } : {}),
              requirement: speech.voice.requirement ?? "preferred"
            }
          }
        : {})
    };
  },
  delivery: (request) => request.delivery!.mode
};

const taskProfiles = new Map<string, TaskProfile>([
  [textToText.kind, textToText],
  [textToSpeech.kind, textToSpeech]
]);

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
