import { describe, expect, it, vi } from "vitest";
import {
  createBrowserSpeechRuntime,
  type BrowserSpeechSynthesis,
  type BrowserSpeechUtterance,
  type BrowserSpeechVoice
} from "./browser-runtime.js";
import { SystemSpeechRuntimeError } from "./runtime.js";

const de: BrowserSpeechVoice = { voiceURI: "de", lang: "de-DE", localService: false };
const en: BrowserSpeechVoice = { voiceURI: "en", lang: "en-US", localService: true };

function fakeSynthesis(voices: BrowserSpeechVoice[] = [de, en]) {
  const listeners = new Set<() => void>();
  const state = { voices };
  const spoken: BrowserSpeechUtterance[] = [];
  const synthesis: BrowserSpeechSynthesis = {
    getVoices: () => state.voices,
    speak: (utterance) => spoken.push(utterance),
    cancel: vi.fn(() => {
      for (const utterance of spoken) utterance.onerror?.({ error: "canceled" });
    }),
    addEventListener: (_type, listener) => listeners.add(listener),
    removeEventListener: (_type, listener) => listeners.delete(listener)
  };
  return { synthesis, spoken, state, listeners };
}

function runtimeOver(fake: ReturnType<typeof fakeSynthesis>, voiceWaitMs = 20, idlePollMs = 1) {
  return createBrowserSpeechRuntime({
    synthesis: () => fake.synthesis,
    createUtterance: () =>
      ({
        lang: "",
        voice: null,
        onstart: null,
        onend: null,
        onerror: null
      }) as BrowserSpeechUtterance,
    voiceWaitMs,
    idlePollMs
  });
}

