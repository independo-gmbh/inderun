import { describe, expect, it } from "vitest";

import {
  createOnnxWebSpeechGraphExecutor,
  type OnnxRuntimeWebModule,
  type OnnxRuntimeWebTensor
} from "./ort-executor.js";
import { NeuralSpeechRuntimeError, type SpeechPackageFiles } from "./runtime.js";

interface Recorder {
  created: { bytes: Uint8Array; options: unknown }[];
  tensors: { type: string; data: unknown; dims: readonly number[] }[];
  feeds: Record<string, OnnxRuntimeWebTensor>[];
  released: number;
  env: { wasm: Record<string, unknown> };
}

function fakeModule(
  outputs: Record<string, OnnxRuntimeWebTensor>,
  failCreate?: string
): { module: OnnxRuntimeWebModule; rec: Recorder } {
  const rec: Recorder = { created: [], tensors: [], feeds: [], released: 0, env: { wasm: {} } };
  class FakeTensor implements OnnxRuntimeWebTensor {
    constructor(
      readonly type: string,
      readonly data: Float32Array | BigInt64Array,
      readonly dims: readonly number[]
    ) {
      rec.tensors.push({ type, data, dims });
    }
  }
  const module: OnnxRuntimeWebModule = {
    InferenceSession: {
      async create(bytes, options) {
        if (failCreate !== undefined && new TextDecoder().decode(bytes) === failCreate) {
          throw new Error("bad model");
        }
        rec.created.push({ bytes, options });
        return {
          async run(feeds) {
            rec.feeds.push(feeds);
            return outputs;
          },
          async release() {
            rec.released += 1;
          }
        };
      }
    },
    Tensor: FakeTensor,
    env: rec.env
  };
  return { module, rec };
}

function files(): SpeechPackageFiles {
  return {
    async read(file) {
      return new TextEncoder().encode(file);
    }
  };
}

const graphs = { text: "text.onnx", decoder: "decoder.onnx" };

