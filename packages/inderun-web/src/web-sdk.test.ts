import type { ModelPackage } from "@independo/inderun-contracts";
import { describe, expect, it, vi } from "vitest";

const onnxRuntimeCloses = vi.hoisted(() => ({ count: 0 }));
vi.mock("./providers/onnx/transformers-runtime.js", async (importOriginal) => {
  const original =
    await importOriginal<typeof import("./providers/onnx/transformers-runtime.js")>();
  return {
    ...original,
    createTransformersJsRuntime: () => ({
      availability: async () => ({ available: true }),
      prepare: async () => ({ available: true }),
      generate: async () => ({ text: "ok" }),
      close: async () => {
        onnxRuntimeCloses.count += 1;
      }
    })
  };
});

import { createIndeRunWeb } from "./index.js";
import { createFixtureNeuralSpeechRuntime } from "./neural-speech.js";

function speechPackage(id: string): ModelPackage {
  return {
    id,
    format: "onnx",
    tasks: ["text_to_speech"],
    source: { sourceType: "app_managed" },
    speech: {
      pipeline: "fixture",
      sampleRate: 24000,
      graphs: { acoustic: "acoustic.onnx" },
      voices: [{ id: "v_de", name: "Fixture German", locales: ["de-DE"] }]
    }
  };
}

describe("createIndeRunWeb", () => {
  it("registers one neural speech provider per package under its composed id", async () => {
    const engine = createIndeRunWeb({
      neuralSpeech: [
        { modelPackage: speechPackage("tts-a"), runtime: createFixtureNeuralSpeechRuntime() },
        { modelPackage: speechPackage("tts-b"), runtime: createFixtureNeuralSpeechRuntime() }
      ]
    });

    const ids = (await engine.checkCapabilities()).map((snapshot) => snapshot.providerId);
    expect(ids).toEqual(["local.onnx.speech.web:tts-a", "local.onnx.speech.web:tts-b"]);
  });

  it("requires a provider configuration, naming neuralSpeech among them", () => {
    expect(() => createIndeRunWeb({})).toThrow(
      "createIndeRunWeb requires at least one provider configuration (openAI, onnx, systemModel, systemSpeech, and/or neuralSpeech)."
    );
  });

  it("factory engine close closes the ONNX provider it built", async () => {
    const before = onnxRuntimeCloses.count;
    const engine = createIndeRunWeb({
      onnx: {
        modelPackage: {
          id: "m",
          format: "onnx",
          tasks: ["text_to_text"],
          source: { sourceType: "registry", ref: "x" }
        }
      }
    });

    await engine.close();
    await engine.close();

    expect(onnxRuntimeCloses.count).toBe(before + 1);
  });

  it("factory engine close never closes an app-supplied neural speech runtime", async () => {
    const runtime = createFixtureNeuralSpeechRuntime();
    const engine = createIndeRunWeb({
      neuralSpeech: [{ modelPackage: speechPackage("tts-a"), runtime }]
    });

    await engine.close();

    expect(await runtime.availability({} as never)).toEqual({ available: true });
  });
});
