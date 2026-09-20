import type { TaskRequest, TaskResult } from "@independo/inderun-contracts";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { HostServices } from "./host.js";
import type { ProviderAdapter, ProviderDescriptor, ProviderStreamEvent } from "./provider.js";
import {
  buildSharedPlannerInput,
  collectProviderRuntimeSnapshots,
  type SharedPlannerInput,
  type SharedPlannerRoutePlan
} from "./route-planner.js";

const WASM_SPECIFIER = "@independo/inderun-route-core-wasm";

const sampleInput: SharedPlannerInput = {
  task: { kind: "text_to_text" },
  constraints: { privacy: "cloud_allowed", cloud: "allowed", networkOnline: true },
  preferences: { optimizeFor: "balanced" },
  providers: []
};

async function loadPlanner() {
  const { WasmRoutePlanner } = await import("./route-planner.js");
  return new WasmRoutePlanner();
}

/**
 * These tests mock the WASM package by its real, literal specifier. That only
 * works because `route-planner.ts` imports it via a static literal — if the
 * specifier ever regressed to a variable (see #109), `vi.doMock` would no
 * longer intercept it and these tests would start hitting the real package.
 */
describe("WasmRoutePlanner", () => {
  afterEach(() => {
    vi.doUnmock(WASM_SPECIFIER);
    vi.resetModules();
    vi.restoreAllMocks();
  });

  it("reports import_failed and warns once when the module fails to load", async () => {
    vi.doMock(WASM_SPECIFIER, () => {
      throw new Error("module load boom");
    });
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => undefined);

    const planner = await loadPlanner();
    const outcome = await planner.planRoute(sampleInput);

    expect(outcome).toEqual({
      routePlan: null,
      unavailableReason: "import_failed"
    });
    expect(warnSpy).toHaveBeenCalledTimes(1);
  });

  it("reports invalid_module_shape when planRouteJson is missing", async () => {
    vi.doMock(WASM_SPECIFIER, () => ({ initSharedCore: undefined, planRouteJson: undefined }));

    const planner = await loadPlanner();
    const outcome = await planner.planRoute(sampleInput);

    expect(outcome).toEqual({
      routePlan: null,
      unavailableReason: "invalid_module_shape"
    });
  });

  it("reports init_failed when initSharedCore rejects", async () => {
    vi.doMock(WASM_SPECIFIER, () => ({
      initSharedCore: () => Promise.reject(new Error("init boom")),
      planRouteJson: () => "{}"
    }));

    const planner = await loadPlanner();
    const outcome = await planner.planRoute(sampleInput);

    expect(outcome).toEqual({
      routePlan: null,
      unavailableReason: "init_failed"
    });
  });

  it("reports plan_failed when planRouteJson throws", async () => {
    vi.doMock(WASM_SPECIFIER, () => ({
      initSharedCore: undefined,
      planRouteJson: () => {
        throw new Error("plan boom");
      }
    }));

    const planner = await loadPlanner();
    const outcome = await planner.planRoute(sampleInput);

    expect(outcome).toEqual({
      routePlan: null,
      unavailableReason: "plan_failed"
    });
  });

  it("returns the parsed route plan on success", async () => {
    const plan: SharedPlannerRoutePlan = {
      selectedProviderId: "provider-a",
      fallbackProviderIds: [],
      candidates: [{ providerId: "provider-a", order: 0 }],
      rejectedProviders: [],
      failureCode: null,
      explanation: { summary: "ok" }
    };
    vi.doMock(WASM_SPECIFIER, () => ({
      initSharedCore: undefined,
      planRouteJson: () => JSON.stringify(plan)
    }));

    const planner = await loadPlanner();
    const outcome = await planner.planRoute(sampleInput);

    expect(outcome).toEqual({ routePlan: plan });
  });

  it("warns only once across repeated calls after a load failure", async () => {
    vi.doMock(WASM_SPECIFIER, () => {
      throw new Error("module load boom");
    });
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => undefined);

    const planner = await loadPlanner();
    await planner.planRoute(sampleInput);
    await planner.planRoute(sampleInput);

    expect(warnSpy).toHaveBeenCalledTimes(1);
  });
});

