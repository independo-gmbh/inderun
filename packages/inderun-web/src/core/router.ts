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
  type SharedPlannerInput,
  type SharedPlannerRoutePlan,
  type WasmUnavailableReason,
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
  /**
   * Which planner produced `routePlan`: the shared Rust/WASM core, or the
   * local TypeScript fallback used when the WASM planner is unavailable.
   */
  plannerSource: "wasm" | "fallback";
  /**
   * Set when `plannerSource` is `"fallback"` because the WASM planner failed;
   * `undefined` when the fallback was not caused by a planner failure.
   */
  plannerUnavailableReason?: WasmUnavailableReason;
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

    if (outcome.routePlan) {
      return this.selectFromSharedPlan(snapshots, outcome.routePlan);
    }

    return this.selectFallbackRoute(
      request,
      snapshots,
      online,
      interactionMode,
      outcome.unavailableReason
    );
  }

  private selectFromSharedPlan(
    snapshots: ProviderRuntimeSnapshot[],
    routePlan: SharedPlannerRoutePlan
  ): RouteSelection {
    if (!routePlan.selectedProviderId) {
      throw this.routePlanFailure(routePlan);
    }

    return this.buildSelectionFromRoutePlan(snapshots, routePlan, "wasm");
  }

  private selectFallbackRoute(
    request: TaskRequest,
    snapshots: ProviderRuntimeSnapshot[],
    online: boolean,
    interactionMode: InteractionMode,
    plannerUnavailableReason?: WasmUnavailableReason
  ): RouteSelection {
    const plan = this.createFallbackPlan(request, snapshots, online, interactionMode);
    if (!plan.selectedProviderId) {
      throw this.routePlanFailure(plan);
    }

    return this.buildSelectionFromRoutePlan(snapshots, plan, "fallback", plannerUnavailableReason);
  }

  private buildSelectionFromRoutePlan(
    snapshots: ProviderRuntimeSnapshot[],
    routePlan: SharedPlannerRoutePlan,
    plannerSource: "wasm" | "fallback",
    plannerUnavailableReason?: WasmUnavailableReason
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
      explanation: routePlan.explanation.summary,
      plannerSource,
      ...(plannerUnavailableReason ? { plannerUnavailableReason } : {})
    };
  }

  /**
   * Hand-written mirror of the shared Rust planner (`rust/inderun-route-core/src/planner.rs`),
   * used when the WASM core cannot be loaded. It reproduces the same rejection
   * codes and messages so route explanations stay comparable across both paths.
   *
   * Known, deliberate divergence: this mirror keeps the id-sorted snapshot order
   * instead of reproducing the Rust placement/preference ranks, so `optimizeFor`
   * does not influence ordering here.
   */
  private createFallbackPlan(
    request: TaskRequest,
    snapshots: ProviderRuntimeSnapshot[],
    online: boolean,
    interactionMode: InteractionMode
  ): SharedPlannerRoutePlan {
    const planInput = buildSharedPlannerInput(request, snapshots, online, interactionMode);
    const eligible = snapshots.filter((candidate) =>
      candidate.descriptor.tasks.includes(planInput.task.kind)
    );

    const localCandidates = eligible.filter((candidate) => candidate.descriptor.type !== "cloud");
    const cloudCandidates = eligible.filter((candidate) => candidate.descriptor.type === "cloud");

    // Constraint filtering must apply to the whole candidate list, not just the selected provider:
    // the remainder becomes the engine's fallback chain, and a fallback that violates the request
    // constraints would let a `local_required` run be retried against a cloud provider.
    const admissible: ProviderRuntimeSnapshot[] = [];
    const rejectedProviders: SharedPlannerRoutePlan["rejectedProviders"] = [];

    for (const candidate of snapshots) {
      const reasons = this.evaluateFallbackCandidate(candidate, planInput, interactionMode);
      if (reasons.length === 0) {
        admissible.push(candidate);
      } else {
        rejectedProviders.push({ providerId: candidate.descriptor.id, reasons });
      }
    }

    if (admissible.length === 0) {
      const failureSummary = this.buildFallbackFailureSummary({
        online,
        interactionMode,
        taskKind: planInput.task.kind,
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
        rejectedProviders,
        failureCode,
        explanation: {
          summary: failureSummary
        }
      };
    }

    const selectedProviderId = admissible[0]?.descriptor.id;
    const summary =
      interactionMode === "stream"
        ? `Selected streaming provider '${selectedProviderId}' deterministically from ${admissible.length} eligible candidate(s).`
        : `Selected provider '${selectedProviderId}' deterministically from ${admissible.length} eligible candidate(s).`;

    return {
      selectedProviderId,
      fallbackProviderIds: admissible.slice(1).map((candidate) => candidate.descriptor.id),
      candidates: admissible.map((candidate, index) => ({
        providerId: candidate.descriptor.id,
        order: index
      })),
      rejectedProviders,
      explanation: {
        summary,
        selectedProviderId
      }
    };
  }

  /**
   * Mirrors `evaluate_provider` in the shared Rust planner: it accumulates every
   * violated rule rather than short-circuiting, so a rejected provider carries a
   * complete explanation. The streaming checks are ordered static-before-dynamic
   * for the same reason as in Rust — a provider that never declared streaming
   * must not also be reported as dynamically unavailable.
   */
  private evaluateFallbackCandidate(
    candidate: ProviderRuntimeSnapshot,
    planInput: SharedPlannerInput,
    interactionMode: InteractionMode
  ): SharedPlannerRoutePlan["rejectedProviders"][number]["reasons"] {
    const descriptor = candidate.descriptor;
    const capabilities = candidate.capabilities;
    const constraints = planInput.constraints;
    const wantsStream = interactionMode === "stream";
    const reasons: SharedPlannerRoutePlan["rejectedProviders"][number]["reasons"] = [];

    // Mirrors `is_data_private` in the shared Rust planner: a provider is private when it
    // declares that data does not leave the device, defaulting to non-cloud providers.
    const isDataPrivate = descriptor.privacy
      ? !descriptor.privacy.dataLeavesDevice
      : descriptor.type !== "cloud";

    if (!descriptor.tasks.includes(planInput.task.kind)) {
      reasons.push({
        code: "task_not_supported",
        message: `Provider '${descriptor.id}' does not support task '${planInput.task.kind}'.`
      });
    }

    if (!wantsStream && !descriptor.supports.run) {
      reasons.push({
        code: "run_not_supported",
        message: `Provider '${descriptor.id}' does not support run().`
      });
    }

    if (wantsStream) {
      if (!descriptor.supports.streaming) {
        reasons.push({
          code: "streaming_not_supported",
          message: `Provider '${descriptor.id}' does not support streaming (Mode 2).`
        });
      } else if (capabilities.streamingAvailable === false) {
        reasons.push({
          code: "streaming_unavailable",
          message:
            capabilities.streamingUnavailableReason ??
            `Provider '${descriptor.id}' cannot stream in the current host environment.`
        });
      }
    }

    if (constraints.privacy === "local_required" && !isDataPrivate) {
      reasons.push({
        code: "privacy_constraint",
        message: `Provider '${descriptor.id}' does not satisfy local-required privacy.`
      });
    }

    if (constraints.privacy === "cloud_required" && descriptor.type !== "cloud") {
      reasons.push({
        code: "privacy_constraint",
        message: `Provider '${descriptor.id}' does not satisfy cloud-required privacy.`
      });
    }

    if (constraints.cloud === "forbidden" && descriptor.type === "cloud") {
      reasons.push({
        code: "cloud_constraint",
        message: `Provider '${descriptor.id}' is cloud-based but cloud execution is forbidden.`
      });
    }

    if (constraints.cloud === "required" && descriptor.type !== "cloud") {
      reasons.push({
        code: "cloud_constraint",
        message: `Provider '${descriptor.id}' is not cloud-based but cloud execution is required.`
      });
    }

    if (constraints.networkOnline === false && descriptor.type === "cloud") {
      reasons.push({
        code: "offline",
        message: `Provider '${descriptor.id}' requires cloud connectivity, but the host is offline.`
      });
    }

    if (!capabilities.available) {
      reasons.push({
        code: "capability_unavailable",
        message: capabilities.reason ?? `Provider '${descriptor.id}' is currently unavailable.`
      });
    }

    return reasons;
  }

  private buildFallbackFailureSummary(input: {
    online: boolean;
    interactionMode: InteractionMode;
    taskKind: string;
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

    if (input.interactionMode === "stream") {
      // Kept verbatim in sync with the shared Rust planner's stream-mode failure
      // summary so the message a caller sees does not depend on which planner ran.
      return `No provider capable of streaming was found for task '${input.taskKind}'.`;
    }

    return "No eligible provider found for the current routing constraints.";
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
