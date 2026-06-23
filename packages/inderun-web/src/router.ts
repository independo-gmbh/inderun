import type { TaskRequest } from "@independo/inderun-contracts";
import type { HostServices } from "./host.js";
import type { ProviderAdapter } from "./provider.js";
import type { ProviderRegistry } from "./registry.js";
import { createCapabilityMismatch, createOffline, createUnavailable } from "./errors.js";
import {
  buildSharedPlannerInput,
  collectProviderRuntimeSnapshots,
  type ProviderRuntimeSnapshot,
  type RoutePlanner,
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
   * Explanation detailing the selection decision. Useful for debugging and telemetry.
   */
  explanation: string;
}

/**
 * Routing engine module. Filters registered providers against task types, execution policies,
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
  async selectRoute(
    request: TaskRequest,
    hostServices: HostServices
  ): Promise<RouteSelection> {
    const online = await hostServices.connectivity.isOnline();
    const snapshots = await collectProviderRuntimeSnapshots(
      this.registry.list(),
      hostServices
    );

    const planInput = buildSharedPlannerInput(
      request,
      snapshots,
      online
    );
    const routePlan = await this.planner.planRoute(planInput);

    if (routePlan) {
      return this.selectFromSharedPlan(request, snapshots, routePlan);
    }

    return this.selectLegacyRoute(request, snapshots, online);
  }

  private selectFromSharedPlan(
    request: TaskRequest,
    snapshots: ProviderRuntimeSnapshot[],
    routePlan: SharedPlannerRoutePlan
  ): RouteSelection {
    const selectedProviderId = routePlan.selectedProviderId ?? undefined;
    if (selectedProviderId) {
      const selected = snapshots.find(
        (snapshot) => snapshot.descriptor.id === selectedProviderId
      );
      if (selected) {
        return {
          provider: selected.provider,
          explanation: routePlan.explanation.summary
        };
      }
    }

    const message = routePlan.explanation.summary;
    switch (routePlan.failureCode) {
      case "offline":
        throw createOffline(message);
      case "unavailable":
        throw createUnavailable(message);
      case "capability_mismatch":
      default:
        if (request.policy.execution === "cloud") {
          throw createUnavailable(message);
        }
        throw createCapabilityMismatch(message);
    }
  }

  private selectLegacyRoute(
    request: TaskRequest,
    snapshots: ProviderRuntimeSnapshot[],
    online: boolean
  ): RouteSelection {
    const taskKind = request.task.kind;
    const executionPolicy = request.policy.execution;

    const taskCandidates = snapshots.filter(
      (candidate) =>
        candidate.descriptor.tasks.includes(taskKind) &&
        candidate.descriptor.supports.run
    );

    if (executionPolicy === "on_device") {
      const localCandidates = taskCandidates.filter(
        (candidate) => candidate.descriptor.type === "local"
      );

      if (localCandidates.length === 0) {
        throw createCapabilityMismatch(
          `Capability mismatch: no on-device provider found supporting task '${taskKind}'.`
        );
      }

      const selected = localCandidates.find(
        (candidate) => candidate.capabilities.available
      );
      if (selected) {
        return {
          provider: selected.provider,
          explanation: `Selected on-device provider '${selected.descriptor.id}' deterministically.`
        };
      }

      throw createCapabilityMismatch(
        "Capability mismatch: on-device execution selected, but on-device provider is currently unavailable."
      );
    }

    if (!online) {
      throw createOffline(
        "Offline: cloud execution selected, but no network connection is available."
      );
    }

    const cloudCandidates = taskCandidates.filter(
      (candidate) => candidate.descriptor.type === "cloud"
    );

    if (cloudCandidates.length === 0) {
      throw createUnavailable(
        `Unavailable: no cloud provider found supporting task '${taskKind}'.`
      );
    }

    const selected = cloudCandidates.find(
      (candidate) => candidate.capabilities.available
    );
    if (selected) {
      return {
        provider: selected.provider,
        explanation: `Selected cloud provider '${selected.descriptor.id}' deterministically.`
      };
    }

    throw createUnavailable(
      "Unavailable: cloud execution selected, but no cloud provider is currently available."
    );
  }
}
