import type { ExecutionProvenance, IndeRunErrorClass } from "@independo/inderun-contracts";
import type { ProviderDescriptor } from "./provider.js";
import type { SharedPlannerRoutePlan } from "./route-planner.js";
import { AUTO_MODEL_PROFILE } from "./model-profiles.js";
import type { BoundVoice } from "./task-profiles.js";

type ExecutionProvenanceAttempt = ExecutionProvenance["attempts"][number];
type RouteRejection = ExecutionProvenance["routeRejections"][number];

/**
 * Accumulates what one execution did -- each attempt and how it ended -- and renders it as the
 * normalized {@link ExecutionProvenance} carried on results, terminal outcomes, and errors.
 *
 * Everything recorded is either observed by the engine (attempts, their outcomes) or declared or
 * reported by a provider (descriptor type and model, the model a response names). Nothing is
 * inferred: an unknown is left absent or reported as `unknown`.
 */
export class ProvenanceRecorder {
  private readonly attempts: ExecutionProvenanceAttempt[] = [];
  private routeRejections: RouteRejection[] = [];
  private readonly boundVoices = new Map<string, { taskKind: string; voice?: BoundVoice }>();

  constructor(private readonly modelProfile: string = AUTO_MODEL_PROFILE) {}

  /** Records the planner's rejections; codes only, never the provider-supplied messages. */
  routed(routePlan: SharedPlannerRoutePlan): void {
    this.routeRejections = routeRejectionsFrom(routePlan.rejectedProviders);
  }

  /** Records the rejections a routing failure carried out on its exception's details. */
  routingFailed(details: Record<string, unknown> | undefined): void {
    const rejected = details?.rejectedProviders;
    if (Array.isArray(rejected)) {
      this.routeRejections = routeRejectionsFrom(
        rejected as SharedPlannerRoutePlan["rejectedProviders"]
      );
    }
  }

  /** Records the voice a provider was handed, which decides what its locality can claim. */
  voiceBound(providerId: string, taskKind: string, voice: BoundVoice | undefined): void {
    this.boundVoices.set(providerId, { taskKind, ...(voice !== undefined ? { voice } : {}) });
  }

  /**
   * Records how one provider attempt ended, and whether the run had committed to it
   * (first content delivered, first possible audible effect, or an artifact handed over).
   */
  attempted(
    providerId: string,
    outcome: ExecutionProvenanceAttempt["outcome"],
    errorClass?: IndeRunErrorClass,
    committed = false
  ): void {
    this.attempts.push({
      providerId,
      outcome,
      ...(committed ? { committed: true } : {}),
      ...(errorClass !== undefined ? { errorClass } : {})
    });
  }

  /**
   * Renders the record. `attributedTo` is the provider the outcome belongs to -- the one that
   * produced the result, the one a stream was committed to, or the one running at cancellation --
   * and is absent when no provider was reached or every attempt failed before a commit.
   */
  build(attributedTo?: ProviderDescriptor, reportedModel?: string): ExecutionProvenance {
    return {
      schemaVersion: "1.0",
      modelProfile: this.modelProfile,
      ...(attributedTo !== undefined ? { providerId: attributedTo.id } : {}),
      locality:
        attributedTo !== undefined
          ? localityOf(attributedTo, this.boundVoices.get(attributedTo.id))
          : "unknown",
      ...(attributedTo?.model !== undefined ? { configuredModel: attributedTo.model } : {}),
      ...(attributedTo !== undefined && reportedModel !== undefined ? { reportedModel } : {}),
      attemptCount: this.attempts.length,
      fallbackOccurred: this.attempts.length > 1,
      attempts: [...this.attempts],
      routeRejections: [...this.routeRejections]
    };
  }
}

const SPEECH = "text_to_speech";

/**
 * The locality to report for a provider. A `local` provider is `on_device` only as far as its
 * voice allows: one that may send text off the device reports `unknown`, because the provider
 * runs here while the synthesis may not. Absent `networkRequired` inherits the task's privacy
 * posture, as it does in the planner. A speech run with no bound voice also reports `unknown`: an
 * engine that lists no voices chooses one itself, and nothing shows where that one runs.
 */
export function localityOf(
  descriptor: ProviderDescriptor,
  bound?: { taskKind: string; voice?: BoundVoice }
): ExecutionProvenance["locality"] {
  switch (descriptor.type) {
    case "local":
      if (bound === undefined) return "on_device";
      if (bound.voice === undefined) return bound.taskKind === SPEECH ? "unknown" : "on_device";
      return voiceMayLeaveDevice(descriptor, bound.taskKind, bound.voice) ? "unknown" : "on_device";
    case "edge":
      return "edge";
    case "cloud":
      return "cloud";
  }
}

function voiceMayLeaveDevice(
  descriptor: ProviderDescriptor,
  taskKind: string,
  voice: BoundVoice
): boolean {
  const task = descriptor.taskCapabilities?.find((entry) => entry.kind === taskKind);
  const privacy = task?.privacy ?? descriptor.privacy;
  return voice.networkRequired ?? privacy?.dataLeavesDevice ?? false;
}

function routeRejectionsFrom(
  rejected: SharedPlannerRoutePlan["rejectedProviders"]
): RouteRejection[] {
  return rejected.map((provider) => ({
    providerId: provider.providerId,
    codes: provider.reasons.map((reason) => reason.code)
  }));
}
