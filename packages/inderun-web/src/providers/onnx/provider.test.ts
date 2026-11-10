import type { ModelPackage, TaskRequest } from "@independo/inderun-contracts";
import { describe, expect, it, vi } from "vitest";

const transformersCloses = vi.hoisted(() => ({ count: 0 }));
vi.mock("./transformers-runtime.js", () => ({
  createTransformersJsRuntime: () => ({
    availability: async () => ({ available: true }),
    prepare: async () => ({ available: true }),
    generate: async () => ({ text: "transformers" }),
    close: async () => {
      transformersCloses.count += 1;
    }
  })
}));

import { IndeRun, IndeRunException, prepare } from "../../index.js";
import { ProviderRegistry, type HostServices, type ProviderAdapter } from "../../provider.js";
import {
  DEFAULT_ONNX_WEB_PROVIDER_ID,
  OnnxRuntimeError,
  OnnxRuntimeWebProvider,
  createFixtureOnnxRuntime,
  type OnnxProviderOptions,
  type OnnxTextGenerationRuntime
} from "../../onnx.js";

const MODEL_PACKAGE: ModelPackage = {
  id: "phi-3-mini-web",
  format: "onnx",
  tasks: ["text_to_text"],
  runtime: { platforms: ["web"] },
  source: { sourceType: "registry", ref: "onnx-community/Phi-3-mini" }
};

function modelPackage(overrides: Partial<ModelPackage> = {}): ModelPackage {
  return { ...MODEL_PACKAGE, ...overrides } as ModelPackage;
}

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

