import type {
  ExecutionProvenance,
  IndeRunApi,
  ProviderCapabilitySnapshot,
  StreamEvent,
  StreamRun,
  TaskResult
} from "@independo/inderun-web";
import { IndeRunException } from "@independo/inderun-web";
import { describe, expect, it, vi } from "vitest";
import { type AppConfig, type AppDependencies, mountApp } from "./app";
import { RouteDecisionTelemetryService } from "./route-decision";

const SYSTEM_MODEL = "local.system-model.web";
const ONNX = "local.onnx.genai.web";
const CLOUD = "openai:gpt-5.2";

const CONFIG: AppConfig = {
  cloudModel: "gpt-5.2",
  proxyEndpointUrl: "/api/inderun/openai-responses",
  onDeviceModel: "onnx-community/gemma-3-1b-it-ONNX"
};

async function flush(): Promise<void> {
  for (let i = 0; i < 6; i += 1) {
    await Promise.resolve();
  }
}

const SNAPSHOTS: ProviderCapabilitySnapshot[] = [
  {
    providerId: CLOUD,
    descriptor: { id: CLOUD, type: "cloud" } as ProviderCapabilitySnapshot["descriptor"],
    capabilities: { available: true }
  },
  {
    providerId: ONNX,
    descriptor: { id: ONNX, type: "local" } as ProviderCapabilitySnapshot["descriptor"],
    capabilities: { available: true }
  },
  {
    providerId: SYSTEM_MODEL,
    descriptor: { id: SYSTEM_MODEL, type: "local" } as ProviderCapabilitySnapshot["descriptor"],
    capabilities: { available: false, reason: "Chrome 138+ required" }
  }
];

function provenance(overrides: Partial<ExecutionProvenance>): ExecutionProvenance {
  return {
    schemaVersion: "1.0",
    modelProfile: "simplify",
    locality: "unknown",
    attemptCount: 0,
    fallbackOccurred: false,
    attempts: [],
    routeRejections: [],
    ...overrides
  };
}

function taskResult(text: string, prov?: ExecutionProvenance): TaskResult {
  return {
    schemaVersion: "1.0",
    runId: "run_demo",
    output: { type: "text", text },
    finishReason: "stop",
    telemetry: { providerUsed: prov?.providerId ?? CLOUD, totalMs: 42 },
    ...(prov ? { provenance: prov } : {})
  } as TaskResult;
}

function event(sequence: number, type: string, payload: Record<string, unknown>): StreamEvent {
  return {
    schemaVersion: "1.0",
    runId: "run_stream",
    sequence,
    timestamp: sequence,
    type,
    payload
  } as unknown as StreamEvent;
}

function terminal(sequence: number, payload: Record<string, unknown>): StreamEvent {
  return event(sequence, "terminal", { schemaVersion: "1.0", runId: "run_stream", ...payload });
}

function streamRunOf(events: StreamEvent[], cancel = vi.fn()): StreamRun {
  return {
    handle: { schemaVersion: "1.0", runId: "run_stream", startedAt: 0 } as StreamRun["handle"],
    events: (async function* () {
      for (const item of events) yield item;
    })(),
    cancel
  };
}

function fakeInderun(overrides: Partial<IndeRunApi> = {}): IndeRunApi {
  return {
    run: vi.fn(),
    stream: vi.fn(),
    checkCapabilities: vi.fn().mockResolvedValue(SNAPSHOTS),
    ...overrides
  };
}

function mount(overrides: Partial<AppDependencies> = {}): HTMLElement {
  document.body.innerHTML = `<div id="app"></div>`;
  const root = document.querySelector<HTMLElement>("#app");
  if (!root) {
    throw new Error("Missing app root for test.");
  }
  mountApp(root, {
    inderun: fakeInderun(),
    config: CONFIG,
    getLastRouteDecision: vi.fn().mockReturnValue(undefined),
    isOnline: () => true,
    ...overrides
  });
  return root;
}

function choose(root: HTMLElement, name: string, value: string): void {
  const radio = root.querySelector<HTMLInputElement>(`input[name="${name}"][value="${value}"]`);
  if (!radio) {
    throw new Error(`Missing ${name} option ${value}.`);
  }
  radio.checked = true;
  radio.dispatchEvent(new Event("change"));
}

function text(root: HTMLElement, selector: string): string {
  return root.querySelector(selector)?.textContent ?? "";
}

