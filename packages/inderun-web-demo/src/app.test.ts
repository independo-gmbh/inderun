import { IndeRunException } from "@independo/inderun-web";
import { describe, expect, it, vi } from "vitest";
import { mountApp } from "./app";

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

    mountApp(root, {
      config: {
        model: "gemma4:latest",
        proxyEndpointUrl: "/api/inderun/openai-responses"
      },
      runPrompt
    });

    root.querySelector<HTMLButtonElement>("#mode-cloud")?.click();
    const cloudPrompt = root.querySelector<HTMLTextAreaElement>("#prompt");
    if (!cloudPrompt) {
      throw new Error("Expected prompt field after mode switch.");
    }

    cloudPrompt.value = "Test prompt";
    root.querySelector<HTMLButtonElement>("#run-button")?.click();
    await Promise.resolve();
    await Promise.resolve();

    expect(runPrompt).toHaveBeenCalledWith("Test prompt", "cloud");
    expect(root.textContent).toContain("Routed through the cloud provider.");
    expect(root.textContent).toContain("openai");
    expect(root.textContent).toContain("42 ms");
  });

  it("runs the on-device mode against the local provider and shows the on-device model", async () => {
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

    mountApp(root, {
      config: {
        model: "gemma4:latest",
        proxyEndpointUrl: "/api/inderun/openai-responses",
        onDeviceModel: "deterministic fixture runtime"
      },
      runPrompt
    });

    root.querySelector<HTMLButtonElement>("#mode-on-device")?.click();

    const prompt = root.querySelector<HTMLTextAreaElement>("#prompt");
    if (!prompt) {
      throw new Error("Expected prompt field.");
    }
    prompt.value = "Test prompt";

    expect(root.textContent).toContain("deterministic fixture runtime");

    root.querySelector<HTMLButtonElement>("#run-button")?.click();
    await Promise.resolve();
    await Promise.resolve();

    expect(runPrompt).toHaveBeenCalledWith("Test prompt", "on_device");
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

    mountApp(root, {
      config: {
        model: "gemma4:latest",
        proxyEndpointUrl: "/api/inderun/openai-responses"
      },
      runPrompt
    });

    const button = root.querySelector<HTMLButtonElement>("#run-button");
    if (!button) {
      throw new Error("Expected run button.");
    }

    button.click();
    await Promise.resolve();
    await Promise.resolve();

    expect(root.textContent).toContain("AuthError");
    expect(root.textContent).toContain("Authentication failed.");
    expect(root.textContent).toContain("TypeError: Failed to fetch");
    expect(root.textContent).toContain("run_auth");
  });
});
