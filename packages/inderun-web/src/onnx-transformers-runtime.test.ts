import type { ModelPackage } from "@independo/inderun-contracts";
import { afterEach, describe, expect, it } from "vitest";
import { OnnxRuntimeError } from "./onnx-runtime.js";
import {
  createTransformersJsRuntime,
  type TransformersModule,
  type TransformersTextGenerator
} from "./onnx-transformers-runtime.js";

interface PipelineCall {
  task: string;
  model?: string;
  options?: Record<string, unknown>;
}

interface GenerateCall {
  input: unknown;
  options?: Record<string, unknown>;
}

function createFakeModule(
  generator: TransformersTextGenerator = async () => [
    { generated_text: [{ role: "assistant", content: "hello from onnx" }] }
  ]
): { module: TransformersModule; pipelineCalls: PipelineCall[]; generateCalls: GenerateCall[] } {
  const pipelineCalls: PipelineCall[] = [];
  const generateCalls: GenerateCall[] = [];

  const module: TransformersModule = {
    env: {},
    async pipeline(task, model, options) {
      pipelineCalls.push({
        task,
        ...(model !== undefined ? { model } : {}),
        ...(options !== undefined ? { options } : {})
      });
      return async (input, generateOptions) => {
        generateCalls.push({
          input,
          ...(generateOptions !== undefined ? { options: generateOptions } : {})
        });
        return generator(input, generateOptions);
      };
    }
  };

  return { module, pipelineCalls, generateCalls };
}

function modelPackage(overrides: Partial<ModelPackage> = {}): ModelPackage {
  return {
    id: "phi-3-mini-web",
    format: "onnx",
    tasks: ["text_to_text"],
    source: { sourceType: "registry", ref: "onnx-community/Phi-3-mini" },
    ...overrides
  } as ModelPackage;
}

const originalNavigator = Object.getOwnPropertyDescriptor(globalThis, "navigator");

function setNavigator(value: unknown): void {
  Object.defineProperty(globalThis, "navigator", {
    value,
    configurable: true,
    writable: true
  });
}

afterEach(() => {
  if (originalNavigator) {
    Object.defineProperty(globalThis, "navigator", originalNavigator);
  } else {
    Reflect.deleteProperty(globalThis, "navigator");
  }
});

describe("createTransformersJsRuntime prepare", () => {
  it("reports unavailable when the optional dependency is missing", async () => {
    const runtime = createTransformersJsRuntime({
      load: async () => {
        throw new Error("Cannot find package '@huggingface/transformers'");
      }
    });

    const availability = await runtime.prepare(modelPackage());

    expect(availability.available).toBe(false);
    expect(availability.reason).toContain("runtime package unavailable");
  });

  it("reports unavailable for non-ONNX model formats", async () => {
    const { module } = createFakeModule();
    const runtime = createTransformersJsRuntime({ load: async () => module });

    const availability = await runtime.prepare(modelPackage({ format: "genai" }));

    expect(availability.available).toBe(false);
    expect(availability.reason).toContain("unsupported model format");
  });

  it("reports unavailable when a programmatic source has no createGenerator", async () => {
    const { module } = createFakeModule();
    const runtime = createTransformersJsRuntime({ load: async () => module });

    const availability = await runtime.prepare(
      modelPackage({ source: { sourceType: "programmatic" } })
    );

    expect(availability.available).toBe(false);
    expect(availability.reason).toContain("programmatic model packages require a createGenerator");
  });

  it("reports unavailable when the model package declares no source.ref", async () => {
    const { module } = createFakeModule();
    const runtime = createTransformersJsRuntime({ load: async () => module });

    const availability = await runtime.prepare(
      modelPackage({ source: { sourceType: "registry" } })
    );

    expect(availability.available).toBe(false);
    expect(availability.reason).toContain("does not declare source.ref");
  });

  it("is available for a registry-sourced ONNX package", async () => {
    const { module } = createFakeModule();
    const runtime = createTransformersJsRuntime({ load: async () => module });

    await expect(runtime.prepare(modelPackage())).resolves.toEqual({ available: true });
  });
});