function createHostServices(): HostServices {
  return {
    connectivity: {
      async isOnline() {
        return true;
      }
    },
    clock: {
      now() {
        return 0;
      }
    }
  };
}

interface FakeProviderOptions {
  streaming: boolean;
  implementsStream?: boolean;
  cancel?: ProviderDescriptor["cancel"];
  streamingAvailable?: boolean;
  streamingUnavailableReason?: string;
  cancellationAvailable?: boolean;
}

function createFakeProvider(id: string, opts: FakeProviderOptions): ProviderAdapter {
  const provider: ProviderAdapter = {
    describe() {
      return {
        id,
        type: "local",
        transport: "in_process",
        supports: {
          run: true,
          streaming: opts.streaming,
          realtime: false,
          tools: false,
          reasoningEvents: false,
          structuredOutput: false,
          multimodal: false
        },
        cancel: opts.cancel ?? "soft",
        tasks: ["text_to_text"]
      };
    },
    async capabilities() {
      return {
        available: true,
        ...(opts.streamingAvailable !== undefined
          ? { streamingAvailable: opts.streamingAvailable }
          : {}),
        ...(opts.streamingUnavailableReason !== undefined
          ? { streamingUnavailableReason: opts.streamingUnavailableReason }
          : {}),
        ...(opts.cancellationAvailable !== undefined
          ? { cancellationAvailable: opts.cancellationAvailable }
          : {})
      };
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

  if (opts.implementsStream ?? opts.streaming) {
    // eslint-disable-next-line require-yield
    provider.stream = async function* (): AsyncGenerator<ProviderStreamEvent> {
      return;
    };
  }

  return provider;
}

const request: TaskRequest = {
  schemaVersion: "1.0",
  task: { kind: "text_to_text" },
  prompt: "test prompt"
};

describe("planner input projection", () => {
  it("carries static streaming and cancellation declarations into the planner input", async () => {
    const snapshots = await collectProviderRuntimeSnapshots(
      [createFakeProvider("p1", { streaming: true, cancel: "hard" })],
      createHostServices()
    );

    expect(snapshots[0]!.descriptor).toMatchObject({
      id: "p1",
      supports: { run: true, streaming: true },
      cancel: "hard"
    });
    expect(snapshots[0]!.capabilities).toMatchObject({
      available: true,
      streamingAvailable: true
    });
  });

  it("treats a declared-but-unimplemented stream() as streaming unavailable", async () => {
    const snapshots = await collectProviderRuntimeSnapshots(
      [createFakeProvider("p1", { streaming: true, implementsStream: false })],
      createHostServices()
    );

    expect(snapshots[0]!.capabilities.streamingAvailable).toBe(false);
    expect(snapshots[0]!.capabilities.streamingUnavailableReason).toContain(
      "does not implement stream()"
    );
  });

  it("lets a provider revoke streaming dynamically with its own reason", async () => {
    const snapshots = await collectProviderRuntimeSnapshots(
      [
        createFakeProvider("p1", {
          streaming: true,
          streamingAvailable: false,
          streamingUnavailableReason: "Host has no chunked HTTP capability."
        })
      ],
      createHostServices()
    );

    expect(snapshots[0]!.capabilities.streamingAvailable).toBe(false);
    expect(snapshots[0]!.capabilities.streamingUnavailableReason).toBe(
      "Host has no chunked HTTP capability."
    );
  });

  it("passes the requested interaction mode through, defaulting to run", async () => {
    const snapshots = await collectProviderRuntimeSnapshots(
      [createFakeProvider("p1", { streaming: false })],
      createHostServices()
    );

    expect(buildSharedPlannerInput(request, snapshots, true).interactionMode).toBe("run");
    expect(buildSharedPlannerInput(request, snapshots, true, "stream").interactionMode).toBe(
      "stream"
    );
  });
});