describe("createBrowserSpeechRuntime", () => {
  it("reports a missing API without touching it", () => {
    const runtime = createBrowserSpeechRuntime({ synthesis: () => undefined });

    expect(runtime.availability()).toMatchObject({ kind: "api_missing" });
  });

  it("reports no voices when the API is missing", async () => {
    const runtime = createBrowserSpeechRuntime({ synthesis: () => undefined });

    await expect(runtime.voices()).resolves.toEqual([]);
  });

  it("lists what the browser calls local first", async () => {
    const voices = await runtimeOver(fakeSynthesis()).voices();

    expect(voices.map((voice) => voice.uri)).toEqual(["en", "de"]);
  });

  it("lists the browser's default ahead of its equals, with its name", async () => {
    const voices = await runtimeOver(
      fakeSynthesis([
        { voiceURI: "a", name: "A", lang: "de-DE", localService: true },
        { voiceURI: "b", name: "B", lang: "de-DE", localService: true, default: true }
      ])
    ).voices();

    expect(voices).toEqual([
      { uri: "b", name: "B", locale: "de-DE", localService: true },
      { uri: "a", name: "A", locale: "de-DE", localService: true }
    ]);
  });

  it("waits for a delayed voiceschanged", async () => {
    const fake = fakeSynthesis([]);
    const pending = runtimeOver(fake, 1000).voices();

    fake.state.voices = [en];
    for (const listener of fake.listeners) listener();

    await expect(pending).resolves.toHaveLength(1);
    expect(fake.listeners.size).toBe(0);
  });

  it("stops waiting when voiceschanged never fires", async () => {
    const fake = fakeSynthesis([]);

    await expect(runtimeOver(fake).voices()).resolves.toEqual([]);
    expect(fake.listeners.size).toBe(0);
  });

  it("waits for voices only once, because every request probes them", async () => {
    const fake = fakeSynthesis([]);
    const runtime = runtimeOver(fake);
    await runtime.voices();
    const wait = vi.spyOn(fake.synthesis, "addEventListener");

    await expect(runtime.voices()).resolves.toEqual([]);
    expect(wait).not.toHaveBeenCalled();
  });

  it("fails an utterance that never starts", async () => {
    const fake = fakeSynthesis();
    const runtime = createBrowserSpeechRuntime({
      synthesis: () => fake.synthesis,
      createUtterance: () =>
        ({
          lang: "",
          voice: null,
          onstart: null,
          onend: null,
          onerror: null
        }) as BrowserSpeechUtterance,
      startTimeoutMs: 5
    });

    await expect(runtime.speak({ text: "Hallo", locale: "de" })).rejects.toBeInstanceOf(
      SystemSpeechRuntimeError
    );
  });

  it("waits for a list that arrives late, also without voiceschanged", async () => {
    const fake = fakeSynthesis([]);
    const runtime = runtimeOver(fake);
    const listed = runtime.whenVoicesListed();

    fake.state.voices = [en];

    await expect(listed).resolves.toBe(true);
    expect(fake.listeners.size).toBe(0);
  });

  it("stops waiting for voices at its bound and on abort", async () => {
    const fake = fakeSynthesis([]);
    const bounded = createBrowserSpeechRuntime({
      synthesis: () => fake.synthesis,
      voiceLoadMs: 5,
      idlePollMs: 1
    });
    await expect(bounded.whenVoicesListed()).resolves.toBe(false);

    const controller = new AbortController();
    const waiting = runtimeOver(fake).whenVoicesListed(controller.signal);
    controller.abort();
    await expect(waiting).resolves.toBe(false);
  });

  it("waits until the shared queue is idle", async () => {
    const fake = fakeSynthesis();
    fake.synthesis.speaking = true;
    fake.synthesis.pending = true;
    const idle = vi.fn();
    const waiting = runtimeOver(fake, 20, 1).whenIdle().then(idle);

    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(idle).not.toHaveBeenCalled();
    fake.synthesis.speaking = false;
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(idle).not.toHaveBeenCalled();
    fake.synthesis.pending = false;

    await waiting;
    expect(idle).toHaveBeenCalled();
  });

  it("stops waiting for the queue on abort, leaving it alone", async () => {
    const fake = fakeSynthesis();
    fake.synthesis.speaking = true;
    const controller = new AbortController();
    const waiting = runtimeOver(fake).whenIdle(controller.signal);

    controller.abort();

    await waiting;
    expect(fake.synthesis.cancel).not.toHaveBeenCalled();
  });

  it("refuses a voice that is gone instead of letting the browser pick one", async () => {
    const fake = fakeSynthesis([en]);

    await expect(
      runtimeOver(fake).speak({
        text: "Hallo",
        locale: "de-DE",
        voice: { uri: "de", locale: "de-DE" }
      })
    ).rejects.toBeInstanceOf(SystemSpeechRuntimeError);
    expect(fake.spoken).toEqual([]);
  });

  it("speaks the chosen voice and reports the time between start and end", async () => {
    const fake = fakeSynthesis();
    const pending = runtimeOver(fake).speak({
      text: "Hallo",
      locale: "de-DE",
      voice: { uri: "de", locale: "de-DE" }
    });

    const utterance = fake.spoken[0]!;
    expect(utterance.lang).toBe("de-DE");
    expect(utterance.voice).toBe(de);
    utterance.onstart?.();
    utterance.onend?.();

    await expect(pending).resolves.toMatchObject({ durationMs: expect.any(Number) });
  });

  it("reports the first word boundary as first audio, measured from the hand-over", async () => {
    const now = vi.spyOn(Date, "now").mockReturnValue(1000);
    try {
      const fake = fakeSynthesis();
      const pending = runtimeOver(fake).speak({ text: "Hallo Welt", locale: "de-DE" });
      const utterance = fake.spoken[0]!;
      now.mockReturnValue(1100);
      utterance.onstart?.();
      now.mockReturnValue(1240);
      utterance.onboundary?.();
      now.mockReturnValue(1500);
      utterance.onboundary?.();
      utterance.onend?.();

      await expect(pending).resolves.toEqual({ durationMs: 400, firstAudioMs: 240 });
    } finally {
      now.mockRestore();
    }
  });

  it("reports no first audio when the browser sends no word boundary", async () => {
    const fake = fakeSynthesis();
    const pending = runtimeOver(fake).speak({ text: "Hallo", locale: "de-DE" });
    const utterance = fake.spoken[0]!;
    utterance.onstart?.();
    utterance.onend?.();

    expect(await pending).not.toHaveProperty("firstAudioMs");
  });

  it("does not start when already aborted", async () => {
    const fake = fakeSynthesis();
    const controller = new AbortController();
    controller.abort();

    await expect(
      runtimeOver(fake).speak({ text: "Hallo", locale: "de" }, controller.signal)
    ).resolves.toEqual({ stopped: true });
    expect(fake.spoken).toEqual([]);
  });

  it("treats the error its own cancel raises as stopped", async () => {
    const fake = fakeSynthesis();
    const controller = new AbortController();
    const pending = runtimeOver(fake).speak({ text: "Hallo", locale: "de" }, controller.signal);

    controller.abort();

    await expect(pending).resolves.toEqual({ stopped: true });
    expect(fake.synthesis.cancel).toHaveBeenCalledTimes(1);
  });

  it("settles once when end and error race", async () => {
    const fake = fakeSynthesis();
    const pending = runtimeOver(fake).speak({ text: "Hallo", locale: "de" });

    const utterance = fake.spoken[0]!;
    utterance.onend?.();
    utterance.onerror?.({ error: "synthesis-failed" });

    await expect(pending).resolves.toEqual({});
  });

  it("does not cancel the shared queue when nothing of its own is playing", async () => {
    const fake = fakeSynthesis();
    const controller = new AbortController();
    const pending = runtimeOver(fake).speak({ text: "Hallo", locale: "de" }, controller.signal);

    fake.spoken[0]!.onend?.();
    await pending;
    controller.abort();

    expect(fake.synthesis.cancel).not.toHaveBeenCalled();
  });

  it("maps a refused utterance and other failures", async () => {
    const fake = fakeSynthesis();
    const runtime = runtimeOver(fake);

    const refused = runtime.speak({ text: "a", locale: "de" });
    fake.spoken[0]!.onerror?.({ error: "not-allowed" });
    await expect(refused).rejects.toMatchObject({ kind: "not_allowed" });

    const failed = runtime.speak({ text: "b", locale: "de" });
    fake.spoken[1]!.onerror?.({ error: "synthesis-failed" });
    await expect(failed).rejects.toBeInstanceOf(SystemSpeechRuntimeError);
  });
});
