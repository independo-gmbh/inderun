import { readFileSync } from "node:fs";
import { join } from "node:path";

import type { ModelPackage } from "@independo/inderun-contracts";
import { describe, expect, it } from "vitest";

import { createOnnxNeuralSpeechRuntime } from "./onnx-runtime.js";
import type { PcmChunk, SpeechPackageFiles } from "./runtime.js";

const modelDir = process.env["INDERUN_NEURAL_SPEECH_MODEL_DIR"];

function fsPackageFiles(dir: string): SpeechPackageFiles {
  return {
    async read(file) {
      return new Uint8Array(readFileSync(join(dir, file)));
    }
  };
}

async function collect(iterable: AsyncIterable<PcmChunk>): Promise<PcmChunk[]> {
  const chunks: PcmChunk[] = [];
  for await (const chunk of iterable) chunks.push(chunk);
  return chunks;
}

function rms(samples: Int16Array): number {
  let sum = 0;
  for (const s of samples) sum += s * s;
  return Math.sqrt(sum / samples.length);
}

describe.skipIf(!modelDir)("Articulino through onnxruntime-web (real model)", () => {
  it("speaks a German sentence", async () => {
    const pkg = JSON.parse(
      readFileSync(join(modelDir!, "model-package.json"), "utf8")
    ) as ModelPackage;
    const runtime = createOnnxNeuralSpeechRuntime({
      files: fsPackageFiles(modelDir!),
      load: () => import("onnxruntime-web")
    });
    expect(await runtime.prepare(pkg)).toEqual({ available: true });
    const started = performance.now();
    const chunks = await collect(
      runtime.synthesize({
        modelPackage: pkg,
        text: "Ich habe Hunger.",
        locale: "de-DE",
        voiceId: pkg.speech!.voices[0]!.id
      })
    );
    const seconds = chunks[0]!.samples.length / 24000;
    expect(seconds).toBeGreaterThan(1);
    expect(seconds).toBeLessThan(6);
    expect(rms(chunks[0]!.samples)).toBeGreaterThan(300);
    console.log(
      `web real model: ${seconds.toFixed(2)} s audio in ${(performance.now() - started).toFixed(0)} ms`
    );
  }, 120_000);
});
