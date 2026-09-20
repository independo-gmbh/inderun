import { describe, it, expect, beforeEach } from "vitest";
import { IndeRun, ProviderRegistry, type HostServices } from "../index.js";
import { createMockHostServices, createRequest } from "../test/stream-fakes.js";

/**
 * Web-specific Mode 2 regression coverage.
 *
 * The behaviour every engine shares -- ordering, terminal outcomes, cancellation
 * races, routing rejections, fallback, provider faults and stream telemetry --
 * lives in `engine.conformance.test.ts`, driven by the cross-SDK catalog at
 * `contracts/fixtures/streaming/engine-conformance.json`. Those cases used to be
 * duplicated here and hand-copied into the Swift and Kotlin suites, which is how
 * the three drifted apart in the first place.
 *
 * What belongs in this file is anything that is a property of the Web engine
 * alone, and so has no counterpart to stay in step with.
 */
describe("IndeRun.stream()", () => {
  let registry: ProviderRegistry;
  let host: HostServices;

  beforeEach(() => {
    registry = new ProviderRegistry();
    host = createMockHostServices();
  });

  it("throws CapabilityMismatch when no provider is registered at all", async () => {
    // Distinct from the catalog's rejection cases, which all register a provider
    // and assert why it was rejected: here the planner has nothing to reject.
    const engine = new IndeRun(registry, host);
    await expect(engine.stream(createRequest())).rejects.toMatchObject({
      errorClass: "CapabilityMismatch"
    });
  });
});
