import type { ModelPackage } from "@independo/inderun-contracts";
import { expect, it, vi } from "vitest";

vi.mock("@independo/inderun-route-core-wasm", () => ({
  normalizeSpeechText: () => Promise.reject(new Error("module missing"))
}));

const { createArticulinoRuntime } = await import("./articulino/runtime.js");
const { NeuralSpeechRuntimeError } = await import("./runtime.js");

it("a failing speech text module surfaces as an unavailable runtime error", async () => {
  const runtime = createArticulinoRuntime({
    executor: { load: () => Promise.resolve(), run: () => Promise.reject(new Error("unused")) },
    files: { read: () => Promise.reject(new Error("unused")) }
  });
  const pkg = {
    id: "p",
    speech: { pipeline: "articulino", frontend: { kind: "grapheme" } }
  } as ModelPackage;

  const error = await runtime.normalizeText?.(pkg, "Am 3. Mai.", "de-DE").catch((e: unknown) => e);

  expect(error).toBeInstanceOf(NeuralSpeechRuntimeError);
  expect((error as InstanceType<typeof NeuralSpeechRuntimeError>).kind).toBe("unavailable");
  expect((error as Error).message).toBe("speech text frontend unavailable: module missing");
  expect((error as InstanceType<typeof NeuralSpeechRuntimeError>).originalError).toBeInstanceOf(
    Error
  );
});

it("unsupported locales never reach the speech text module", async () => {
  const runtime = createArticulinoRuntime({
    executor: { load: () => Promise.resolve(), run: () => Promise.reject(new Error("unused")) },
    files: { read: () => Promise.reject(new Error("unused")) }
  });
  const pkg = {
    id: "p",
    speech: { pipeline: "articulino", frontend: { kind: "grapheme" } }
  } as ModelPackage;

  for (const locale of ["fr", "", "deu", "eng"]) {
    expect(await runtime.normalizeText?.(pkg, "Hello\u0000World", locale)).toBe("Hello\u0000World");
  }
});

it("English text reaches the speech text normalizer", async () => {
  const runtime = createArticulinoRuntime({
    executor: { load: () => Promise.resolve(), run: () => Promise.reject(new Error("unused")) },
    files: { read: () => Promise.reject(new Error("unused")) }
  });
  const pkg = {
    id: "p",
    speech: { pipeline: "articulino", frontend: { kind: "grapheme" } }
  } as ModelPackage;

  for (const locale of ["en", "en-US", "en-GB", "EN_us"]) {
    const error = await runtime.normalizeText?.(pkg, "at 3 pm", locale).catch((e: unknown) => e);
    expect(error, locale).toBeInstanceOf(NeuralSpeechRuntimeError);
    expect((error as Error).message).toBe("speech text frontend unavailable: module missing");
  }
});