describe("simplification flow", () => {
  it("runs generateText within the simplify profile and shows on-device provenance", async () => {
    const run = vi.fn().mockResolvedValue(
      taskResult(
        "Pay the service charges within 14 days.",
        provenance({
          providerId: SYSTEM_MODEL,
          locality: "on_device",
          attemptCount: 1,
          attempts: [{ providerId: SYSTEM_MODEL, outcome: "succeeded" }]
        })
      )
    );
    const root = mount({ inderun: fakeInderun({ run }) });
    await flush();

    root.querySelector<HTMLButtonElement>("#simplify-button")?.click();
    await flush();

    const request = run.mock.calls[0]?.[0];
    expect(request).toMatchObject({
      modelProfile: "simplify",
      constraints: { privacy: "local_preferred" }
    });
    expect(request.messages[0].role).toBe("system");
    expect(request.messages[1]).toMatchObject({ role: "user" });

    expect(text(root, "#simplify-output")).toBe("Pay the service charges within 14 days.");
    const panel = root.textContent ?? "";
    expect(panel).toContain("On this device");
    expect(panel).toContain("Browser built-in model (Prompt API)");
    expect(panel).toContain("not declared");
    expect(panel).toContain("not reported");
    expect(panel).toContain("No — 1 target attempted");
    expect(panel).not.toContain("Fixture output");
  });

  it("streams text progressively through streamText and shows cloud provenance", async () => {
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const cloudProvenance = provenance({
      providerId: CLOUD,
      locality: "cloud",
      configuredModel: "gpt-5.2",
      reportedModel: "gpt-5.2-2025-12-11",
      attemptCount: 1,
      attempts: [{ providerId: CLOUD, outcome: "succeeded" }],
      routeRejections: [
        { providerId: SYSTEM_MODEL, codes: ["streaming_not_supported"] },
        { providerId: ONNX, codes: ["streaming_not_supported"] }
      ]
    });
    const stream = vi.fn().mockResolvedValue({
      handle: { schemaVersion: "1.0", runId: "run_stream", startedAt: 0 },
      events: (async function* () {
        yield event(0, "content_delta", { text: "You must pay " });
        await gate;
        yield event(1, "content_delta", { text: "within 14 days." });
        yield terminal(2, {
          outcome: "completed",
          finalText: "You must pay within 14 days.",
          finishReason: "stop",
          provenance: cloudProvenance
        });
      })(),
      cancel: vi.fn()
    });
    const root = mount({ inderun: fakeInderun({ stream }) });
    await flush();

    choose(root, "simplify-delivery", "stream");
    root.querySelector<HTMLButtonElement>("#simplify-button")?.click();

    await vi.waitFor(() => expect(text(root, "#simplify-output")).toBe("You must pay "));
    expect(text(root, "#simplify-output")).not.toContain("within");

    release();
    await vi.waitFor(() => expect(root.textContent).toContain("Done."));
    expect(text(root, "#simplify-output")).toBe("You must pay within 14 days.");
    const panel = root.textContent ?? "";
    expect(panel).toContain("Cloud");
    expect(panel).toContain("gpt-5.2-2025-12-11");
    expect(panel).toContain("streaming_not_supported");
    expect(panel).toContain("On-device targets cannot stream yet");
    expect(panel).toContain("Sent to the cloud");
  });

  it("shows a fallback from a failed on-device attempt to the cloud", async () => {
    const run = vi.fn().mockResolvedValue(
      taskResult(
        "Plain text from the cloud.",
        provenance({
          providerId: CLOUD,
          locality: "cloud",
          configuredModel: "gpt-5.2",
          attemptCount: 2,
          fallbackOccurred: true,
          attempts: [
            { providerId: ONNX, outcome: "failed", errorClass: "Internal" },
            { providerId: CLOUD, outcome: "succeeded" }
          ],
          routeRejections: [{ providerId: SYSTEM_MODEL, codes: ["capability_unavailable"] }]
        })
      )
    );
    const root = mount({ inderun: fakeInderun({ run }) });
    await flush();

    root.querySelector<HTMLButtonElement>("#simplify-button")?.click();
    await flush();

    const panel = root.textContent ?? "";
    expect(panel).toContain("Yes — 2 targets attempted");
    expect(panel).toContain("Fell back to another target");
    expect(panel).toContain("ONNX model in the browser (Internal) failed");
    expect(panel).toContain("Browser built-in model not available");
    const attempts = root.querySelectorAll(".provenance-list")[0]?.textContent ?? "";
    expect(attempts.indexOf(ONNX)).toBeLessThan(attempts.indexOf(CLOUD));
    expect(attempts).toContain("failed");
    expect(attempts).toContain("succeeded");
  });

  it("renders a failure with its provenance and says no on-device model could run", async () => {
    const run = vi.fn().mockRejectedValue(
      new IndeRunException({
        errorClass: "CapabilityMismatch",
        message: "No eligible provider for this request.",
        provenance: provenance({
          routeRejections: [
            { providerId: SYSTEM_MODEL, codes: ["capability_unavailable"] },
            { providerId: ONNX, codes: ["capability_unavailable"] },
            { providerId: CLOUD, codes: ["privacy_constraint"] }
          ]
        })
      })
    );
    const root = mount({ inderun: fakeInderun({ run }) });
    await flush();

    choose(root, "simplify-privacy", "local_required");
    root.querySelector<HTMLButtonElement>("#simplify-button")?.click();
    await flush();

    expect(run.mock.calls[0]?.[0]).toMatchObject({ constraints: { privacy: "local_required" } });
    const panel = root.textContent ?? "";
    expect(panel).toContain("CapabilityMismatch");
    expect(panel).toContain("No on-device model could run this");
    expect(panel).toContain("Cloud not permitted");
    expect(panel).toContain("privacy_constraint");
    expect(panel).toContain("Unknown");
    expect(panel).toContain("No — no target was attempted");
  });

  it("says the cloud is unavailable when the device is offline", async () => {
    const run = vi.fn().mockRejectedValue(
      new IndeRunException({
        errorClass: "Offline",
        message: "The device is offline.",
        provenance: provenance({
          routeRejections: [
            { providerId: SYSTEM_MODEL, codes: ["capability_unavailable"] },
            { providerId: CLOUD, codes: ["offline"] }
          ]
        })
      })
    );
    const root = mount({ inderun: fakeInderun({ run }), isOnline: () => false });
    await flush();

    expect(root.textContent).toContain("Network: offline");

    choose(root, "simplify-privacy", "cloud_allowed");
    root.querySelector<HTMLButtonElement>("#simplify-button")?.click();
    await flush();

    const panel = root.textContent ?? "";
    expect(panel).toContain("Offline: the cloud is unavailable");
    expect(panel).toContain("needs a network connection");
  });

  it("labels on-device output from the fixture runtime as a fixture", async () => {
    const run = vi.fn().mockResolvedValue(
      taskResult(
        "[fixture:inderun-demo-fixture] text",
        provenance({
          providerId: ONNX,
          locality: "on_device",
          configuredModel: "inderun-demo-fixture",
          attemptCount: 1,
          attempts: [{ providerId: ONNX, outcome: "succeeded" }]
        })
      )
    );
    const root = mount({
      inderun: fakeInderun({ run }),
      config: { cloudModel: "gpt-5.2", proxyEndpointUrl: "/api/inderun/openai-responses" }
    });
    await flush();

    expect(root.textContent).toContain("echoes input; not a real model");

    root.querySelector<HTMLButtonElement>("#simplify-button")?.click();
    await flush();

    expect(root.textContent).toContain("Fixture output, not a real model");
    expect(root.textContent).toContain("ONNX in the browser (fixture runtime)");
  });

  it("stops a streaming run and keeps the partial text", async () => {
    let cancelled!: () => void;
    const cancelledSignal = new Promise<void>((resolve) => {
      cancelled = resolve;
    });
    const cancel = vi.fn(() => cancelled());
    const stream = vi.fn().mockResolvedValue({
      handle: { schemaVersion: "1.0", runId: "run_stream", startedAt: 0 },
      events: (async function* () {
        yield event(0, "content_delta", { text: "You must pay" });
        await cancelledSignal;
        yield terminal(1, {
          outcome: "cancelled",
          partialText: "You must pay",
          provenance: provenance({
            providerId: CLOUD,
            locality: "cloud",
            attemptCount: 1,
            attempts: [{ providerId: CLOUD, outcome: "cancelled" }]
          })
        });
      })(),
      cancel
    });
    const root = mount({ inderun: fakeInderun({ stream }) });
    await flush();

    choose(root, "simplify-delivery", "stream");
    root.querySelector<HTMLButtonElement>("#simplify-button")?.click();
    await vi.waitFor(() => expect(text(root, "#simplify-output")).toBe("You must pay"));

    const stop = root.querySelector<HTMLButtonElement>("#stop-button");
    expect(stop?.disabled).toBe(false);
    stop?.click();

    await vi.waitFor(() => expect(root.textContent).toContain("Stopped."));
    expect(cancel).toHaveBeenCalledTimes(1);
    expect(text(root, "#simplify-output")).toBe("You must pay");
    expect(root.querySelectorAll(".provenance-list")[0]?.textContent).toContain("cancelled");
  });

  it("does not offer Stop for a whole-result run", async () => {
    const root = mount();
    await flush();

    expect(root.querySelector("#stop-button")).toBeNull();
    choose(root, "simplify-delivery", "stream");
    expect(root.querySelector<HTMLButtonElement>("#stop-button")?.disabled).toBe(true);
  });
});