describe("onnx web speech graph executor", () => {
  it("loads the module once and sets the thread count first", async () => {
    const { module, rec } = fakeModule({});
    let loads = 0;
    const executor = createOnnxWebSpeechGraphExecutor({
      files: files(),
      threads: 3,
      load: async () => {
        loads += 1;
        return module;
      }
    });
    await executor.load(graphs);
    await executor.load({});
    expect(loads).toBe(1);
    expect(rec.env.wasm["numThreads"]).toBe(3);
    expect(rec.created.map((c) => new TextDecoder().decode(c.bytes))).toEqual([
      "text.onnx",
      "decoder.onnx"
    ]);
    expect(rec.created[0]?.options).toEqual({
      executionProviders: ["wasm"],
      graphOptimizationLevel: "all"
    });
  });

  it("does not overwrite a thread count another executor set, unless asked to", async () => {
    const { module, rec } = fakeModule({});
    const make = (threads?: number) =>
      createOnnxWebSpeechGraphExecutor({
        files: files(),
        load: async () => module,
        ...(threads === undefined ? {} : { threads })
      });
    await make(3).load(graphs);
    await make().load(graphs);
    expect(rec.env.wasm["numThreads"]).toBe(3);
    await make(2).load(graphs);
    expect(rec.env.wasm["numThreads"]).toBe(2);
  });

  it("refuses an input that is neither float32 nor int64", async () => {
    const { module } = fakeModule({});
    const executor = createOnnxWebSpeechGraphExecutor({ files: files(), load: async () => module });
    await executor.load(graphs);
    await expect(
      executor.run("text", { a: { shape: [1], data: new Int32Array([1]) as never } })
    ).rejects.toMatchObject({ kind: "internal", message: "graph input unsupported: text.a" });
  });

  it("maps typed arrays to tensor types and float outputs back with their dims", async () => {
    const { module, rec } = fakeModule({
      latents: { type: "float32", data: new Float32Array([1, 2, 3, 4]), dims: [2, 2] },
      ids: { type: "int64", data: new BigInt64Array([7n]), dims: [1] }
    });
    const executor = createOnnxWebSpeechGraphExecutor({ files: files(), load: async () => module });
    await executor.load(graphs);
    const out = await executor.run("text", {
      a: { shape: [1, 2], data: new BigInt64Array([1n, 2n]) },
      b: { shape: [2], data: new Float32Array([0.5, 1.5]) }
    });
    expect(rec.tensors.map((t) => [t.type, t.dims])).toEqual([
      ["int64", [1, 2]],
      ["float32", [2]]
    ]);
    expect(Object.keys(rec.feeds[0] ?? {})).toEqual(["a", "b"]);
    expect(out["latents"]?.shape).toEqual([2, 2]);
    expect(out["latents"]?.data).toBeInstanceOf(Float32Array);
    expect(Array.from(out["latents"]?.data ?? [])).toEqual([1, 2, 3, 4]);
    expect(out["ids"]?.data).toBeInstanceOf(BigInt64Array);
  });

  it("refuses an output type it cannot represent, naming it", async () => {
    const { module } = fakeModule({
      mask: { type: "bool", data: new Uint8Array([1]), dims: [1] }
    });
    const executor = createOnnxWebSpeechGraphExecutor({ files: files(), load: async () => module });
    await executor.load(graphs);
    await expect(executor.run("text", {})).rejects.toMatchObject({
      kind: "internal",
      message: "graph output unsupported: text.mask bool"
    });
  });

  it("refuses an unknown role", async () => {
    const { module } = fakeModule({});
    const executor = createOnnxWebSpeechGraphExecutor({ files: files(), load: async () => module });
    await executor.load(graphs);
    await expect(executor.run("voice", {})).rejects.toMatchObject({
      kind: "internal",
      message: "graph not loaded: voice"
    });
  });

  it("reports a missing onnxruntime-web as unavailable", async () => {
    const executor = createOnnxWebSpeechGraphExecutor({
      files: files(),
      load: async () => {
        throw new Error("Cannot find package");
      }
    });
    const error = await executor.load(graphs).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(NeuralSpeechRuntimeError);
    expect(error).toMatchObject({
      kind: "unavailable",
      message: "onnxruntime-web is not installed: Cannot find package"
    });
  });

  it("replaces the loaded graphs on every load, releasing the previous sessions", async () => {
    const { module, rec } = fakeModule({});
    const executor = createOnnxWebSpeechGraphExecutor({ files: files(), load: async () => module });
    await executor.load(graphs);
    await executor.load(graphs);
    expect(rec.created).toHaveLength(4);
    expect(rec.released).toBe(2);
  });

  it("names the role and the file when a graph file is missing", async () => {
    const { module } = fakeModule({});
    const missing: SpeechPackageFiles = {
      async read(file) {
        throw new NeuralSpeechRuntimeError("capability", `model files missing: ${file}`);
      }
    };
    const executor = createOnnxWebSpeechGraphExecutor({ files: missing, load: async () => module });
    await expect(executor.load(graphs)).rejects.toMatchObject({
      kind: "unavailable",
      message: "graph failed to load: text: model files missing: text.onnx"
    });
  });

  it("refuses a graph file name outside the package", async () => {
    const { module, rec } = fakeModule({});
    const executor = createOnnxWebSpeechGraphExecutor({ files: files(), load: async () => module });
    await expect(executor.load({ text: "../text.onnx" })).rejects.toMatchObject({
      kind: "unavailable",
      message: "graph failed to load: text: model file name invalid: ../text.onnx"
    });
    expect(rec.created).toHaveLength(0);
  });

  it("names the role when a graph fails to load", async () => {
    const { module } = fakeModule({}, "decoder.onnx");
    const executor = createOnnxWebSpeechGraphExecutor({ files: files(), load: async () => module });
    await expect(executor.load(graphs)).rejects.toMatchObject({
      kind: "unavailable",
      message: "graph failed to load: decoder: bad model"
    });
  });

  it("releases every session on close", async () => {
    const { module, rec } = fakeModule({});
    const executor = createOnnxWebSpeechGraphExecutor({ files: files(), load: async () => module });
    await executor.load(graphs);
    await executor.close?.();
    expect(rec.released).toBe(2);
  });
});
