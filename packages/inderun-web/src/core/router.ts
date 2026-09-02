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
  type InteractionMode,
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
   *
   * The requested `interactionMode` is a planning input, not a post-filter: the
   * shared planner rejects providers that cannot satisfy it and says why, so the
   * whole returned chain is mode-compatible.
   */
  async selectRoute(
    request: TaskRequest,
    hostServices: HostServices,
    interactionMode: InteractionMode = "run"
  ): Promise<RouteSelection> {
    const online = await hostServices.connectivity.isOnline();
    const snapshots = await collectProviderRuntimeSnapshots(this.registry.list(), hostServices);

    const planInput = buildSharedPlannerInput(request, snapshots, online, interactionMode);
    const outcome = await this.planner.planRoute(planInput);

    if (!outcome.routePlan) {
      // There is no second planner to degrade to: routing is the shared Rust
      // core's semantics or nothing. Failing here keeps provider selection
      // identical everywhere rather than forking it on a module load failure.
      const reason = outcome.unavailableReason ?? "import_failed";
      throw createInternal(`Route planner unavailable (${reason}).`, {
        details: { plannerUnavailableReason: reason }
      });
    }

    return this.selectFromSharedPlan(snapshots, outcome.routePlan);
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

  /**
   * Routing failure throws before any `route_decided` telemetry is emitted, so the
   * plan's diagnostics are attached to the exception — that is the only channel
   * through which a caller learns *why* each provider was rejected.
   */
  private routePlanFailure(routePlan: SharedPlannerRoutePlan): never {
    const message = routePlan.explanation.summary;
    const details = {
      details: {
        failureCode: routePlan.failureCode,
        rejectedProviders: routePlan.rejectedProviders
      }
    };
    switch (routePlan.failureCode) {
      case "offline":
        throw createOffline(message, details);
      case "unavailable":
        throw createUnavailable(message, details);
      case "capability_mismatch":
      default:
        throw createCapabilityMismatch(message, details);
    }
  }
}
