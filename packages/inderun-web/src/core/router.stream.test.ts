import type { TaskRequest, TaskResult } from "@independo/inderun-contracts";
import { beforeEach, describe, expect, it } from "vitest";
import type { HostServices } from "./host.js";
import type { ProviderAdapter, ProviderStreamEvent } from "./provider.js";
import { ProviderRegistry } from "./registry.js";
import { Router } from "./router.js";

/**
 * These tests exercise the hand-written mirror planner in `Router`, not the Rust
 * core: the WASM module cannot be imported under vitest, so `WasmRoutePlanner`
 * reports "unavailable" and the fallback path runs. The rejection codes and the
 * stream-mode failure summary asserted here are kept verbatim in sync with
 * `rust/inderun-route-core/src/tests.rs`.
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

interface FakeProviderOptions {
  streaming: boolean;
  implementsStream?: boolean;
  streamingAvailable?: boolean;
  streamingUnavailableReason?: string;
}

function createProvider(id: string, opts: FakeProviderOptions): ProviderAdapter {
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
        cancel: "soft",
        tasks: ["text_to_text"],
        privacy: { dataLeavesDevice: false }
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

describe("Router streaming-aware selection", () => {
  let registry: ProviderRegistry;

  beforeEach(() => {
    registry = new ProviderRegistry();
  });

  it("plans a different chain for stream mode than for run mode", async () => {
    registry.register(createProvider("p_stream", { streaming: true }));
    registry.register(createProvider("p_run_only", { streaming: false }));
    const router = new Router(registry);

    const runRoute = await router.selectRoute(request, createHostServices(), "run");
    const streamRoute = await router.selectRoute(request, createHostServices(), "stream");

    expect(runRoute.routePlan.candidates.map((candidate) => candidate.providerId)).toEqual([
      "p_run_only",
      "p_stream"
    ]);
    expect(streamRoute.routePlan.candidates.map((candidate) => candidate.providerId)).toEqual([
      "p_stream"
    ]);
    expect(streamRoute.routePlan.rejectedProviders).toEqual([
      {
        providerId: "p_run_only",
        reasons: [
          {
            code: "streaming_not_supported",
            message: "Provider 'p_run_only' does not support streaming (Mode 2)."
          }
        ]
      }
    ]);
  });

  it("defaults to run mode and reports no streaming rejections there", async () => {
    registry.register(createProvider("p_run_only", { streaming: false }));
    const router = new Router(registry);

    const route = await router.selectRoute(request, createHostServices());

    expect(route.routePlan.selectedProviderId).toBe("p_run_only");
    expect(route.routePlan.rejectedProviders).toEqual([]);
  });

  it("rejects a provider that declares streaming but does not implement stream()", async () => {
    registry.register(createProvider("p_declared", { streaming: true, implementsStream: false }));
    const router = new Router(registry);

    await expect(router.selectRoute(request, createHostServices(), "stream")).rejects.toMatchObject(
      {
        errorClass: "CapabilityMismatch",
        message: "No provider capable of streaming was found for task 'text_to_text'.",
        details: {
          failureCode: "capability_mismatch",
          rejectedProviders: [
            {
              providerId: "p_declared",
              reasons: [
                {
                  code: "streaming_unavailable",
                  message:
                    "Provider 'p_declared' declares streaming but does not implement stream()."
                }
              ]
            }
          ]
        }
      }
    );
  });

  it("surfaces a provider's own dynamic streaming rejection reason", async () => {
    registry.register(
      createProvider("p_dynamic", {
        streaming: true,
        streamingAvailable: false,
        streamingUnavailableReason: "Host has no chunked HTTP capability."
      })
    );
    const router = new Router(registry);

    await expect(router.selectRoute(request, createHostServices(), "stream")).rejects.toMatchObject(
      {
        errorClass: "CapabilityMismatch",
        details: {
          rejectedProviders: [
            {
              providerId: "p_dynamic",
              reasons: [
                {
                  code: "streaming_unavailable",
                  message: "Host has no chunked HTTP capability."
                }
              ]
            }
          ]
        }
      }
    );
  });

  it("reports capability_mismatch, not offline, when an offline host has only local providers", async () => {
    registry.register(createProvider("p_local", { streaming: false }));
    const router = new Router(registry);

    await expect(
      router.selectRoute(request, createHostServices(false), "stream")
    ).rejects.toMatchObject({
      errorClass: "CapabilityMismatch",
      details: {
        failureCode: "capability_mismatch",
        rejectedProviders: [
          {
            providerId: "p_local",
            reasons: [{ code: "streaming_not_supported" }]
          }
        ]
      }
    });
  });

  it("still reports offline when a cloud provider was rejected for connectivity", async () => {
    const cloudProvider = createProvider("p_cloud", { streaming: true });
    const describeCloud = cloudProvider.describe.bind(cloudProvider);
    cloudProvider.describe = () => ({
      ...describeCloud(),
      type: "cloud",
      privacy: { dataLeavesDevice: true }
    });
    registry.register(cloudProvider);
    const router = new Router(registry);

    await expect(
      router.selectRoute(request, createHostServices(false), "stream")
    ).rejects.toMatchObject({
      errorClass: "Offline",
      details: { failureCode: "offline" }
    });
  });

  it("keeps privacy constraints in force for streaming routes", async () => {
    const cloudProvider = createProvider("p_cloud", { streaming: true });
    const describeCloud = cloudProvider.describe.bind(cloudProvider);
    cloudProvider.describe = () => ({
      ...describeCloud(),
      type: "cloud",
      privacy: { dataLeavesDevice: true }
    });
    registry.register(cloudProvider);
    const router = new Router(registry);

    const localRequired: TaskRequest = { ...request, constraints: { privacy: "local_required" } };

    await expect(
      router.selectRoute(localRequired, createHostServices(), "stream")
    ).rejects.toMatchObject({
      details: {
        rejectedProviders: [
          {
            providerId: "p_cloud",
            reasons: [
              {
                code: "privacy_constraint",
                message: "Provider 'p_cloud' does not satisfy local-required privacy."
              }
            ]
          }
        ]
      }
    });
  });
});
