import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import type { ModelPackage } from "@independo/inderun-contracts";
import { afterEach, describe, expect, it, vi } from "vitest";

import { encodeSafetensors } from "../../test/safetensors-writer.js";
import { createOnnxNeuralSpeechRuntime, createUrlPackageFiles } from "./onnx-runtime.js";
import type { OnnxRuntimeWebModule, OnnxRuntimeWebTensor } from "./ort-executor.js";
import type { PcmChunk, SpeechPackageFiles } from "./runtime.js";

interface Tensor {
  shape: number[];
  data?: number[];
}
const catalog = JSON.parse(
  readFileSync(
    join(
      dirname(fileURLToPath(import.meta.url)),
      "../../../../../contracts/fixtures/speech/articulino-pipeline.json"
    ),
    "utf8"
  )
) as {
  config: Record<string, unknown>;
  voice: Record<string, Tensor>;
  cases: {
    kind: string;
    text: string;
    language: string;
    pauseMs: number;
    executor: {
      text: Record<string, Tensor>;
      dit_step: Record<string, Tensor>[];
      decoder: Record<string, Tensor>;
    };
    noise: Tensor[];
  }[];
};
const endToEnd = catalog.cases.find((c) => c.kind === "endToEnd")!;

function articulinoPackage(
  sourceType: NonNullable<ModelPackage["source"]>["sourceType"] = "app_managed"
): ModelPackage {
  return {
    id: "articulino-fixture",
    version: "1",
    format: "onnx",
    tasks: ["text_to_speech"],
    source: { sourceType },
    speech: {
      pipeline: "articulino",
      sampleRate: 24000,
      graphs: { text: "text.onnx", dit_step: "dit_step.onnx", decoder: "decoder.onnx" },
      frontend: { kind: "grapheme", assets: { config: "config.json" } },
      voices: [{ id: "v", name: "V", locales: ["de-DE", "en-US"], file: "voices/v.safetensors" }]
    }
  };
}

function memoryFiles(): SpeechPackageFiles {
  const f32 = (d: number[] = []): Float32Array => new Float32Array(d);
  const voice = encodeSafetensors(
    Object.fromEntries(
      Object.entries(catalog.voice).map(([k, t]) => [k, { shape: t.shape, data: f32(t.data) }])
    ),
    { format: "inderun.articulino.voice/1" }
  );
  const files: Record<string, Uint8Array> = {
    "config.json": new TextEncoder().encode(JSON.stringify(catalog.config)),
    "voices/v.safetensors": voice,
    "text.onnx": new TextEncoder().encode("text"),
    "dit_step.onnx": new TextEncoder().encode("dit_step"),
    "decoder.onnx": new TextEncoder().encode("decoder")
  };
  return {
    async read(file) {
      const bytes = files[file];
      if (bytes === undefined) throw new Error(`no such file: ${file}`);
      return bytes;
    }
  };
}

function scriptedModule(created: string[] = []): OnnxRuntimeWebModule {
  const steps = [...endToEnd.executor.dit_step];
  const toOut = (m: Record<string, Tensor>): Record<string, OnnxRuntimeWebTensor> =>
    Object.fromEntries(
      Object.entries(m).map(([k, t]) => [
        k,
        { type: "float32", data: new Float32Array(t.data ?? []), dims: t.shape }
      ])
    );
  class FakeTensor implements OnnxRuntimeWebTensor {
    constructor(
      readonly type: string,
      readonly data: Float32Array | BigInt64Array,
      readonly dims: readonly number[]
    ) {}
  }
  return {
    InferenceSession: {
      async create(bytes) {
        const role = new TextDecoder().decode(bytes);
        created.push(role);
        return {
          async run() {
            if (role === "text") return toOut(endToEnd.executor.text);
            if (role === "decoder") return toOut(endToEnd.executor.decoder);
            const next = steps.shift();
            if (next === undefined) throw new Error("no more dit_step outputs");
            return toOut(next);
          },
          async release() {}
        };
      }
    },
    Tensor: FakeTensor
  };
}

async function collect(iterable: AsyncIterable<PcmChunk>): Promise<PcmChunk[]> {
  const chunks: PcmChunk[] = [];
  for await (const chunk of iterable) chunks.push(chunk);
  return chunks;
}

const originalFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = originalFetch;
});

