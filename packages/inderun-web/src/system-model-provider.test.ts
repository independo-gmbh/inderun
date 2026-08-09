import type { TaskRequest } from "@independo/inderun-contracts";
import { describe, expect, it } from "vitest";
import {
  IndeRun,
  IndeRunException,
  ProviderRegistry,
  type HostServices,
  type ProviderAdapter
} from "./index.js";
import {
  DEFAULT_SYSTEM_MODEL_WEB_PROVIDER_ID,
  SystemModelWebProvider,
  type SystemModelProviderOptions
} from "./system-model.js";
import {
  SystemModelRuntimeError,
  createFixtureSystemModelRuntime,
  type SystemModelAvailabilityKind,
  type SystemModelRuntime
} from "./system-model-runtime.js";

function createHost(): HostServices {
  return {
    connectivity: {
      async isOnline() {
        return true;
      }
    },
    clock: {
      now() {
        return 1000;
      }
    }
  };
}

function createProvider(
  overrides: Partial<SystemModelProviderOptions> = {}
): SystemModelWebProvider {
  return new SystemModelWebProvider({
    runtime: createFixtureSystemModelRuntime(),
    ...overrides
  });
}

function createRequest(overrides: Partial<TaskRequest> = {}): TaskRequest {
  const request: TaskRequest = {
    schemaVersion: "1.0",
    task: { kind: "text_to_text" },
    prompt: "Say hello.",
    constraints: { privacy: "local_required" }
  };

  for (const [key, value] of Object.entries(overrides)) {
    if (value === undefined) {
      delete (request as Record<string, unknown>)[key];
    } else {
      (request as Record<string, unknown>)[key] = value;
    }
  }

  return request;
}

async function runWithProviders(request: TaskRequest, ...providers: ProviderAdapter[]) {
  const registry = new ProviderRegistry();
  for (const provider of providers) {
    registry.register(provider);
  }

  const engine = new IndeRun(registry, createHost());
  return engine.run(request);
}

/** Minimal cloud adapter used to prove strict-local policy never falls back to cloud. */
function createCloudProvider(): ProviderAdapter {
  return {
    describe: () => ({
      id: "cloud-test",
      type: "cloud",
      transport: "http",
      supports: {
        run: true,
        streaming: false,
        realtime: false,
        tools: false,
        reasoningEvents: false,
        structuredOutput: false,
        multimodal: false
      },
      cancel: "hard",
      tasks: ["text_to_text"],
      privacy: { dataLeavesDevice: true }
    }),
    capabilities: async () => ({ available: true }),
    run: async (_request, context) => ({
      schemaVersion: "1.0",
      runId: context.runId,
      output: { type: "text", text: "cloud output" },
      finishReason: "stop",
      telemetry: { providerUsed: "cloud-test", totalMs: 0 }
    })
  };
}

describe("SystemModelWebProvider descriptor", () => {
  it("describes a local, run-only, soft-cancel provider that keeps data on device", () => {
    const descriptor = createProvider().describe();

    expect(descriptor).toEqual({
      id: DEFAULT_SYSTEM_MODEL_WEB_PROVIDER_ID,
      type: "local",
      transport: "system_service",
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
      privacy: { dataLeavesDevice: false }
    });
  });

  it("supports an explicit provider id override", () => {
    const provider = createProvider({ id: "custom.system-model" });

    expect(provider.describe().id).toBe("custom.system-model");
  });

  it("defaults to the Chrome Prompt API runtime, not the deterministic fixture", async () => {
    const originalLanguageModel = Object.getOwnPropertyDescriptor(globalThis, "LanguageModel");
    Reflect.deleteProperty(globalThis, "LanguageModel");

    try {
      const provider = new SystemModelWebProvider();
      const capabilities = await provider.capabilities(createHost());

      // The fixture runtime always reports available; only the real Chrome runtime reports
      // api_missing when `LanguageModel` is undefined.
      expect(capabilities.available).toBe(false);
      expect(capabilities.reason).toContain("API missing");
    } finally {
      if (originalLanguageModel) {
        Object.defineProperty(globalThis, "LanguageModel", originalLanguageModel);
      }
    }
  });
});

describe("SystemModelWebProvider capabilities", () => {
  const cases: Array<[SystemModelAvailabilityKind, string]> = [
    ["downloadable", "downloadable"],
    ["downloading", "downloading"],
    ["model_unavailable", "unavailable"],
    ["api_missing", "API missing"],
    ["browser_unsupported", "unsupported"],
    ["feature_disabled", "feature disabled"],
    ["hardware_unsupported", "hardware"],
    ["resource_constrained", "storage or network"],
    ["unavailable", "temporarily unavailable"]
  ];

  it("is available when the runtime reports 'available'", async () => {
    await expect(createProvider().capabilities(createHost())).resolves.toEqual({
      available: true
    });
  });

  for (const [kind, reasonFragment] of cases) {
    it(`reports unavailable with a '${reasonFragment}' reason for runtime kind '${kind}'`, async () => {
      const provider = createProvider({
        runtime: createFixtureSystemModelRuntime({
          availability: { kind, reason: `${kind} reason` }
        })
      });

      const capabilities = await provider.capabilities(createHost());

      expect(capabilities.available).toBe(false);
      expect(capabilities.reason).toContain(reasonFragment);
    });
  }
});