describe("createTransformersJsRuntime generate", () => {
  it("builds the pipeline from the registry model ref and returns the assistant turn", async () => {
    const { module, pipelineCalls, generateCalls } = createFakeModule();
    const runtime = createTransformersJsRuntime({ load: async () => module, device: "wasm" });

    const output = await runtime.generate({
      modelPackage: modelPackage(),
      messages: [{ role: "user", content: "Hi." }],
      generation: { maxOutputTokens: 16, temperature: 0.5, topP: 0.9, stop: ["</s>"] }
    });

    expect(output.text).toBe("hello from onnx");
    expect(pipelineCalls[0]?.task).toBe("text-generation");
    expect(pipelineCalls[0]?.model).toBe("onnx-community/Phi-3-mini");
    expect(pipelineCalls[0]?.options).toMatchObject({ device: "wasm" });
    expect(generateCalls[0]?.options).toMatchObject({
      max_new_tokens: 16,
      temperature: 0.5,
      do_sample: true,
      top_p: 0.9,
      stop_strings: ["</s>"]
    });
  });

  it("defaults to a quantized dtype per device instead of fp32", async () => {
    // Transformers.js would otherwise load full fp32 weights, which fails ONNX session creation
    // with std::bad_alloc for all but tiny models.
    const wasm = createFakeModule();
    await createTransformersJsRuntime({ load: async () => wasm.module, device: "wasm" }).generate({
      modelPackage: modelPackage(),
      messages: [{ role: "user", content: "Hi." }]
    });
    expect(wasm.pipelineCalls[0]?.options).toMatchObject({ dtype: "q4" });

    const gpu = createFakeModule();
    await createTransformersJsRuntime({
      load: async () => gpu.module,
      device: "webgpu"
    }).generate({
      modelPackage: modelPackage(),
      messages: [{ role: "user", content: "Hi." }]
    });
    expect(gpu.pipelineCalls[0]?.options).toMatchObject({ dtype: "q4f16" });
  });

  it("lets an explicit dtype override the default", async () => {
    const { module, pipelineCalls } = createFakeModule();
    await createTransformersJsRuntime({
      load: async () => module,
      device: "wasm",
      dtype: "fp16"
    }).generate({
      modelPackage: modelPackage(),
      messages: [{ role: "user", content: "Hi." }]
    });

    expect(pipelineCalls[0]?.options).toMatchObject({ dtype: "fp16" });
  });

  it("maps allocation failures during model load to an unavailable runtime error", async () => {
    const { module } = createFakeModule();
    module.pipeline = async () => {
      throw new Error("Can't create a session. ERROR_CODE: 6, ERROR_MESSAGE: std::bad_alloc");
    };
    const runtime = createTransformersJsRuntime({ load: async () => module });

    const error = await runtime
      .generate({ modelPackage: modelPackage(), messages: [{ role: "user", content: "Hi." }] })
      .catch((err: unknown) => err);

    expect((error as OnnxRuntimeError).kind).toBe("unavailable");
    expect((error as OnnxRuntimeError).message).toContain("insufficient memory");
  });

  it("selects webgpu when navigator.gpu exists and wasm otherwise", async () => {
    setNavigator({ gpu: {} });
    const withGpu = createFakeModule();
    await createTransformersJsRuntime({ load: async () => withGpu.module }).generate({
      modelPackage: modelPackage(),
      messages: [{ role: "user", content: "Hi." }]
    });
    expect(withGpu.pipelineCalls[0]?.options).toMatchObject({ device: "webgpu" });

    setNavigator({});
    const withoutGpu = createFakeModule();
    await createTransformersJsRuntime({ load: async () => withoutGpu.module }).generate({
      modelPackage: modelPackage(),
      messages: [{ role: "user", content: "Hi." }]
    });
    expect(withoutGpu.pipelineCalls[0]?.options).toMatchObject({ device: "wasm" });
  });

  it("points Transformers.js at local assets for bundled sources", async () => {
    const { module } = createFakeModule();
    const runtime = createTransformersJsRuntime({
      load: async () => module,
      localModelPath: "/models/"
    });

    await runtime.generate({
      modelPackage: modelPackage({ source: { sourceType: "bundled", ref: "phi3-mini" } }),
      messages: [{ role: "user", content: "Hi." }]
    });

    expect(module.env).toEqual({
      allowLocalModels: true,
      allowRemoteModels: false,
      localModelPath: "/models/"
    });
  });

  it("uses an application-supplied generator for programmatic sources", async () => {
    const { module } = createFakeModule();
    const runtime = createTransformersJsRuntime({
      load: async () => module,
      createGenerator: async () => async () => [{ generated_text: "app supplied" }]
    });

    const output = await runtime.generate({
      modelPackage: modelPackage({ source: { sourceType: "programmatic" } }),
      messages: [{ role: "user", content: "Hi." }]
    });

    expect(output.text).toBe("app supplied");
  });

  it("maps model load failures to a capability runtime error", async () => {
    const { module } = createFakeModule();
    module.pipeline = async () => {
      throw new Error("404 model not found");
    };
    const runtime = createTransformersJsRuntime({ load: async () => module });

    const error = await runtime
      .generate({ modelPackage: modelPackage(), messages: [{ role: "user", content: "Hi." }] })
      .catch((err: unknown) => err);

    expect(error).toBeInstanceOf(OnnxRuntimeError);
    expect((error as OnnxRuntimeError).kind).toBe("capability");
  });

  it("maps generation failures to an internal runtime error", async () => {
    const { module } = createFakeModule(async () => {
      throw new Error("kernel failure");
    });
    const runtime = createTransformersJsRuntime({ load: async () => module });

    const error = await runtime
      .generate({ modelPackage: modelPackage(), messages: [{ role: "user", content: "Hi." }] })
      .catch((err: unknown) => err);

    expect((error as OnnxRuntimeError).kind).toBe("internal");
  });

  it("maps malformed pipeline output to an internal runtime error", async () => {
    const { module } = createFakeModule(async () => [{ unexpected: true }]);
    const runtime = createTransformersJsRuntime({ load: async () => module });

    const error = await runtime
      .generate({ modelPackage: modelPackage(), messages: [{ role: "user", content: "Hi." }] })
      .catch((err: unknown) => err);

    expect((error as OnnxRuntimeError).kind).toBe("internal");
    expect((error as OnnxRuntimeError).message).toContain("model output malformed");
  });

  it("rejects an already aborted generation as a timeout", async () => {
    const { module } = createFakeModule();
    const runtime = createTransformersJsRuntime({ load: async () => module });
    const controller = new AbortController();
    controller.abort();

    const error = await runtime
      .generate(
        { modelPackage: modelPackage(), messages: [{ role: "user", content: "Hi." }] },
        controller.signal
      )
      .catch((err: unknown) => err);

    expect((error as OnnxRuntimeError).kind).toBe("timeout");
  });
});