describe("onnx neural speech runtime", () => {
  it("refuses an unknown pipeline without loading the module", async () => {
    const load = vi.fn();
    const runtime = createOnnxNeuralSpeechRuntime({ files: memoryFiles(), load });
    const pkg = articulinoPackage();
    pkg.speech!.pipeline = "fixture";
    expect(await runtime.availability(pkg)).toEqual({
      available: false,
      reason: "unsupported pipeline 'fixture'"
    });
    expect(load).not.toHaveBeenCalled();
  });

  it("needs files for a package the runtime cannot resolve on its own", async () => {
    const runtime = createOnnxNeuralSpeechRuntime();
    expect(await runtime.availability(articulinoPackage("registry"))).toEqual({
      available: false,
      reason: "model source unavailable: 'registry' needs 'files'"
    });
  });

  it("prepares and synthesizes through the executor and the pipeline", async () => {
    const runtime = createOnnxNeuralSpeechRuntime({
      files: memoryFiles(),
      load: async () => scriptedModule(),
      noise: (() => {
        let next = 0;
        return () => new Float32Array(endToEnd.noise[next++]?.data ?? []);
      })(),
      pauseMs: endToEnd.pauseMs
    });
    const pkg = articulinoPackage();
    expect(await runtime.prepare(pkg)).toEqual({ available: true });
    const chunks = await collect(
      runtime.synthesize({
        modelPackage: pkg,
        text: endToEnd.text,
        locale: endToEnd.language,
        voiceId: "v"
      })
    );
    expect(chunks).toHaveLength(1);
    expect(chunks[0]?.isLast).toBe(true);
    expect(chunks[0]?.samples.length).toBeGreaterThan(0);
  });

  it("prepares a package once and treats a new version as a new package", async () => {
    const created: string[] = [];
    const runtime = createOnnxNeuralSpeechRuntime({
      files: memoryFiles(),
      load: async () => scriptedModule(created)
    });
    const pkg = articulinoPackage();
    expect(await runtime.prepare(pkg)).toEqual({ available: true });
    expect(await runtime.prepare(pkg)).toEqual({ available: true });
    expect(created).toHaveLength(3);
    expect(await runtime.prepare({ ...pkg, version: "2" })).toEqual({ available: true });
    expect(created).toHaveLength(6);
  });

  it("refuses to synthesize an unresolvable package as unavailable", async () => {
    const runtime = createOnnxNeuralSpeechRuntime();
    await expect(
      collect(
        runtime.synthesize({
          modelPackage: articulinoPackage("registry"),
          text: "a",
          locale: "de",
          voiceId: "v"
        })
      )
    ).rejects.toMatchObject({
      kind: "unavailable",
      message: "model source unavailable: 'registry' needs 'files'"
    });
  });
});

describe("url package files", () => {
  it("resolves a file against the base url", async () => {
    const fetchMock = vi.fn(async () => new Response(new Uint8Array([1, 2, 3])));
    globalThis.fetch = fetchMock as unknown as typeof fetch;
    const bytes = await createUrlPackageFiles("https://cdn.example/models/art/").read(
      "voices/v.safetensors"
    );
    expect(Array.from(bytes)).toEqual([1, 2, 3]);
    expect(String(fetchMock.mock.calls[0]?.[0])).toBe(
      "https://cdn.example/models/art/voices/v.safetensors"
    );
  });

  it("treats a directory ref without a trailing slash as a directory", async () => {
    const fetchMock = vi.fn(async () => new Response(new Uint8Array([1])));
    globalThis.fetch = fetchMock as unknown as typeof fetch;
    await createUrlPackageFiles("/models/art").read("voices/v.safetensors");
    expect(new URL(String(fetchMock.mock.calls[0]?.[0])).pathname).toBe(
      "/models/art/voices/v.safetensors"
    );
  });

  it("throws a capability error for a missing file", async () => {
    globalThis.fetch = vi.fn(
      async () => new Response("no", { status: 404 })
    ) as unknown as typeof fetch;
    await expect(
      createUrlPackageFiles("https://cdn.example/m/").read("text.onnx")
    ).rejects.toMatchObject({
      kind: "capability",
      message: "model files missing: text.onnx (HTTP 404)"
    });
  });

  it("refuses a name that leaves the package directory without fetching", async () => {
    const fetchMock = vi.fn(async () => new Response(new Uint8Array([1])));
    globalThis.fetch = fetchMock as unknown as typeof fetch;
    const files = createUrlPackageFiles("https://cdn.example/m/");
    for (const name of [
      "",
      "../x.onnx",
      "a/../../x.onnx",
      "/x.onnx",
      "https://evil.example/x.onnx",
      "//evil.example/x",
      "%2e%2e/x",
      "a/%2E%2e/x",
      ".%2E/x",
      "a%2f..%2fx",
      "a%5cx"
    ]) {
      await expect(files.read(name), name).rejects.toMatchObject({
        kind: "capability",
        message: `model file name invalid: ${name}`
      });
    }
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("reads a nested path inside the package directory", async () => {
    const fetchMock = vi.fn(async () => new Response(new Uint8Array([1])));
    globalThis.fetch = fetchMock as unknown as typeof fetch;
    await createUrlPackageFiles("https://cdn.example/models/art/").read(
      "voices/de/v%20one.safetensors"
    );
    expect(String(fetchMock.mock.calls[0]?.[0])).toBe(
      "https://cdn.example/models/art/voices/de/v%20one.safetensors"
    );
  });
});
