import type { ExecutionProvenance, IndeRunErrorClass } from "@independo/inderun-contracts";
import type { ProviderDescriptor } from "./provider.js";
import type { SharedPlannerRoutePlan } from "./route-planner.js";
import { AUTO_MODEL_PROFILE } from "./model-profiles.js";

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

  /** Records how one provider attempt ended. */
  attempted(
    providerId: string,
    outcome: ExecutionProvenanceAttempt["outcome"],
    errorClass?: IndeRunErrorClass
  ): void {
    this.attempts.push({
      providerId,
      outcome,
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
      locality: attributedTo !== undefined ? localityOf(attributedTo) : "unknown",
      ...(attributedTo?.model !== undefined ? { configuredModel: attributedTo.model } : {}),
      ...(attributedTo !== undefined && reportedModel !== undefined ? { reportedModel } : {}),
      attemptCount: this.attempts.length,
      fallbackOccurred: this.attempts.length > 1,
      attempts: [...this.attempts],
      routeRejections: [...this.routeRejections]
    };
  }
}

function localityOf(descriptor: ProviderDescriptor): ExecutionProvenance["locality"] {
  switch (descriptor.type) {
    case "local":
      return "on_device";
    case "edge":
      return "edge";
    case "cloud":
      return "cloud";
  }
}

function routeRejectionsFrom(
  rejected: SharedPlannerRoutePlan["rejectedProviders"]
): RouteRejection[] {
  return rejected.map((provider) => ({
    providerId: provider.providerId,
    codes: provider.reasons.map((reason) => reason.code)
  }));
}
