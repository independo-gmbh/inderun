import type { TaskRequest } from "@independo/inderun-contracts";
import type { HostServices } from "./host.js";
import type { ProviderAdapter } from "./provider.js";
import type { ProviderRegistry } from "./registry.js";
import {
  createCapabilityMismatch,
  createInternal,
  createOffline,
  createUnavailable
} from "./errors.js";
import {
  buildSharedPlannerInput,
  collectProviderRuntimeSnapshots,
  type ProviderRuntimeSnapshot,
  type RoutePlanner,
  type SharedPlannerInput,
  type SharedPlannerRoutePlan,
  WasmRoutePlanner
} from "./route-planner.js";

/**
 * Output structure from the Router containing the chosen provider and a route selection description.
 */
export interface RouteSelection {
  /**
   * The selected provider adapter to run.
   */
  provider: ProviderAdapter;
  /**
   * Ordered fallback providers to try if the primary provider fails before producing a final result.
   */
  fallbackProviders: ProviderAdapter[];
  /**
   * The shared route plan used to select this provider chain.
   */
  routePlan: SharedPlannerRoutePlan;
  /**
   * Explanation detailing the selection decision. Useful for debugging and telemetry.
   */
  explanation: string;
}

/**
 * Routing engine module. Filters registered providers against task types, request constraints,
 * and dynamic host capabilities (such as connectivity and battery/thermal constraints)
 * to output deterministic execution pathways.
 */
export class Router {
  constructor(
    private registry: ProviderRegistry,
    private planner: RoutePlanner = new WasmRoutePlanner()
  ) {}

  /**
   * Selects an optimal and compatible execution provider based on the task request and host conditions.
   * @param request - The canonical task request payload.
   * @param hostServices - Host services containing network status and hardware indicators.
   * @returns Resolves to the selected RouteSelection object.
   * @throws {IndeRunException} Under the following routing failure rules:
   *  - `CapabilityMismatch` when `execution === 'on_device'` but no local provider is registered or available.
   *  - `Offline` when `execution === 'cloud'` but the device lacks internet connectivity.
   *  - `Unavailable` when `execution === 'cloud'` but no cloud provider is registered or functional.
   */
  async selectRoute(request: TaskRequest, hostServices: HostServices): Promise<RouteSelection> {
    const online = await hostServices.connectivity.isOnline();
    const snapshots = await collectProviderRuntimeSnapshots(this.registry.list(), hostServices);

    const planInput = buildSharedPlannerInput(request, snapshots, online);
    const routePlan = await this.planner.planRoute(planInput);

    if (routePlan) {
      return this.selectFromSharedPlan(snapshots, routePlan);
    }

    return this.selectFallbackRoute(request, snapshots, online);
  }

  private selectFromSharedPlan(
    snapshots: ProviderRuntimeSnapshot[],
    routePlan: SharedPlannerRoutePlan
  ): RouteSelection {
    if (!routePlan.selectedProviderId) {
      throw this.routePlanFailure(routePlan);
    }

    return this.buildSelectionFromRoutePlan(snapshots, routePlan);
  }

  private selectFallbackRoute(
    request: TaskRequest,
    snapshots: ProviderRuntimeSnapshot[],
    online: boolean
  ): RouteSelection {
    const plan = this.createFallbackPlan(request, snapshots, online);
    if (!plan.selectedProviderId) {
      throw this.routePlanFailure(plan);
    }

    return this.buildSelectionFromRoutePlan(snapshots, plan);
  }

  private buildSelectionFromRoutePlan(
    snapshots: ProviderRuntimeSnapshot[],
    routePlan: SharedPlannerRoutePlan
  ): RouteSelection {
    const orderedProviders = routePlan.candidates
      .map((candidate) =>
        snapshots.find((snapshot) => snapshot.descriptor.id === candidate.providerId)
      )
      .filter((snapshot): snapshot is ProviderRuntimeSnapshot => snapshot !== undefined);

    const selected = orderedProviders[0];
    if (!selected) {
      throw createInternal("Route plan selected a provider that is no longer registered.");
    }

    return {
      provider: selected.provider,
      fallbackProviders: orderedProviders.slice(1).map((snapshot) => snapshot.provider),
      routePlan,
      explanation: routePlan.explanation.summary
    };
  }

