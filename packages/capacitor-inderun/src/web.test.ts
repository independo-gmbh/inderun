import { beforeEach, describe, expect, it, vi } from "vitest";
import type { TaskResult } from "@independo/inderun-contracts";
import { IndeRunException } from "@independo/inderun-web";

const { createIndeRunWebMock } = vi.hoisted(() => ({
  createIndeRunWebMock: vi.fn()
}));

vi.mock("@independo/inderun-web", async () => {
  const actual = await vi.importActual<typeof import("@independo/inderun-web")>("@independo/inderun-web");
  return {
    ...actual,
    createIndeRunWeb: createIndeRunWebMock
  };
});

import { IndeRunCapacitor } from "./index.js";
import { IndeRunWeb } from "./web.js";

describe("IndeRunWeb", () => {
  beforeEach(() => {
    createIndeRunWebMock.mockReset();
  });

  it("delegates run() to the web SDK with the provided bootstrap options", async () => {
    const result: TaskResult = {
      schemaVersion: "1.0",
      runId: "run_123",
      finishReason: "stop",
      output: { type: "text", text: "Thin wrapper." },
      telemetry: { providerUsed: "openai", totalMs: 12 }
    };

    const runMock = vi.fn().mockResolvedValue(result);
    createIndeRunWebMock.mockReturnValue({ run: runMock });

    const plugin = new IndeRunWeb();
    const request = {
      schemaVersion: "1.0" as const,
      task: { kind: "text_to_text" as const },
      prompt: "Hello"
    };

    await expect(
      plugin.configure({
        openAI: {
          model: "gpt-5.2",
          endpointUrl: "/api/inderun/openai-responses",
          auth: "none"
        }
      })
    ).resolves.toBeUndefined();

    await expect(plugin.run(request)).resolves.toEqual(result);

    expect(createIndeRunWebMock).toHaveBeenCalledOnce();
    const webCallArg = createIndeRunWebMock.mock.calls[0][0] as Record<string, unknown>;
    // compactOpenAIOptions() must omit absent optional fields entirely (not set them to undefined)
    expect(webCallArg).toStrictEqual({
      openAI: {
        model: "gpt-5.2",
        endpointUrl: "/api/inderun/openai-responses",
        auth: "none"
      }
    });
    expect(webCallArg).not.toHaveProperty("allowDirectOpenAIEndpoint");
    expect((webCallArg["openAI"] as Record<string, unknown>)).not.toHaveProperty("authContextRef");
    expect((webCallArg["openAI"] as Record<string, unknown>)).not.toHaveProperty("timeoutMs");
    expect(runMock).toHaveBeenCalledWith(request);
  });

  it("returns a normalized contract error when web provider registration is missing", async () => {
    const plugin = new IndeRunWeb();

    await expect(
      plugin.configure()
    ).rejects.toMatchObject({
      schemaVersion: "1.0",
      errorClass: "Unavailable"
    });
  });

  it("returns a normalized contract error when run() is called before configure()", async () => {
    const plugin = new IndeRunWeb();

    await expect(
      plugin.run({
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "Hello"
      })
    ).rejects.toMatchObject({
      schemaVersion: "1.0",
      errorClass: "Unavailable"
    });
  });

  it("normalizes plugin rejection data exposed by the Capacitor facade", async () => {
    createIndeRunWebMock.mockReturnValue({
      run: vi.fn().mockRejectedValue(
        new IndeRunException({
          errorClass: "AuthError",
          message: "Missing authContextRef."
        })
      )
    });

    await IndeRunCapacitor.configure({
      openAI: {
        model: "gpt-5.2"
      }
    });

    await expect(
      IndeRunCapacitor.run({
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "Hello"
      })
    ).rejects.toMatchObject({
      schemaVersion: "1.0",
      errorClass: "AuthError",
      message: "Missing authContextRef."
    });
  });
});