describe("SystemModelWebProvider run", () => {
  it("executes a local run and reports the provider in telemetry", async () => {
    const result = await runWithProviders(createRequest(), createProvider());

    expect(result.output.text).toBe("[fixture:system-model] Say hello.");
    expect(result.finishReason).toBe("stop");
    expect(result.telemetry.providerUsed).toBe(DEFAULT_SYSTEM_MODEL_WEB_PROVIDER_ID);
  });

  it("is selected over a cloud provider under local_required policy", async () => {
    const result = await runWithProviders(createRequest(), createCloudProvider(), createProvider());

    expect(result.telemetry.providerUsed).toBe(DEFAULT_SYSTEM_MODEL_WEB_PROVIDER_ID);
  });

  it("does not fall back to cloud when the local provider is unavailable under local_required", async () => {
    const provider = createProvider({
      runtime: createFixtureSystemModelRuntime({
        availability: { kind: "model_unavailable", reason: "model files missing." }
      })
    });

    await expect(
      runWithProviders(createRequest(), createCloudProvider(), provider)
    ).rejects.toMatchObject({ errorClass: "CapabilityMismatch" });
  });

  it("normalizes messages when messages are supplied", async () => {
    const seen: string[] = [];
    const runtime: SystemModelRuntime = {
      async availability() {
        return { kind: "available" };
      },
      async generate(input) {
        seen.push(...input.messages.map((message) => `${message.role}:${message.content}`));
        return { text: "ok" };
      }
    };

    await runWithProviders(
      createRequest({
        prompt: undefined,
        messages: [
          { role: "system", content: "Be terse." },
          { role: "user", content: "Hi." }
        ]
      }),
      createProvider({ runtime })
    );

    expect(seen).toEqual(["system:Be terse.", "user:Hi."]);
  });

  it("passes generation controls through to the runtime", async () => {
    let received: unknown;
    const runtime: SystemModelRuntime = {
      async availability() {
        return { kind: "available" };
      },
      async generate(input) {
        received = input.generation;
        return { text: "ok" };
      }
    };

    await runWithProviders(
      createRequest({ generation: { maxOutputTokens: 32, temperature: 0.2 } }),
      createProvider({ runtime })
    );

    expect(received).toEqual({ maxOutputTokens: 32, temperature: 0.2 });
  });

  it("returns runtime-reported finish reason", async () => {
    const runtime: SystemModelRuntime = {
      async availability() {
        return { kind: "available" };
      },
      async generate() {
        return { text: "truncated", finishReason: "length" as const };
      }
    };

    const result = await runWithProviders(createRequest(), createProvider({ runtime }));

    expect(result.finishReason).toBe("length");
  });

  it("rejects a request without prompt or messages as Internal", async () => {
    await expect(
      runWithProviders(createRequest({ prompt: undefined }), createProvider())
    ).rejects.toMatchObject({ errorClass: "Internal" });
  });

  it("maps an empty model output to Internal", async () => {
    const provider = createProvider({
      runtime: createFixtureSystemModelRuntime({ respond: () => "" })
    });

    await expect(runWithProviders(createRequest(), provider)).rejects.toMatchObject({
      errorClass: "Internal"
    });
  });
});

describe("SystemModelWebProvider error mapping", () => {
  const cases: Array<[SystemModelRuntimeError["kind"], string]> = [
    ["capability", "CapabilityMismatch"],
    ["unavailable", "Unavailable"],
    ["timeout", "Timeout"],
    ["internal", "Internal"]
  ];

  for (const [kind, errorClass] of cases) {
    it(`maps runtime error kind '${kind}' to ${errorClass}`, async () => {
      const provider = createProvider({
        runtime: createFixtureSystemModelRuntime({
          failWith: new SystemModelRuntimeError(kind, `${kind} failure`)
        })
      });

      await expect(runWithProviders(createRequest(), provider)).rejects.toMatchObject({
        errorClass,
        message: `${kind} failure`,
        providerId: DEFAULT_SYSTEM_MODEL_WEB_PROVIDER_ID
      });
    });
  }

  it("maps an unexpected runtime throwable to Internal", async () => {
    const provider = createProvider({
      runtime: createFixtureSystemModelRuntime({ failWith: new Error("boom") })
    });

    const error = await runWithProviders(createRequest(), provider).catch((err: unknown) => err);

    expect(error).toBeInstanceOf(IndeRunException);
    expect((error as IndeRunException).errorClass).toBe("Internal");
  });

  it("maps a generation timeout to Timeout", async () => {
    const provider = createProvider({
      timeoutMs: 5,
      runtime: createFixtureSystemModelRuntime({ delayMs: 50 })
    });

    await expect(runWithProviders(createRequest(), provider)).rejects.toMatchObject({
      errorClass: "Timeout"
    });
  });

  it("never produces cloud-only error classes for a local runtime", async () => {
    const provider = createProvider({
      runtime: createFixtureSystemModelRuntime({
        failWith: new SystemModelRuntimeError("unavailable", "runtime initialization failed")
      })
    });

    const error = (await runWithProviders(createRequest(), provider).catch(
      (err: unknown) => err
    )) as IndeRunException;

    expect(["AuthError", "RateLimited", "Offline"]).not.toContain(error.errorClass);
  });
});