  private createFallbackPlan(
    request: TaskRequest,
    snapshots: ProviderRuntimeSnapshot[],
    online: boolean
  ): SharedPlannerRoutePlan {
    const planInput = buildSharedPlannerInput(request, snapshots, online);
    const eligible = snapshots
      .filter((candidate) => candidate.descriptor.tasks.includes(planInput.task.kind))
      .filter((candidate) => candidate.descriptor.supports.run);

    const localCandidates = eligible.filter((candidate) => candidate.descriptor.type !== "cloud");
    const cloudCandidates = eligible.filter((candidate) => candidate.descriptor.type === "cloud");

    const selected = eligible.find((candidate) => {
      const descriptor = candidate.descriptor;
      const constraints = planInput.constraints;
      const privacy = descriptor.privacy?.dataLeavesDevice ?? descriptor.type !== "cloud";

      if (constraints.cloud === "forbidden" && descriptor.type === "cloud") {
        return false;
      }

      if (constraints.cloud === "required" && descriptor.type !== "cloud") {
        return false;
      }

      if (constraints.privacy === "local_required" && !privacy) {
        return false;
      }

      if (constraints.privacy === "cloud_required" && descriptor.type !== "cloud") {
        return false;
      }

      if (!online && descriptor.type === "cloud") {
        return false;
      }

      return candidate.capabilities.available;
    });

    const ordered = selected
      ? [selected, ...eligible.filter((candidate) => candidate !== selected)]
      : [];

    if (ordered.length === 0) {
      const failureSummary = this.buildFallbackFailureSummary({
        online,
        constraints: planInput.constraints,
        localCandidates,
        cloudCandidates
      });
      const failureCode = !online
        ? "offline"
        : planInput.constraints.cloud === "required" ||
            planInput.constraints.privacy === "cloud_required"
          ? "unavailable"
          : "capability_mismatch";

      return {
        fallbackProviderIds: [],
        candidates: [],
        rejectedProviders: [],
        failureCode,
        explanation: {
          summary: failureSummary
        }
      };
    }

    const selectedProviderId = ordered[0]?.descriptor.id;

    return {
      selectedProviderId,
      fallbackProviderIds: ordered.slice(1).map((candidate) => candidate.descriptor.id),
      candidates: ordered.map((candidate, index) => ({
        providerId: candidate.descriptor.id,
        order: index
      })),
      rejectedProviders: [],
      explanation: {
        summary: `Selected provider '${selectedProviderId}' deterministically from ${ordered.length} eligible candidate(s).`,
        selectedProviderId
      }
    };
  }

  private buildFallbackFailureSummary(input: {
    online: boolean;
    constraints: SharedPlannerInput["constraints"];
    localCandidates: ProviderRuntimeSnapshot[];
    cloudCandidates: ProviderRuntimeSnapshot[];
  }): string {
    const wantsCloud =
      input.constraints.cloud === "required" || input.constraints.privacy === "cloud_required";
    const wantsLocal = input.constraints.privacy === "local_required";

    if (!input.online && (wantsCloud || input.cloudCandidates.length > 0)) {
      return "No network connection is available.";
    }

    if (wantsCloud) {
      if (input.cloudCandidates.length === 0) {
        return "No cloud provider found.";
      }

      return "No cloud provider is currently available.";
    }

    if (wantsLocal) {
      if (input.localCandidates.length === 0) {
        return "No on-device provider found.";
      }

      return "No on-device provider is currently available.";
    }

    return "No eligible provider found for the current routing constraints.";
  }

  private routePlanFailure(routePlan: SharedPlannerRoutePlan): never {
    const message = routePlan.explanation.summary;
    switch (routePlan.failureCode) {
      case "offline":
        throw createOffline(message);
      case "unavailable":
        throw createUnavailable(message);
      case "capability_mismatch":
      default:
        throw createCapabilityMismatch(message);
    }
  }
}
