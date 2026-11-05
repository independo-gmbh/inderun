import type { ModelPackage } from "@independo/inderun-contracts";
import { describe, expect, it } from "vitest";

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
});
