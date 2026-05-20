import type { TaskRequest } from "@independo/inderun-contracts";
import type { HostServices } from "./host.js";
import type { ProviderAdapter } from "./provider.js";
import type { ProviderRegistry } from "./registry.js";
import { createCapabilityMismatch, createOffline, createUnavailable } from "./errors.js";

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
  constructor(private registry: ProviderRegistry) {}

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
    const taskKind = request.task.kind;
    const executionPolicy = request.policy.execution;

    // 1. Map, sort, and filter candidate providers stably by ID to ensure deterministic selection
    const candidates = this.registry.list().map((p) => ({
      provider: p,
      descriptor: p.describe()
    })).sort((a, b) => a.descriptor.id.localeCompare(b.descriptor.id));

    const taskCandidates = candidates.filter(
      (c) => c.descriptor.tasks.includes(taskKind) && c.descriptor.supports.run
    );

    // 2. Route based on execution policy
    if (executionPolicy === "on_device") {
      const localCandidates = taskCandidates.filter(
        (c) => c.descriptor.type === "local"
      );

      if (localCandidates.length === 0) {
        throw createCapabilityMismatch(
          `Capability mismatch: no on-device provider found supporting task '${taskKind}'.`
        );
      }

      // Check dynamic capabilities of local candidates
      for (const candidate of localCandidates) {
        const caps = await candidate.provider.capabilities(hostServices);
        if (caps.available) {
          return {
            provider: candidate.provider,
            explanation: `Selected on-device provider '${candidate.descriptor.id}' deterministically.`
          };
        }
      }

      throw createCapabilityMismatch(
        "Capability mismatch: on-device execution selected, but on-device provider is currently unavailable."
      );
    } else if (executionPolicy === "cloud") {
      // Check network status before filtering cloud providers
      const online = await hostServices.connectivity.isOnline();
      if (!online) {
        throw createOffline(
          "Offline: cloud execution selected, but no network connection is available."
        );
      }

      const cloudCandidates = taskCandidates.filter(
        (c) => c.descriptor.type === "cloud"
      );

      if (cloudCandidates.length === 0) {
        throw createUnavailable(
          `Unavailable: no cloud provider found supporting task '${taskKind}'.`
        );
      }

      // Check dynamic capabilities of cloud candidates
      for (const candidate of cloudCandidates) {
        const caps = await candidate.provider.capabilities(hostServices);
        if (caps.available) {
          return {
            provider: candidate.provider,
            explanation: `Selected cloud provider '${candidate.descriptor.id}' deterministically.`
          };
        }
      }

      throw createUnavailable(
        "Unavailable: cloud execution selected, but no cloud provider is currently available."
      );
    } else {
      throw createCapabilityMismatch(
        `Capability mismatch: unsupported execution policy '${executionPolicy}'.`
      );
    }
  }
}
