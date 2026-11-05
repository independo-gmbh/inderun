import type { ModelPackage } from "@independo/inderun-contracts";
import { describe, expect, it } from "vitest";

import { createFixtureNeuralSpeechRuntime } from "./fixture-runtime.js";
import { type PcmChunk, NeuralSpeechRuntimeError } from "./runtime.js";

const pkg = { id: "fixture-voice", speech: { sampleRate: 24000 } } as unknown as ModelPackage;

async function collect(iterable: AsyncIterable<PcmChunk>): Promise<PcmChunk[]> {
  const chunks: PcmChunk[] = [];
  for await (const chunk of iterable) chunks.push(chunk);
  return chunks;
}

const text = "abcdefghijklmnopqrstuvwxyz12"; // 28 characters

describe("fixture neural speech runtime", () => {
  it("uses a 28 character sentence", () => {
    expect(text.length).toBe(28);
  });

  it("yields 14 chunks of 2400 frames with isLast only on the last", async () => {
    const runtime = createFixtureNeuralSpeechRuntime();
    const chunks = await collect(
      runtime.synthesize({ modelPackage: pkg, text, locale: "de-DE", voiceId: "v1" })
    );

    expect(chunks).toHaveLength(14);
    expect(chunks.every((c) => c.samples.length === 2400 && c.sampleRate === 24000)).toBe(true);
    expect(chunks.reduce((n, c) => n + c.samples.length, 0)).toBe(33600);
    expect(chunks.map((c) => c.isLast)).toEqual([...Array<boolean>(13).fill(false), true]);
  });

  it("emits a partial last chunk when the duration is not a multiple of chunkMs", async () => {
    const runtime = createFixtureNeuralSpeechRuntime({ chunkMs: 1000 });
    const chunks = await collect(
      runtime.synthesize({ modelPackage: pkg, text, locale: "de-DE", voiceId: "v1" })
    );
    expect(chunks.map((c) => c.samples.length)).toEqual([24000, 9600]);
  });

  it("keeps the 440 Hz sine phase continuous across chunks", async () => {
    const runtime = createFixtureNeuralSpeechRuntime();
    const chunks = await collect(
      runtime.synthesize({ modelPackage: pkg, text, locale: "de-DE", voiceId: "v1" })
    );
    const at = (n: number): number =>
      Math.round(0.2 * 32767 * Math.sin((2 * Math.PI * 440 * n) / 24000));
    expect(chunks[1]?.samples[0]).toBe(at(2400));
    expect(chunks[1]?.samples[5]).toBe(at(2405));
  });

  it("ends the iteration without throwing when the signal aborts", async () => {
    const runtime = createFixtureNeuralSpeechRuntime();
    const controller = new AbortController();
    const chunks: PcmChunk[] = [];
    for await (const chunk of runtime.synthesize({
      modelPackage: pkg,
      text,
      locale: "de-DE",
      voiceId: "v1",
      signal: controller.signal
    })) {
      chunks.push(chunk);
      if (chunks.length === 2) controller.abort();
    }
    expect(chunks).toHaveLength(2);
  });

  it("throws an internal error after failAfterChunks chunks", async () => {
    const runtime = createFixtureNeuralSpeechRuntime({ failAfterChunks: 1 });
    const chunks: PcmChunk[] = [];
    const error = await (async () => {
      try {
        for await (const chunk of runtime.synthesize({
          modelPackage: pkg,
          text,
          locale: "de-DE",
          voiceId: "v1"
        })) {
          chunks.push(chunk);
        }
      } catch (e) {
        return e;
      }
      return undefined;
    })();
    expect(chunks).toHaveLength(1);
    expect(error).toBeInstanceOf(NeuralSpeechRuntimeError);
    expect((error as NeuralSpeechRuntimeError).kind).toBe("internal");
  });

  it("records calls and scripted results", async () => {
    const runtime = createFixtureNeuralSpeechRuntime({
      availability: { available: false, reason: "no gpu" },
      prepareResult: { available: false, reason: "download refused" }
    });
    await collect(
      runtime.synthesize({ modelPackage: pkg, text: "Hi", locale: "en-US", voiceId: "v2" })
    );
    expect(runtime.synthesized).toEqual([{ text: "Hi", locale: "en-US", voiceId: "v2" }]);
    expect(await runtime.availability(pkg)).toEqual({ available: false, reason: "no gpu" });
    expect(await runtime.prepare(pkg)).toEqual({ available: false, reason: "download refused" });
    expect(runtime.availabilityCalls).toBe(1);
    expect(runtime.prepareCalls).toBe(1);
  });
});
