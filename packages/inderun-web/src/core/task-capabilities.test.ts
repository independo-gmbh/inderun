import type { TaskRequest, TaskResult } from "@independo/inderun-contracts";
import { describe, expect, it } from "vitest";
import { IndeRun } from "./engine.js";
import { IndeRunException } from "./errors.js";
import type { HostServices } from "./host.js";
import type { ProviderAdapter, ProviderDescriptor } from "./provider.js";
import { ProviderRegistry } from "./registry.js";
import { Router } from "./router.js";

/**
 * Per-task provider capabilities through the real WASM planner (#243). The planner
 * semantics are pinned by the shared vectors in contracts/fixtures/routing/; these
 * tests check that the Web engine hands the planner the per-task declarations and
 * surfaces them, using a provider that declares only text_to_speech.
 */

const host: HostServices = {
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

const textRequest: TaskRequest = {
  schemaVersion: "1.0",
  task: { kind: "text_to_text" },
  prompt: "Hello"
};

const supports: ProviderDescriptor["supports"] = {
  run: true,
  streaming: true,
  realtime: false,
  tools: false,
  reasoningEvents: false,
  structuredOutput: false,
  multimodal: false
};

function createProvider(descriptor: ProviderDescriptor): ProviderAdapter {
  return {
    describe() {
      return descriptor;
    },
    async capabilities() {
      return {
        available: true,
        taskCapabilities: [{ kind: "text_to_speech", voices: [{ locale: "de-DE" }] }]
      };
    },
    async run(request: TaskRequest): Promise<TaskResult> {
      return {
        schemaVersion: "1.0",
        runId: request.requestId ?? "run-1",
        output: { type: "text", text: descriptor.id },
        finishReason: "stop",
        telemetry: { providerUsed: descriptor.id, totalMs: 0 }
      };
    },
    async *stream() {
      yield { type: "done", finishReason: "stop" };
    }
  } as ProviderAdapter;
}

// Sorts first by id, so only its declarations can keep it out of a text route.
const speechOnly = createProvider({
  id: "a_speech_only",
  type: "local",
  transport: "system_service",
  supports,
  cancel: "hard",
  tasks: ["text_to_speech"],
  taskCapabilities: [
    {
      kind: "text_to_speech",
      inputs: ["text"],
      interaction: { run: true, stream: false },
      cancel: "hard",
      outputs: [{ delivery: "playback" }]
    }
  ],
  privacy: { dataLeavesDevice: false }
});

const legacyText = createProvider({
  id: "z_legacy_text",
  type: "local",
  transport: "in_process",
  supports,
  cancel: "soft",
  tasks: ["text_to_text"],
  privacy: { dataLeavesDevice: false }
});

// Declares text_to_text explicitly but accepts only image input.
const imageOnlyText = createProvider({
  id: "a_image_only",
  type: "local",
  transport: "in_process",
  supports,
  cancel: "soft",
  tasks: ["text_to_text"],
  taskCapabilities: [
    {
      kind: "text_to_text",
      inputs: ["image"],
      interaction: { run: true, stream: true },
      cancel: "soft",
      outputs: [{ delivery: "inline" }]
    }
  ],
  privacy: { dataLeavesDevice: false }
});

describe("per-task provider capabilities", () => {
  it("sends text input for a text request, so a provider that only accepts images is rejected", async () => {
    const registry = new ProviderRegistry();
    registry.register(imageOnlyText);
    registry.register(legacyText);

    const selection = await new Router(registry).selectRoute(textRequest, host);

    expect(selection.provider.describe().id).toBe("z_legacy_text");
    expect(selection.routePlan.rejectedProviders).toEqual([
      expect.objectContaining({
        providerId: "a_image_only",
        reasons: [expect.objectContaining({ code: "input_not_supported" })]
      })
    ]);
  });

  it("never routes a text request to a speech-only provider, in run or stream mode", async () => {
    const registry = new ProviderRegistry();
    registry.register(speechOnly);
    registry.register(legacyText);
    const router = new Router(registry);

    for (const mode of ["run", "stream"] as const) {
      const selection = await router.selectRoute(textRequest, host, mode);
      expect(selection.provider.describe().id).toBe("z_legacy_text");
      expect(selection.routePlan.rejectedProviders).toEqual([
        expect.objectContaining({
          providerId: "a_speech_only",
          reasons: expect.arrayContaining([expect.objectContaining({ code: "task_not_supported" })])
        })
      ]);
    }
  });

  it("refuses a text request with task_not_supported when only a speech provider is registered", async () => {
    const registry = new ProviderRegistry();
    registry.register(speechOnly);

    const error = await new IndeRun(registry, host).run(textRequest).catch((caught) => caught);

    expect(error).toBeInstanceOf(IndeRunException);
    expect((error as IndeRunException).errorClass).toBe("CapabilityMismatch");
    expect((error as IndeRunException).details?.rejectedProviders).toEqual([
      expect.objectContaining({
        providerId: "a_speech_only",
        reasons: [expect.objectContaining({ code: "task_not_supported" })]
      })
    ]);
  });

  it("reports static and dynamic task capabilities from checkCapabilities()", async () => {
    const registry = new ProviderRegistry();
    registry.register(speechOnly);

    const [snapshot] = await new IndeRun(registry, host).checkCapabilities();

    expect(snapshot?.descriptor.taskCapabilities?.[0]).toMatchObject({
      kind: "text_to_speech",
      outputs: [{ delivery: "playback" }]
    });
    expect(snapshot?.capabilities.taskCapabilities).toEqual([
      { kind: "text_to_speech", voices: [{ locale: "de-DE" }] }
    ]);
  });
});
