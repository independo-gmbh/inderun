import { afterEach, describe, expect, it, vi } from "vitest";
import type { SharedPlannerInput, SharedPlannerRoutePlan } from "./route-planner.js";

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
      source: "unavailable",
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
      source: "unavailable",
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
      source: "unavailable",
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
      source: "unavailable",
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

    expect(outcome).toEqual({ routePlan: plan, source: "wasm" });
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