function createProvider(overrides: Partial<OnnxProviderOptions> = {}): OnnxRuntimeWebProvider {
  return new OnnxRuntimeWebProvider({
    modelPackage: MODEL_PACKAGE,
    runtime: createFixtureOnnxRuntime(),
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

describe("OnnxRuntimeWebProvider descriptor", () => {
  it("describes a local, run-only, soft-cancel provider that keeps data on device", () => {
    const descriptor = createProvider().describe();

    expect(descriptor).toEqual({
      id: DEFAULT_ONNX_WEB_PROVIDER_ID,
      type: "local",
      model: "phi-3-mini-web",
      transport: "in_process",
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
      taskCapabilities: [
        {
          kind: "text_to_text",
          inputs: ["text"],
          interaction: { run: true, stream: false, prepare: true },
          cancel: "soft",
          outputs: [{ delivery: "inline" }]
        }
      ],
      privacy: { dataLeavesDevice: false }
    });
  });

  it("uses the model package tasks and an explicit provider id override", () => {
    const provider = createProvider({
      id: "custom.onnx",
      modelPackage: modelPackage({ tasks: ["text_to_text", "embeddings"] })
    });

    expect(provider.describe().id).toBe("custom.onnx");
    expect(provider.describe().tasks).toEqual(["text_to_text", "embeddings"]);
  });
});

describe("OnnxRuntimeWebProvider capabilities", () => {
  it("is available when the model package and runtime are usable", async () => {
    await expect(createProvider().capabilities(createHost())).resolves.toMatchObject({
      available: true
    });
  });

  it("rejects a malformed model package", async () => {
    const provider = createProvider({
      modelPackage: { format: "onnx" } as unknown as ModelPackage
    });

    const capabilities = await provider.capabilities(createHost());

    expect(capabilities.available).toBe(false);
    expect(capabilities.reason).toContain("model package malformed");
  });

  it("rejects filesystem model sources as unsupported on Web", async () => {
    const provider = createProvider({
      modelPackage: modelPackage({ source: { sourceType: "filesystem", ref: "/models/phi3" } })
    });

    const capabilities = await provider.capabilities(createHost());

    expect(capabilities.available).toBe(false);
    expect(capabilities.reason).toContain("'filesystem' model sources are unsupported on Web");
  });

  it("rejects remote model sources as deferred on Web", async () => {
    const provider = createProvider({
      modelPackage: modelPackage({
        source: { sourceType: "remote", ref: "https://models.example/phi3" }
      })
    });

    const capabilities = await provider.capabilities(createHost());

    expect(capabilities.available).toBe(false);
    expect(capabilities.reason).toContain("'remote' model sources are deferred on Web");
  });

  it("accepts every Web-supported model source type", async () => {
    for (const sourceType of ["registry", "bundled", "programmatic", "app_managed"] as const) {
      const provider = createProvider({
        modelPackage: modelPackage({ source: { sourceType, ref: "models/phi3" } })
      });

      await expect(provider.capabilities(createHost())).resolves.toMatchObject({ available: true });
    }
  });

  it("rejects a model package that does not target the web platform", async () => {
    const provider = createProvider({
      modelPackage: modelPackage({ runtime: { platforms: ["android", "apple"] } })
    });

    const capabilities = await provider.capabilities(createHost());

    expect(capabilities.available).toBe(false);
    expect(capabilities.reason).toContain("platform unsupported");
  });

  it("rejects a model package that does not declare text_to_text", async () => {
    const provider = createProvider({ modelPackage: modelPackage({ tasks: ["embeddings"] }) });

    const capabilities = await provider.capabilities(createHost());

    expect(capabilities.available).toBe(false);
    expect(capabilities.reason).toContain("unsupported task");
  });

  it("surfaces the runtime availability reason unchanged", async () => {
    const provider = createProvider({
      runtime: createFixtureOnnxRuntime({
        availability: { available: false, reason: "execution backend unavailable: no WebGPU." }
      })
    });

    await expect(provider.capabilities(createHost())).resolves.toEqual({
      available: false,
      reason: "execution backend unavailable: no WebGPU."
    });
  });
});

describe("OnnxRuntimeWebProvider run", () => {
  it("executes a local run and reports the provider in telemetry", async () => {
    const result = await runWithProviders(createRequest(), createProvider());

    expect(result.output.text).toBe("[fixture:phi-3-mini-web] Say hello.");
    expect(result.finishReason).toBe("stop");
    expect(result.telemetry.providerUsed).toBe(DEFAULT_ONNX_WEB_PROVIDER_ID);
  });

  it("is selected over a cloud provider under local_required policy", async () => {
    const result = await runWithProviders(createRequest(), createCloudProvider(), createProvider());

    expect(result.telemetry.providerUsed).toBe(DEFAULT_ONNX_WEB_PROVIDER_ID);
  });

  it("does not fall back to cloud when the local provider is unavailable under local_required", async () => {
    const provider = createProvider({
      runtime: createFixtureOnnxRuntime({
        availability: { available: false, reason: "model files missing." }
      })
    });

    await expect(
      runWithProviders(createRequest(), createCloudProvider(), provider)
    ).rejects.toMatchObject({ errorClass: "CapabilityMismatch" });
  });

  it("never retries on a cloud provider when the local attempt fails under local_required", async () => {
    // The shared Rust planner constrains the whole chain, not just the primary, so a
    // failing local_required attempt has no cloud fallback to be retried against.
    const provider = createProvider({
      runtime: createFixtureOnnxRuntime({
        failWith: new OnnxRuntimeError("internal", "generation blew up")
      })
    });

    const error = (await runWithProviders(createRequest(), createCloudProvider(), provider).catch(
      (err: unknown) => err
    )) as IndeRunException;

    expect(error.errorClass).toBe("Internal");
    expect(error.message).toBe("generation blew up");
    expect(error.details?.attemptedProviderIds).toEqual([DEFAULT_ONNX_WEB_PROVIDER_ID]);
  });

  it("normalizes the last user message when messages are supplied", async () => {
    const seen: string[] = [];
    const runtime: OnnxTextGenerationRuntime = {
      async availability() {
        return { available: true };
      },
      async prepare() {
        return { available: true };
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
    const runtime: OnnxTextGenerationRuntime = {
      async availability() {
        return { available: true };
      },
      async prepare() {
        return { available: true };
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

  it("returns runtime-reported finish reason and usage", async () => {
    const runtime: OnnxTextGenerationRuntime = {
      async availability() {
        return { available: true };
      },
      async prepare() {
        return { available: true };
      },
      async generate() {
        return {
          text: "truncated",
          finishReason: "length" as const,
          usage: { inputTokens: 4, outputTokens: 8 }
        };
      }
    };

    const result = await runWithProviders(createRequest(), createProvider({ runtime }));

    expect(result.finishReason).toBe("length");
    expect(result.usage).toEqual({ inputTokens: 4, outputTokens: 8 });
  });

  it("rejects a request without prompt or messages as Internal", async () => {
    await expect(
      runWithProviders(createRequest({ prompt: undefined }), createProvider())
    ).rejects.toMatchObject({ errorClass: "Internal" });
  });

  it("maps an empty model output to Internal", async () => {
    const provider = createProvider({
      runtime: createFixtureOnnxRuntime({ respond: () => "" })
    });

    await expect(runWithProviders(createRequest(), provider)).rejects.toMatchObject({
      errorClass: "Internal"
    });
  });
});

describe("OnnxRuntimeWebProvider error mapping", () => {
  const cases: Array<[OnnxRuntimeError["kind"], string]> = [
    ["capability", "CapabilityMismatch"],
    ["unavailable", "Unavailable"],
    ["timeout", "Timeout"],
    ["internal", "Internal"]
  ];

  for (const [kind, errorClass] of cases) {
    it(`maps runtime error kind '${kind}' to ${errorClass}`, async () => {
      const provider = createProvider({
        runtime: createFixtureOnnxRuntime({
          failWith: new OnnxRuntimeError(kind, `${kind} failure`)
        })
      });

      await expect(runWithProviders(createRequest(), provider)).rejects.toMatchObject({
        errorClass,
        message: `${kind} failure`,
        providerId: DEFAULT_ONNX_WEB_PROVIDER_ID
      });
    });
  }

  it("maps an unexpected runtime throwable to Internal", async () => {
    const provider = createProvider({
      runtime: createFixtureOnnxRuntime({ failWith: new Error("boom") })
    });

    const error = await runWithProviders(createRequest(), provider).catch((err: unknown) => err);

    expect(error).toBeInstanceOf(IndeRunException);
    expect((error as IndeRunException).errorClass).toBe("Internal");
  });

  it("maps a generation timeout to Timeout", async () => {
    const provider = createProvider({
      timeoutMs: 5,
      runtime: createFixtureOnnxRuntime({ delayMs: 50 })
    });

    await expect(runWithProviders(createRequest(), provider)).rejects.toMatchObject({
      errorClass: "Timeout"
    });
  });

  it("never produces cloud-only error classes for a local runtime", async () => {
    const provider = createProvider({
      runtime: createFixtureOnnxRuntime({
        failWith: new OnnxRuntimeError("unavailable", "runtime initialization failed")
      })
    });

    const error = (await runWithProviders(createRequest(), provider).catch(
      (err: unknown) => err
    )) as IndeRunException;

    expect(["AuthError", "RateLimited", "Offline"]).not.toContain(error.errorClass);
  });
});

describe("OnnxRuntimeWebProvider loading", () => {
  function countingRuntime(
    loadResult: { available: boolean; reason?: string } = { available: true }
  ) {
    const counts = { loads: 0 };
    const runtime = {
      ...createFixtureOnnxRuntime(),
      prepare: async () => {
        counts.loads += 1;
        return loadResult;
      }
    };
    return { runtime, counts };
  }

  function engine(...providers: ProviderAdapter[]): IndeRun {
    const registry = new ProviderRegistry();
    for (const provider of providers) registry.register(provider);
    return new IndeRun(registry, createHost());
  }

  it("never loads the model for a capability check, and reports it cold", async () => {
    const { runtime, counts } = countingRuntime();

    const capabilities = await createProvider({ runtime }).capabilities(createHost());

    expect(counts.loads).toBe(0);
    expect(capabilities).toMatchObject({
      available: true,
      taskCapabilities: [{ kind: "text_to_text", readiness: "cold" }]
    });
  });

  it("loads once for prepare, and is ready after it", async () => {
    const { runtime, counts } = countingRuntime();
    const provider = createProvider({ runtime });
    const inderun = engine(provider);

    const { items } = await (await prepare(inderun)).result;
    await inderun.run(createRequest());

    expect(items).toMatchObject([{ status: "prepared" }]);
    expect(counts.loads).toBe(1);
    await expect(provider.capabilities(createHost())).resolves.toEqual({ available: true });
  });

  it("loads on the first run when nobody prepared it", async () => {
    const { runtime, counts } = countingRuntime();
    const inderun = engine(createProvider({ runtime }));

    await inderun.run(createRequest());
    await inderun.run(createRequest());

    expect(counts.loads).toBe(1);
  });

  it("remembers a failed load, so routing stops choosing the provider", async () => {
    const { runtime, counts } = countingRuntime({ available: false, reason: "model corrupt" });
    const provider = createProvider({ runtime });
    const inderun = engine(provider);

    await expect(inderun.run(createRequest())).rejects.toBeInstanceOf(IndeRunException);
    await expect(inderun.run(createRequest())).rejects.toBeInstanceOf(IndeRunException);

    expect(counts.loads).toBe(1);
    await expect(provider.capabilities(createHost())).resolves.toEqual({
      available: false,
      reason: "model corrupt"
    });
  });

  it("falls back when the model fails to load", async () => {
    const { runtime } = countingRuntime({ available: false, reason: "model corrupt" });
    const broken = createProvider({ runtime, id: "broken" });
    const healthy = createProvider({ id: "healthy" });

    const result = await engine(broken, healthy).run(createRequest());

    expect(result.telemetry?.providerUsed).toBe("healthy");
  });
});

describe("OnnxRuntimeWebProvider runtime descriptors", () => {
  it("builds the fixture runtime from a JSON descriptor", async () => {
    const options = JSON.parse(
      JSON.stringify({ modelPackage: MODEL_PACKAGE, runtime: { kind: "fixture" } })
    ) as OnnxProviderOptions;

    const result = await runWithProviders(createRequest(), new OnnxRuntimeWebProvider(options));

    expect(result.output).toEqual({ type: "text", text: "[fixture:phi-3-mini-web] Say hello." });
  });

  it("treats a null runtime like an absent one", () => {
    const options = JSON.parse(
      JSON.stringify({ modelPackage: MODEL_PACKAGE, runtime: null })
    ) as OnnxProviderOptions;

    expect(() => new OnnxRuntimeWebProvider(options)).not.toThrow();
  });

  it("rejects an unknown runtime kind at construction", () => {
    const build = () =>
      new OnnxRuntimeWebProvider({
        modelPackage: MODEL_PACKAGE,
        runtime: { kind: "fixtures" } as never
      });

    expect(build).toThrow(TypeError);
    expect(build).toThrow(/fixtures/);
  });

  it("closes a descriptor-built runtime and never an injected one", async () => {
    const before = transformersCloses.count;
    await new OnnxRuntimeWebProvider({
      modelPackage: MODEL_PACKAGE,
      runtime: { kind: "transformers_js" }
    }).close();
    expect(transformersCloses.count).toBe(before + 1);

    const injected = createFixtureOnnxRuntime();
    const close = vi.fn(async () => undefined);
    await new OnnxRuntimeWebProvider({
      modelPackage: MODEL_PACKAGE,
      runtime: { ...injected, close }
    }).close();
    expect(close).not.toHaveBeenCalled();
  });
});
