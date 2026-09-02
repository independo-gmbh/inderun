import type { TaskRequest, TaskResult } from "@independo/inderun-contracts";
import { beforeEach, describe, expect, it } from "vitest";
import { IndeRunException } from "./errors.js";
import type { HostServices } from "./host.js";
import type { ProviderAdapter } from "./provider.js";
import { ProviderRegistry } from "./registry.js";
import type { PlannerOutcome, RoutePlanner } from "./route-planner.js";
import { Router } from "./router.js";

/**
 * Covers the two properties the Router owes to the shared Rust core: ordering comes
 * from the core's placement/preference ranks rather than from registry order, and a
 * planner that cannot load fails the route instead of routing by different rules.
 */

function createHostServices(online = true): HostServices {
  return {
    connectivity: {
      async isOnline() {
        return online;
      }
    },
    clock: {
      now() {
        return 0;
      }
    }
  };
}

function createProvider(id: string, type: "local" | "cloud"): ProviderAdapter {
  return {
    describe() {
      return {
        id,
        type,
        transport: type === "cloud" ? "http" : "in_process",
        supports: {
          run: true,
          streaming: false,
          realtime: false,
          tools: false,
          reasoningEvents: false,
          structuredOutput: false,
          multimodal: false
        },
        cancel: "soft",
        tasks: ["text_to_text"],
        privacy: { dataLeavesDevice: type === "cloud" }
      };
    },
    async capabilities() {
      return { available: true };
    },
    async run(request: TaskRequest): Promise<TaskResult> {
      return {
        schemaVersion: "1.0",
        runId: request.requestId ?? "run-1",
        output: { type: "text", text: "unused" },
        finishReason: "stop",
        telemetry: { providerUsed: id, totalMs: 0 }
      };
    }
  };
}

describe("Router provider ordering", () => {
  let registry: ProviderRegistry;

  beforeEach(() => {
    registry = new ProviderRegistry();
    // Registered so that the id sort order (cloud-provider < local-provider)
    // disagrees with the ranking under `latency`, which is what makes this a
    // real assertion about the ranks rather than about the snapshot order.
    registry.register(createProvider("local-provider", "local"));
    registry.register(createProvider("cloud-provider", "cloud"));
  });

  it("prefers the local provider when optimizing for privacy", async () => {
    const selection = await new Router(registry).selectRoute(
      {
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "test prompt",
        preferences: { optimizeFor: "privacy" }
      },
      createHostServices()
    );

    expect(selection.routePlan.selectedProviderId).toBe("local-provider");
    expect(selection.routePlan.fallbackProviderIds).toEqual(["cloud-provider"]);
  });

  it("prefers the cloud provider when optimizing for latency", async () => {
    const selection = await new Router(registry).selectRoute(
      {
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "test prompt",
        preferences: { optimizeFor: "latency" }
      },
      createHostServices()
    );

    expect(selection.routePlan.selectedProviderId).toBe("cloud-provider");
    expect(selection.routePlan.fallbackProviderIds).toEqual(["local-provider"]);
  });
});

describe("Router when the shared planner is unavailable", () => {
  it("fails the route instead of planning with different semantics", async () => {
    const registry = new ProviderRegistry();
    registry.register(createProvider("local-provider", "local"));

    const planner: RoutePlanner = {
      async planRoute(): Promise<PlannerOutcome> {
        return { routePlan: null, unavailableReason: "init_failed" };
      }
    };

    const promise = new Router(registry, planner).selectRoute(
      {
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "test prompt"
      },
      createHostServices()
    );

    await expect(promise).rejects.toThrowError(/Route planner unavailable \(init_failed\)\./);

    try {
      await promise;
    } catch (error) {
      expect(error).toBeInstanceOf(IndeRunException);
      const exception = error as IndeRunException;
      expect(exception.errorClass).toBe("Internal");
      expect(exception.details?.plannerUnavailableReason).toBe("init_failed");
    }
  });
});
