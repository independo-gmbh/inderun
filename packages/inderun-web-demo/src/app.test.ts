import type { ProviderCapabilitySnapshot } from "@independo/inderun-web";
import { IndeRunException } from "@independo/inderun-web";
import { describe, expect, it, vi } from "vitest";
import { mountApp } from "./app";
import type { RouteDecidedPayload } from "./demo-client";

async function flush(): Promise<void> {
  for (let i = 0; i < 4; i += 1) {
    await Promise.resolve();
  }
}

const SNAPSHOTS: ProviderCapabilitySnapshot[] = [
  {
    providerId: "openai",
    descriptor: { id: "openai", type: "cloud" } as ProviderCapabilitySnapshot["descriptor"],
    capabilities: { available: true }
  },
  {
    providerId: "local.onnx.genai.web",
    descriptor: {
      id: "local.onnx.genai.web",
      type: "local"
    } as ProviderCapabilitySnapshot["descriptor"],
    capabilities: { available: true }
  },
  {
    providerId: "local.system-model.web",
    descriptor: {
      id: "local.system-model.web",
      type: "local"
    } as ProviderCapabilitySnapshot["descriptor"],
    capabilities: { available: false, reason: "Chrome 138+ required" }
  }
];

describe("mountApp", () => {
  it("renders successful run output and telemetry metadata", async () => {
    document.body.innerHTML = `<div id="app"></div>`;
    const root = document.querySelector<HTMLElement>("#app");
    if (!root) {
      throw new Error("Missing app root for test.");
    }

    const runPrompt = vi.fn().mockResolvedValue({
      schemaVersion: "1.0",
      runId: "run_demo",
      output: { type: "text", text: "Routed through the cloud provider." },
      finishReason: "stop",
      telemetry: {
        providerUsed: "openai",
        totalMs: 42
      }
    });
    const checkProviderCapabilities = vi.fn().mockResolvedValue(SNAPSHOTS);
    const getLastRouteDecision = vi.fn().mockReturnValue(undefined);

    mountApp(root, {
      config: {
        model: "gemma4:latest",
        proxyEndpointUrl: "/api/inderun/openai-responses"
      },
      runPrompt,
      checkProviderCapabilities,
      getLastRouteDecision
    });
    await flush();

    root.querySelector<HTMLButtonElement>('[data-privacy="cloud_required"]')?.click();

    const cloudPrompt = root.querySelector<HTMLTextAreaElement>("#prompt");
    if (!cloudPrompt) {
      throw new Error("Expected prompt field after mode switch.");
    }
    cloudPrompt.value = "Test prompt";
    root.querySelector<HTMLButtonElement>("#run-button")?.click();
    await flush();

    expect(runPrompt).toHaveBeenCalledWith("Test prompt", "cloud_required");
    expect(root.textContent).toContain("Routed through the cloud provider.");
    expect(root.textContent).toContain("openai");
    expect(root.textContent).toContain("42 ms");
  });

  it("clicks each privacy preference button and runs with the corresponding value", async () => {
    document.body.innerHTML = `<div id="app"></div>`;
    const root = document.querySelector<HTMLElement>("#app");
    if (!root) {
      throw new Error("Missing app root for test.");
    }

    const runPrompt = vi.fn().mockResolvedValue({
      schemaVersion: "1.0",
      runId: "run_local",
      output: { type: "text", text: "[fixture:inderun-demo-fixture] Test prompt" },
      finishReason: "stop",
      telemetry: {
        providerUsed: "local.onnx.genai.web",
        totalMs: 7
      }
    });
    const checkProviderCapabilities = vi.fn().mockResolvedValue(SNAPSHOTS);
    const getLastRouteDecision = vi.fn().mockReturnValue(undefined);

    mountApp(root, {
      config: {
        model: "gemma4:latest",
        proxyEndpointUrl: "/api/inderun/openai-responses",
        onDeviceModel: "deterministic fixture runtime"
      },
      runPrompt,
      checkProviderCapabilities,
      getLastRouteDecision
    });
    await flush();

    expect(root.textContent).toContain("deterministic fixture runtime");

    const privacyValues = ["local_required", "local_preferred", "cloud_allowed", "cloud_required"];

    for (const value of privacyValues) {
      root.querySelector<HTMLButtonElement>(`[data-privacy="${value}"]`)?.click();

      const prompt = root.querySelector<HTMLTextAreaElement>("#prompt");
      if (!prompt) {
        throw new Error("Expected prompt field.");
      }
      prompt.value = "Test prompt";

      root.querySelector<HTMLButtonElement>("#run-button")?.click();
      await flush();
      expect(runPrompt).toHaveBeenCalledWith("Test prompt", value);
    }

    expect(root.textContent).toContain("local.onnx.genai.web");
  });

  it("renders normalized IndeRun errors", async () => {
    document.body.innerHTML = `<div id="app"></div>`;
    const root = document.querySelector<HTMLElement>("#app");
    if (!root) {
      throw new Error("Missing app root for test.");
    }

    const runPrompt = vi.fn().mockRejectedValue(
      new IndeRunException({
        errorClass: "AuthError",
        message: "Authentication failed.",
        runId: "run_auth",
        providerId: "openai",
        details: {
          originalError: {
            name: "TypeError",
            message: "Failed to fetch"
          }
        }
      })
    );
    const checkProviderCapabilities = vi.fn().mockResolvedValue(SNAPSHOTS);
    const getLastRouteDecision = vi.fn().mockReturnValue(undefined);

    mountApp(root, {
      config: {
        model: "gemma4:latest",
        proxyEndpointUrl: "/api/inderun/openai-responses"
      },
      runPrompt,
      checkProviderCapabilities,
      getLastRouteDecision
    });
    await flush();

    const button = root.querySelector<HTMLButtonElement>("#run-button");
    if (!button) {
      throw new Error("Expected run button.");
    }

    button.click();
    await flush();

    expect(root.textContent).toContain("AuthError");
    expect(root.textContent).toContain("Authentication failed.");
    expect(root.textContent).toContain("TypeError: Failed to fetch");
    expect(root.textContent).toContain("run_auth");
  });

  it("renders the provider availability badge panel from checkProviderCapabilities", async () => {
    document.body.innerHTML = `<div id="app"></div>`;
    const root = document.querySelector<HTMLElement>("#app");
    if (!root) {
      throw new Error("Missing app root for test.");
    }

    const runPrompt = vi.fn();
    const checkProviderCapabilities = vi.fn().mockResolvedValue(SNAPSHOTS);
    const getLastRouteDecision = vi.fn().mockReturnValue(undefined);

    mountApp(root, {
      config: { model: "gemma4:latest", proxyEndpointUrl: "/api/inderun/openai-responses" },
      runPrompt,
      checkProviderCapabilities,
      getLastRouteDecision
    });
    await flush();

    expect(checkProviderCapabilities).toHaveBeenCalled();
    expect(root.textContent).toContain("openai");
    expect(root.textContent).toContain("local.onnx.genai.web");
    expect(root.textContent).toContain("local.system-model.web");
    expect(root.textContent).toContain("Chrome 138+ required");
  });

  it("renders the routing decision panel from getLastRouteDecision after a run", async () => {
    document.body.innerHTML = `<div id="app"></div>`;
    const root = document.querySelector<HTMLElement>("#app");
    if (!root) {
      throw new Error("Missing app root for test.");
    }

    const routeDecision: RouteDecidedPayload = {
      selectedProviderId: "openai",
      fallbackProviderIds: [],
      rejectedProviders: [
        {
          providerId: "local.system-model.web",
          reasons: [{ code: "capability_unavailable", message: "Prompt API not available" }]
        }
      ],
      explanation: { summary: "Selected openai because cloud is allowed." },
      constraints: null,
      preferences: null,
      plannerSource: null,
      plannerUnavailableReason: null
    };

    const runPrompt = vi.fn().mockResolvedValue({
      schemaVersion: "1.0",
      runId: "run_demo",
      output: { type: "text", text: "Routed through the cloud provider." },
      finishReason: "stop",
      telemetry: { providerUsed: "openai", totalMs: 42 }
    });
    const checkProviderCapabilities = vi.fn().mockResolvedValue(SNAPSHOTS);
    const getLastRouteDecision = vi.fn().mockReturnValue(undefined);

    mountApp(root, {
      config: { model: "gemma4:latest", proxyEndpointUrl: "/api/inderun/openai-responses" },
      runPrompt,
      checkProviderCapabilities,
      getLastRouteDecision
    });
    await flush();

    getLastRouteDecision.mockReturnValue(routeDecision);

    root.querySelector<HTMLButtonElement>("#run-button")?.click();
    await flush();

    expect(root.textContent).toContain("Selected openai because cloud is allowed.");
    expect(root.textContent).toContain("local.system-model.web");
    expect(root.textContent).toContain("capability_unavailable");
    expect(root.textContent).toContain("Prompt API not available");
  });
});
