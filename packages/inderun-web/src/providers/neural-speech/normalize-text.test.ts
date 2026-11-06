import type { ModelPackage } from "@independo/inderun-contracts";
import { describe, expect, it } from "vitest";

import { createArticulinoRuntime } from "./articulino/runtime.js";
import { createOnnxNeuralSpeechRuntime } from "./onnx-runtime.js";
import type { SpeechGraphExecutor, SpeechPackageFiles } from "./runtime.js";

function pkg(pipeline: string, kind: string): ModelPackage {
  return {
    id: "p",
    version: "1",
    format: "onnx",
    tasks: ["text_to_speech"],
    source: { sourceType: "app_managed", ref: "https://example.test/p/" },
    speech: {
      pipeline,
      sampleRate: 24000,
      graphs: {},
      frontend: { kind, assets: { config: "config.json" } },
      voices: [{ id: "v", name: "V", locales: ["de-DE"] }]
    }
  } as ModelPackage;
}

const files: SpeechPackageFiles = { read: () => Promise.reject(new Error("unused")) };
const executor: SpeechGraphExecutor = {
  load: () => Promise.resolve(),
  run: () => Promise.reject(new Error("unused"))
};

describe("normalizeText hooks", () => {
  it("Articulino normalizes a grapheme package", async () => {
    const runtime = createArticulinoRuntime({ executor, files });
    expect(
      await runtime.normalizeText?.(pkg("articulino", "grapheme"), "Am 3. Mai.", "de-DE")
    ).toBe("Am dritten Mai.");
  });

  it("Articulino returns the text unchanged for another frontend", async () => {
    const runtime = createArticulinoRuntime({ executor, files });
    expect(await runtime.normalizeText?.(pkg("articulino", "phoneme"), "Am 3. Mai.", "de-DE")).toBe(
      "Am 3. Mai."
    );
  });

  it("the composed ORT runtime forwards for articulino", async () => {
    const runtime = createOnnxNeuralSpeechRuntime({ files });
    expect(
      await runtime.normalizeText?.(pkg("articulino", "grapheme"), "Am 3. Mai.", "de-DE")
    ).toBe("Am dritten Mai.");
  });

  it("the composed ORT runtime leaves other pipelines unchanged", async () => {
    const runtime = createOnnxNeuralSpeechRuntime({ files });
    expect(await runtime.normalizeText?.(pkg("other", "grapheme"), "Am 3. Mai.", "de-DE")).toBe(
      "Am 3. Mai."
    );
  });
});