describe("advanced task API panels", () => {
  it("runs a hand-built TaskRequest through run() and renders telemetry metadata", async () => {
    const run = vi
      .fn()
      .mockResolvedValue(
        taskResult(
          "Routed through the cloud provider.",
          provenance({ providerId: CLOUD, locality: "cloud" })
        )
      );
    const root = mount({ inderun: fakeInderun({ run }) });
    await flush();

    root.querySelector<HTMLButtonElement>('[data-privacy="cloud_required"]')?.click();
    const prompt = root.querySelector<HTMLTextAreaElement>("#prompt");
    if (!prompt) {
      throw new Error("Expected prompt field after mode switch.");
    }
    prompt.value = "Test prompt";
    root.querySelector<HTMLButtonElement>("#run-button")?.click();
    await flush();

    expect(run).toHaveBeenCalledWith({
      schemaVersion: "1.0",
      task: { kind: "text_to_text" },
      prompt: "Test prompt",
      constraints: { privacy: "cloud_required" }
    });
    expect(root.textContent).toContain("Routed through the cloud provider.");
    expect(root.textContent).toContain("42 ms");
  });

  it("sends each privacy preference button's value", async () => {
    const run = vi.fn().mockResolvedValue(taskResult("[fixture:inderun-demo-fixture] Test prompt"));
    const root = mount({
      inderun: fakeInderun({ run }),
      config: { cloudModel: "gpt-5.2", proxyEndpointUrl: "/api/inderun/openai-responses" }
    });
    await flush();

    expect(root.textContent).toContain("deterministic fixture runtime");

    for (const value of ["local_required", "local_preferred", "cloud_allowed", "cloud_required"]) {
      root.querySelector<HTMLButtonElement>(`[data-privacy="${value}"]`)?.click();
      const prompt = root.querySelector<HTMLTextAreaElement>("#prompt");
      if (!prompt) {
        throw new Error("Expected prompt field.");
      }
      prompt.value = "Test prompt";
      root.querySelector<HTMLButtonElement>("#run-button")?.click();
      await flush();
      expect(run).toHaveBeenLastCalledWith(
        expect.objectContaining({ prompt: "Test prompt", constraints: { privacy: value } })
      );
    }
  });

  it("renders normalized IndeRun errors", async () => {
    const run = vi.fn().mockRejectedValue(
      new IndeRunException({
        errorClass: "AuthError",
        message: "Authentication failed.",
        runId: "run_auth",
        providerId: "openai",
        details: { originalError: { name: "TypeError", message: "Failed to fetch" } }
      })
    );
    const root = mount({ inderun: fakeInderun({ run }) });
    await flush();

    root.querySelector<HTMLButtonElement>("#run-button")?.click();
    await flush();

    expect(root.textContent).toContain("AuthError");
    expect(root.textContent).toContain("Authentication failed.");
    expect(root.textContent).toContain("TypeError: Failed to fetch");
    expect(root.textContent).toContain("run_auth");
  });

  it("renders the provider availability badges from checkCapabilities()", async () => {
    const inderun = fakeInderun();
    const root = mount({ inderun });
    await flush();

    expect(inderun.checkCapabilities).toHaveBeenCalled();
    const badges = text(root, ".badge-row");
    expect(badges).toContain(CLOUD);
    expect(badges).toContain(ONNX);
    expect(badges).toContain(SYSTEM_MODEL);
    expect(badges).toContain("Chrome 138+ required");
  });

  it("renders the routing decision captured for the advanced run", async () => {
    // Shaped exactly like the engine's `route_decided` event (packages/inderun-web/src/core/engine.ts):
    // `explanation` is the planner summary as a plain string.
    const telemetry = new RouteDecisionTelemetryService();
    telemetry.emit({
      type: "route_decided",
      runId: "run_routed",
      timestamp: 0,
      payload: {
        selectedProviderId: CLOUD,
        fallbackProviderIds: [],
        rejectedProviders: [
          {
            providerId: SYSTEM_MODEL,
            reasons: [{ code: "capability_unavailable", message: "Prompt API not available" }]
          }
        ],
        fallbackAvailable: false,
        taskKind: "text_to_text",
        modelProfile: "auto",
        constraints: { privacy: "cloud_allowed" },
        preferences: null,
        explanation: "Selected openai because cloud is allowed."
      }
    });
    const routeDecision = telemetry.getLastRouteDecision();
    const getLastRouteDecision = vi.fn().mockReturnValue(undefined);
    const run = vi.fn().mockResolvedValue(taskResult("Routed through the cloud provider."));
    const root = mount({ inderun: fakeInderun({ run }), getLastRouteDecision });
    await flush();

    getLastRouteDecision.mockReturnValue(routeDecision);
    root.querySelector<HTMLButtonElement>("#run-button")?.click();
    await flush();

    expect(root.textContent).toContain("Selected openai because cloud is allowed.");
    expect(root.textContent).toContain("Prompt API not available");
  });

  it("keeps the advanced section open across re-renders", async () => {
    const root = mount();
    await flush();

    const details = root.querySelector<HTMLDetailsElement>("#advanced");
    if (!details) {
      throw new Error("Expected advanced section.");
    }
    details.open = true;
    details.dispatchEvent(new Event("toggle"));
    root.querySelector<HTMLButtonElement>('[data-privacy="cloud_required"]')?.click();

    expect(root.querySelector<HTMLDetailsElement>("#advanced")?.open).toBe(true);
  });

  it("renders streamed text and an ordered event log, then the terminal summary", async () => {
    const stream = vi
      .fn()
      .mockResolvedValue(
        streamRunOf([
          event(0, "content_delta", { text: "Hello" }),
          event(1, "content_delta", { text: " world" }),
          terminal(2, { outcome: "completed", finalText: "Hello world" })
        ])
      );
    const root = mount({ inderun: fakeInderun({ stream }) });
    await flush();

    root.querySelector<HTMLButtonElement>("#stream-button")?.click();
    await flush();

    expect(stream).toHaveBeenCalledWith(
      expect.objectContaining({ constraints: { privacy: "cloud_allowed" } })
    );
    await vi.waitFor(() => {
      expect(text(root, "#stream-output")).toBe("Hello world");
      expect(root.textContent).toContain("Completed");
    });
    // The log shows sequence numbers, which is how a gap or a reorder is visible.
    expect(text(root, "#stream-log")).toContain("content_delta");
  });

  it("keeps the streamed text when a connectivity change re-renders mid-stream", async () => {
    let release: () => void = () => undefined;
    const held = new Promise<void>((resolve) => {
      release = resolve;
    });
    const stream = vi.fn().mockResolvedValue({
      ...streamRunOf([]),
      events: (async function* () {
        yield event(0, "content_delta", { text: "Partial" });
        await held;
        yield event(1, "content_delta", { text: " text" });
        yield terminal(2, { outcome: "completed", finalText: "Partial text" });
      })()
    });
    const root = mount({ inderun: fakeInderun({ stream }) });
    await flush();

    root.querySelector<HTMLButtonElement>("#stream-button")?.click();
    await vi.waitFor(() => expect(text(root, "#stream-output")).toBe("Partial"));

    window.dispatchEvent(new Event("offline"));
    expect(text(root, "#stream-output")).toBe("Partial");

    release();
    await vi.waitFor(() => expect(text(root, "#stream-output")).toBe("Partial text"));
  });

  it("renders a stream() rejection as a refusal rather than a terminal event", async () => {
    const stream = vi.fn().mockRejectedValue(
      new IndeRunException({
        errorClass: "CapabilityMismatch",
        message: "No provider capable of streaming was found."
      })
    );
    const root = mount({ inderun: fakeInderun({ stream }) });
    await flush();

    root.querySelector<HTMLButtonElement>("#stream-button")?.click();
    await flush();

    expect(root.textContent).toContain("stream() rejected");
    expect(root.textContent).toContain("CapabilityMismatch");
    expect(root.querySelector("#stream-output")).toBeNull();
  });
});
