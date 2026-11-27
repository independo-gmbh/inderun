import { afterEach, describe, expect, it, vi } from "vitest";
import type { TaskRequest } from "@independo/inderun-contracts";
import {
  generateSpeech,
  IndeRun,
  IndeRunException,
  listVoices,
  prepare,
  speak
} from "../../index.js";
import { createBrowserHostServices } from "../../core/browser-host.js";
import { ProviderRegistry } from "../../provider.js";
import { createBrowserSpeechRuntime, type BrowserSpeechSynthesis } from "./browser-runtime.js";
import { SystemSpeechWebProvider } from "./provider.js";
import {
  SystemSpeechRuntimeError,
  type SystemSpeechRuntime,
  type SystemSpeechUtterance,
  type SystemSpeechVoice
} from "./runtime.js";

const LOCAL: SystemSpeechVoice = { uri: "local", locale: "de-DE", localService: true };
const NETWORK: SystemSpeechVoice = { uri: "remote", locale: "de-DE", localService: false };
const ANNA: SystemSpeechVoice = { uri: "anna", name: "Anna", locale: "de-DE", localService: true };
const ANNA_TOO: SystemSpeechVoice = {
  uri: "anna-2",
  name: "Anna",
  locale: "de-DE",
  localService: true
};

const PLAYBACK_STATES = [
  {
    id: "speech.speakingRate",
    delivery: "playback",
    available: true,
    range: { min: 0.5, max: 2, default: 1, step: 0.1 }
  },
  {
    id: "speech.pitch",
    delivery: "playback",
    available: true,
    range: { min: 0.5, max: 2, default: 1, step: 0.1 }
  },
  {
    id: "playback.volume",
    delivery: "playback",
    available: true,
    range: { min: 0, max: 1, default: 1, step: 0.05 }
  }
];

/** A scripted runtime: utterances finish at once, or hold until released or aborted. */
function fakeRuntime(voices: SystemSpeechVoice[] = [LOCAL, NETWORK]) {
  const spoken: { text: string; voice?: string }[] = [];
  const utterances: SystemSpeechUtterance[] = [];
  const stopped: string[] = [];
  const held = new Map<string, () => void>();
  const holds = new Set<string>();
  const state = { voices, failure: undefined as Error | undefined };
  const runtime: SystemSpeechRuntime = {
    availability: () => ({ kind: "available" }),
    voices: async () => state.voices,
    whenIdle: async () => {},
    whenVoicesListed: async () => state.voices.length > 0,
    speak: (utterance, signal) => {
      utterances.push(utterance);
      spoken.push({
        text: utterance.text,
        ...(utterance.voice !== undefined ? { voice: utterance.voice.uri } : {})
      });
      if (state.failure !== undefined) return Promise.reject(state.failure);
      if (!holds.has(utterance.text)) return Promise.resolve({ durationMs: 700, firstAudioMs: 90 });
      return new Promise((resolve) => {
        held.set(utterance.text, () => resolve({ durationMs: 700 }));
        signal?.addEventListener("abort", () => {
          stopped.push(utterance.text);
          resolve({ stopped: true });
        });
      });
    }
  };
  return { runtime, spoken, utterances, stopped, held, holds, state };
}

function engine(runtime: SystemSpeechRuntime, online = true): IndeRun {
  const registry = new ProviderRegistry();
  registry.register(new SystemSpeechWebProvider({ runtime }));
  return new IndeRun(
    registry,
    createBrowserHostServices({ connectivity: { isOnline: async () => online } })
  );
}

const tick = () => new Promise((resolve) => setTimeout(resolve, 5));

describe("SystemSpeechWebProvider", () => {
  const host = (online = true) =>
    createBrowserHostServices({ connectivity: { isOnline: async () => online } });

  it("declares playback only, with hard cancel and a conservative privacy posture", () => {
    const task = new SystemSpeechWebProvider({ runtime: fakeRuntime().runtime }).describe()
      .taskCapabilities![0]!;

    expect(task.outputs).toEqual([{ delivery: "playback" }]);
    expect(task.cancel).toBe("hard");
    expect(task.interaction.stream).toBe(true);
    expect(task.privacy).toEqual({ dataLeavesDevice: true });
    expect(task.controls).toEqual([
      {
        id: "speech.speakingRate",
        valueKind: "number",
        phase: "synthesis",
        lifetime: "utterance",
        deliveries: ["playback"]
      },
      {
        id: "speech.pitch",
        valueKind: "number",
        phase: "synthesis",
        lifetime: "utterance",
        deliveries: ["playback"]
      },
      {
        id: "playback.volume",
        valueKind: "number",
        phase: "playback",
        lifetime: "utterance",
        deliveries: ["playback"]
      }
    ]);
  });

  it("reports a missing API as unavailable rather than failing", async () => {
    const runtime: SystemSpeechRuntime = {
      ...fakeRuntime().runtime,
      availability: () => ({ kind: "api_missing", reason: "no api" })
    };

    await expect(new SystemSpeechWebProvider({ runtime }).capabilities(host())).resolves.toEqual({
      available: false,
      reason: "no api"
    });
  });

  it("reports an empty list as not loaded yet, which is not the same as no voices", async () => {
    const provider = new SystemSpeechWebProvider({ runtime: fakeRuntime([]).runtime });

    await expect(provider.capabilities(host())).resolves.toMatchObject({
      available: false,
      taskCapabilities: [{ kind: "text_to_speech", readiness: "preparing" }]
    });
  });

  it("stops saying not yet once a preparation found nothing", async () => {
    const inderun = engine(fakeRuntime([]).runtime);

    const { items } = await (await prepare(inderun)).result;

    expect(items).toMatchObject([{ status: "failed", task: "text_to_speech" }]);
    const [snapshot] = await inderun.checkCapabilities();
    expect(snapshot?.capabilities).toEqual({
      available: false,
      reason: "The browser offers no speech voices."
    });
  });

  it("speaks on the first call once a late voice list arrives", async () => {
    const fake = fakeRuntime([]);
    fake.runtime.whenVoicesListed = async () => {
      fake.state.voices = [ANNA];
      return true;
    };

    const ending = await (
      await speak(engine(fake.runtime), { text: "Hallo", locale: "de-DE" })
    ).result;

    expect(fake.spoken).toEqual([{ text: "Hallo", voice: "anna" }]);
    expect(ending.speech?.voice?.id).toBe("anna");
  });

  it("refuses speech as not ready when the list never arrives", async () => {
    const fake = fakeRuntime([]);
    fake.runtime.whenVoicesListed = (signal) =>
      new Promise((resolve) => signal?.addEventListener("abort", () => resolve(false)));

    await expect(
      speak(engine(fake.runtime), {
        text: "Hallo",
        locale: "de-DE",
        execution: { timeoutMs: 5 }
      })
    ).rejects.toMatchObject({
      details: expect.objectContaining({
        rejectedProviders: [
          expect.objectContaining({ reasons: [expect.objectContaining({ code: "not_ready" })] })
        ]
      })
    });
  });

  it("prepares when the browser lists its voices, and makes no sound", async () => {
    const fake = fakeRuntime([]);
    fake.runtime.whenVoicesListed = async () => {
      fake.state.voices = [ANNA];
      return true;
    };

    const prepared = await (await prepare(engine(fake.runtime))).result;

    expect(prepared.finishReason).toBe("stop");
    expect(prepared.items).toMatchObject([{ status: "prepared" }]);
    expect(fake.spoken).toEqual([]);
  });

  it("cancels a preparation with one terminal outcome and no failure", async () => {
    const fake = fakeRuntime([]);
    fake.runtime.whenVoicesListed = (signal) =>
      new Promise((resolve) => signal?.addEventListener("abort", () => resolve(false)));
    const preparation = await prepare(engine(fake.runtime));
    await new Promise((resolve) => setTimeout(resolve, 5));

    preparation.cancel("left the screen");
    preparation.cancel("again");

    await expect(preparation.result).resolves.toMatchObject({ finishReason: "cancelled" });
  });

  it("never claims a voice is on-device, and marks known network voices", async () => {
    const provider = new SystemSpeechWebProvider({ runtime: fakeRuntime().runtime });

    const capabilities = await provider.capabilities(host());

    expect(capabilities.taskCapabilities![0]!.voices).toEqual([
      { id: "local", locale: "de-DE", controlStates: PLAYBACK_STATES },
      { id: "remote", locale: "de-DE", networkRequired: true }
    ]);
    expect(capabilities.taskCapabilities![0]!.controlStates).toBeUndefined();
  });

  it("lists every voice, also those with identical traits and names", async () => {
    const voices = await listVoices(engine(fakeRuntime([ANNA, ANNA_TOO]).runtime));

    expect(voices).toEqual([
      {
        providerId: "web_system_speech",
        kind: "platform",
        id: "anna",
        name: "Anna",
        locale: "de-DE"
      },
      {
        providerId: "web_system_speech",
        kind: "platform",
        id: "anna-2",
        name: "Anna",
        locale: "de-DE"
      }
    ]);
  });

  it("speaks a voice picked from the catalog and reports it", async () => {
    const fake = fakeRuntime([ANNA, ANNA_TOO]);
    const inderun = engine(fake.runtime);
    const picked = (await listVoices(inderun))[1]!;

    const ending = await (
      await speak(inderun, { text: "Hallo", locale: "de-DE", voice: picked })
    ).result;

    expect(fake.spoken).toEqual([{ text: "Hallo", voice: "anna-2" }]);
    expect(ending.speech?.voice).toEqual({ id: "anna-2", name: "Anna" });
  });

  it("falls back from a stored voice that is gone, visibly", async () => {
    const fake = fakeRuntime([ANNA]);
    const stored = { providerId: "web_system_speech", id: "anna-2", locale: "de-DE" };

    const playback = await speak(engine(fake.runtime), {
      text: "Hallo",
      locale: "de-DE",
      voice: stored
    });
    const ending = await playback.result;

    expect(ending.speech?.voice?.id).toBe("anna");
  });

  it("refuses a required voice that is gone", async () => {
    const stored = { providerId: "web_system_speech", id: "anna-2", requirement: "required" };

    await expect(
      speak(engine(fakeRuntime([ANNA]).runtime), {
        text: "Hallo",
        locale: "de-DE",
        voice: stored as { requirement: "required" }
      })
    ).rejects.toBeInstanceOf(IndeRunException);
  });

  it("drops known network voices while offline", async () => {
    const provider = new SystemSpeechWebProvider({ runtime: fakeRuntime().runtime });

    const capabilities = await provider.capabilities(host(false));

    expect(capabilities.taskCapabilities![0]!.voices).toEqual([
      { id: "local", locale: "de-DE", controlStates: PLAYBACK_STATES }
    ]);
  });

  it("is unavailable offline when only network voices exist", async () => {
    const provider = new SystemSpeechWebProvider({ runtime: fakeRuntime([NETWORK]).runtime });

    await expect(provider.capabilities(host(false))).resolves.toMatchObject({ available: false });
  });
});

describe("speech through the engine", () => {
  const options = { text: "Hallo", locale: "de-DE" };

  afterEach(() => {
    vi.useRealTimers();
  });

  it("speaks the voice the plan bound, and does not claim on-device", async () => {
    // firstAudioMs adds the wall-clock time from request to handoff; freeze it so the
    // runtime's 90 ms comes through unchanged.
    vi.useFakeTimers({ toFake: ["Date"] });
    const fake = fakeRuntime();

    const ending = await (await speak(engine(fake.runtime), options)).result;

    expect(fake.spoken).toEqual([{ text: "Hallo", voice: "local" }]);
    expect(ending).toMatchObject({
      finishReason: "stop",
      timing: { durationMs: 700, firstAudioMs: 90 },
      speech: { locale: "de-DE" }
    });
    expect(ending.provenance?.providerId).toBe("web_system_speech");
    expect(ending.provenance?.locality).toBe("unknown");
    expect(ending.provenance?.attempts[0]?.committed).toBe(true);
  });

  describe("timing origin", () => {
    /** A runtime whose voice lookup takes 50 ms of (fake) wall-clock time. */
    function slowVoiceRuntime(ending: { durationMs: number; firstAudioMs?: number }) {
      const fake = fakeRuntime();
      const voices = fake.runtime.voices.bind(fake.runtime);
      fake.runtime.voices = async () => {
        vi.setSystemTime(Date.now() + 50);
        return voices();
      };
      fake.runtime.speak = async () => ending;
      return fake.runtime;
    }

    it("counts firstAudioMs from the request, not the handoff", async () => {
      vi.useFakeTimers({ toFake: ["Date"] });

      const ending = await (
        await speak(engine(slowVoiceRuntime({ durationMs: 700, firstAudioMs: 90 })), options)
      ).result;

      expect(ending.timing?.firstAudioMs).toBe(140);
    });

    it("leaves firstAudioMs absent when the runtime reports none", async () => {
      vi.useFakeTimers({ toFake: ["Date"] });

      const ending = await (
        await speak(engine(slowVoiceRuntime({ durationMs: 700 })), options)
      ).result;

      expect(ending.timing).toEqual({ durationMs: 700 });
    });
  });

  it("always refuses local_required", async () => {
    const fake = fakeRuntime();

    await expect(
      speak(engine(fake.runtime), { ...options, execution: { privacy: "local_required" } })
    ).rejects.toMatchObject({ errorClass: "CapabilityMismatch" });
    expect(fake.spoken).toEqual([]);
  });

  it("is refused for retrievable audio before anything plays", async () => {
    const fake = fakeRuntime();

    await expect(generateSpeech(engine(fake.runtime), options)).rejects.toMatchObject({
      errorClass: "CapabilityMismatch"
    });
    expect(fake.spoken).toEqual([]);
  });

  it("refuses an unsupported locale deterministically", async () => {
    const fake = fakeRuntime();

    await expect(
      speak(engine(fake.runtime), { text: "Hello", locale: "en-US" })
    ).rejects.toBeInstanceOf(IndeRunException);
    expect(fake.spoken).toEqual([]);
  });

  it("completes through run() too", async () => {
    const fake = fakeRuntime();
    const request: TaskRequest = {
      schemaVersion: "1.1",
      task: { kind: "text_to_speech" },
      speech: { text: "Hallo", locale: "de-DE" },
      delivery: { mode: "playback" }
    };

    const result = await engine(fake.runtime).run(request);

    expect(result.output).toMatchObject({
      type: "playback",
      playback: { timing: { durationMs: 700 } }
    });
  });

  it("stops the audio on cancel with one terminal outcome", async () => {
    const fake = fakeRuntime();
    fake.holds.add("Hallo");

    const playback = await speak(engine(fake.runtime), options);
    await tick();
    playback.cancel("stop");
    playback.cancel("again");
    const ending = await playback.result;

    expect(fake.stopped).toEqual(["Hallo"]);
    expect(ending.finishReason).toBe("cancelled");
    expect(ending.provenance?.attempts).toHaveLength(1);
    expect(ending.provenance?.attempts[0]).toMatchObject({ outcome: "cancelled", committed: true });
  });

  it("does not fall back after a failure once playback committed", async () => {
    const fake = fakeRuntime();
    fake.state.failure = new SystemSpeechRuntimeError("synthesis_failed", "boom");
    const second = vi.fn();
    const registry = new ProviderRegistry();
    registry.register(new SystemSpeechWebProvider({ runtime: fake.runtime }));
    registry.register(
      new SystemSpeechWebProvider({
        id: "z_second",
        runtime: { ...fakeRuntime().runtime, speak: second }
      })
    );
    const inderun = new IndeRun(registry, createBrowserHostServices());

    const { result } = await speak(inderun, options);

    await expect(result).rejects.toMatchObject({
      errorClass: "Unavailable",
      details: { code: "speech_synthesis_failed" }
    });
    expect(second).not.toHaveBeenCalled();
  });

  it("reports a browser that refuses to speak", async () => {
    const fake = fakeRuntime();
    fake.state.failure = new SystemSpeechRuntimeError("not_allowed", "blocked");

    const { result } = await speak(engine(fake.runtime), options);

    await expect(result).rejects.toMatchObject({ details: { code: "speech_not_allowed" } });
  });

  it("refuses a voice removed since planning before commit", async () => {
    const fake = fakeRuntime([LOCAL]);
    const context = {
      runId: "r",
      hostServices: createBrowserHostServices(),
      voice: { id: "gone", locale: "de-DE", networkRequired: true },
      commit: vi.fn(() => true),
      reportSpeech: () => {},
      artifacts: { create: vi.fn() }
    };
    const provider = new SystemSpeechWebProvider({ runtime: fake.runtime });
    const request: TaskRequest = {
      schemaVersion: "1.1",
      task: { kind: "text_to_speech" },
      speech: { text: "Hallo", locale: "de-DE" },
      delivery: { mode: "playback" }
    };

    await expect(provider.run(request, context as never)).rejects.toMatchObject({
      errorClass: "CapabilityMismatch",
      details: { code: "voice_not_available" }
    });
    expect(context.commit).not.toHaveBeenCalled();
  });

  it("refuses a voice removed while waiting, before commit, so another provider can speak", async () => {
    const fake = fakeRuntime();
    fake.holds.add("eins");
    const other = fakeRuntime();
    const registry = new ProviderRegistry();
    registry.register(new SystemSpeechWebProvider({ runtime: fake.runtime }));
    registry.register(new SystemSpeechWebProvider({ id: "z_other", runtime: other.runtime }));
    const inderun = new IndeRun(registry, createBrowserHostServices());

    const first = await speak(inderun, { text: "eins", locale: "de-DE" });
    await tick();
    const second = await speak(inderun, { text: "zwei", locale: "de-DE" });
    await tick();
    fake.state.voices = [];
    fake.held.get("eins")!();
    await first.result;
    const ending = await second.result;

    expect(fake.spoken.map((call) => call.text)).toEqual(["eins"]);
    expect(other.spoken.map((call) => call.text)).toEqual(["zwei"]);
    expect(ending.provenance?.attempts[0]).toMatchObject({
      outcome: "failed",
      errorClass: "CapabilityMismatch"
    });
    expect(ending.provenance?.attempts[0]?.committed).toBeUndefined();
  });

  it("leaves other speech on the page alone when cancelled while it plays", async () => {
    const spoken: unknown[] = [];
    const synthesis: BrowserSpeechSynthesis = {
      speaking: true,
      getVoices: () => [{ voiceURI: "local", lang: "de-DE", localService: true }],
      speak: (utterance) => spoken.push(utterance),
      cancel: vi.fn()
    };
    const runtime = createBrowserSpeechRuntime({
      synthesis: () => synthesis,
      createUtterance: () => ({
        lang: "",
        voice: null,
        onstart: null,
        onend: null,
        onerror: null
      }),
      idlePollMs: 1
    });

    const playback = await speak(engine(runtime), options);
    await tick();
    playback.cancel("stop");
    const ending = await playback.result;

    expect(ending.finishReason).toBe("cancelled");
    expect(ending.provenance?.attempts[0]?.committed).toBeUndefined();
    expect(spoken).toEqual([]);
    expect(synthesis.cancel).not.toHaveBeenCalled();
  });

  it("plays one utterance at a time, in order, committing at each turn", async () => {
    const fake = fakeRuntime();
    fake.holds.add("eins");
    const inderun = engine(fake.runtime);

    const first = await speak(inderun, { text: "eins", locale: "de-DE" });
    await tick();
    const second = await speak(inderun, { text: "zwei", locale: "de-DE" });
    await tick();
    expect(fake.spoken.map((call) => call.text)).toEqual(["eins"]);

    fake.held.get("eins")!();
    await first.result;
    await second.result;

    expect(fake.spoken.map((call) => call.text)).toEqual(["eins", "zwei"]);
  });

  it("never plays an utterance cancelled while waiting, and keeps the line moving", async () => {
    const fake = fakeRuntime();
    fake.holds.add("eins");
    const inderun = engine(fake.runtime);

    const first = await speak(inderun, { text: "eins", locale: "de-DE" });
    await tick();
    const second = await speak(inderun, { text: "zwei", locale: "de-DE" });
    await tick();
    const third = await speak(inderun, { text: "drei", locale: "de-DE" });
    await tick();
    second.cancel();
    const cancelled = await second.result;
    fake.held.get("eins")!();
    await first.result;
    await third.result;

    expect(cancelled.finishReason).toBe("cancelled");
    expect(cancelled.provenance?.attempts[0]?.committed).toBeUndefined();
    expect(fake.spoken.map((call) => call.text)).toEqual(["eins", "drei"]);
  });
});

describe("speech controls", () => {
  const request = (extra: Record<string, unknown> = {}, playback?: unknown): TaskRequest =>
    ({
      schemaVersion: "1.1",
      task: { kind: "text_to_speech" },
      speech: { text: "Hallo", locale: "de-DE", ...extra },
      delivery: { mode: "playback", ...(playback !== undefined ? { playback } : {}) }
    }) as TaskRequest;

  it("hands the utterance exactly the applied values and records them", async () => {
    const fake = fakeRuntime();

    const result = await engine(fake.runtime).run(
      request(
        { controls: { speakingRate: { value: 1.5 }, pitch: { value: 0.8 } } },
        { volume: { value: 0.5 } }
      )
    );

    expect(fake.utterances[0]).toMatchObject({ rate: 1.5, pitch: 0.8, volume: 0.5 });
    expect(result.output).toMatchObject({
      speech: {
        controls: [
          {
            id: "speech.speakingRate",
            requested: 1.5,
            effective: 1.5,
            status: "applied",
            method: "platform_synthesis"
          },
          {
            id: "speech.pitch",
            requested: 0.8,
            effective: 0.8,
            status: "applied",
            method: "platform_synthesis"
          },
          {
            id: "playback.volume",
            requested: 0.5,
            effective: 0.5,
            status: "applied",
            method: "playback_attenuation"
          }
        ]
      }
    });
  });

  it("leaves an omitted control unset and reports the plan's reason", async () => {
    const fake = fakeRuntime();

    const result = await engine(fake.runtime).run(
      request({ controls: { speakingRate: { value: 1.5 }, pitch: { value: 5 } } })
    );

    const utterance = fake.utterances[0]!;
    expect(utterance.rate).toBe(1.5);
    expect("pitch" in utterance).toBe(false);
    expect("volume" in utterance).toBe(false);
    expect(result.output).toMatchObject({
      speech: {
        controls: [
          { id: "speech.speakingRate", status: "applied" },
          { id: "speech.pitch", requested: 5, status: "not_applied", reason: "out_of_range" }
        ]
      }
    });
  });

  it("leaves every property unset and emits no records without controls", async () => {
    const fake = fakeRuntime();

    const result = await engine(fake.runtime).run(request());

    const utterance = fake.utterances[0]!;
    expect("rate" in utterance || "pitch" in utterance || "volume" in utterance).toBe(false);
    expect((result.output as { speech?: object }).speech).not.toHaveProperty("controls");
  });

  it("never routes a required control to a network voice", async () => {
    const fake = fakeRuntime([NETWORK]);

    await expect(
      engine(fake.runtime).run(
        request({ controls: { speakingRate: { value: 1.5, requirement: "required" } } })
      )
    ).rejects.toBeInstanceOf(IndeRunException);
    expect(fake.utterances).toEqual([]);
  });

  it("keeps the reported records when cancelled after commit", async () => {
    const fake = fakeRuntime();
    fake.holds.add("Hallo");

    const playback = await speak(engine(fake.runtime), {
      text: "Hallo",
      locale: "de-DE",
      controls: { speakingRate: { value: 1.5 } }
    });
    await tick();
    playback.cancel("stop");
    const ending = await playback.result;

    expect(ending.finishReason).toBe("cancelled");
    expect(ending.speech?.controls).toMatchObject([
      { id: "speech.speakingRate", status: "applied", effective: 1.5 }
    ]);
  });
});

describe("speech controls rechecked at the turn", () => {
  const request: TaskRequest = {
    schemaVersion: "1.1",
    task: { kind: "text_to_speech" },
    speech: { text: "Hallo", locale: "de-DE" },
    delivery: { mode: "playback" }
  };
  const bound = { id: "local", locale: "de-DE", controlStates: PLAYBACK_STATES };

  function turn(
    voices: SystemSpeechVoice[],
    controls: Record<string, unknown>[]
  ): {
    provider: SystemSpeechWebProvider;
    context: Record<string, unknown> & { commit: () => boolean };
    fake: ReturnType<typeof fakeRuntime>;
  } {
    const fake = fakeRuntime(voices);
    const context = {
      runId: "r",
      hostServices: createBrowserHostServices(),
      voice: bound,
      controls,
      commit: vi.fn(() => true),
      reportSpeech: () => {},
      artifacts: { create: vi.fn() }
    };
    return { provider: new SystemSpeechWebProvider({ runtime: fake.runtime }), context, fake };
  }

  it.each([
    ["false", false],
    ["undefined", undefined]
  ])(
    "refuses a required control before commit when the voice's localService became %s",
    async (_label, localService) => {
      const { provider, context, fake } = turn(
        [
          { uri: "local", locale: "de-DE", ...(localService === undefined ? {} : { localService }) }
        ],
        [{ id: "speech.speakingRate", value: 1.5, requirement: "required", decision: "apply" }]
      );

      await expect(provider.run(request, context as never)).rejects.toMatchObject({
        errorClass: "CapabilityMismatch",
        details: { code: "speech_control_unsupported" }
      });
      expect(context.commit).not.toHaveBeenCalled();
      expect(fake.utterances).toEqual([]);
    }
  );

  it("drops preferred controls to not_applied/availability_unknown and passes no value on", async () => {
    const { provider, context, fake } = turn(
      [{ uri: "local", locale: "de-DE", localService: false }],
      [
        { id: "speech.pitch", value: 1.2, requirement: "preferred", decision: "apply" },
        { id: "playback.volume", value: 0.5, requirement: "preferred", decision: "apply" }
      ]
    );

    const result = await provider.run(request, context as never);

    expect(fake.utterances).toHaveLength(1);
    expect("pitch" in fake.utterances[0]!).toBe(false);
    expect("volume" in fake.utterances[0]!).toBe(false);
    expect(result.output).toMatchObject({
      speech: {
        controls: [
          {
            id: "speech.pitch",
            requested: 1.2,
            status: "not_applied",
            reason: "availability_unknown"
          },
          {
            id: "playback.volume",
            requested: 0.5,
            status: "not_applied",
            reason: "availability_unknown"
          }
        ]
      }
    });
  });

  it("keeps applying controls while the live voice is still on-device", async () => {
    const { provider, context, fake } = turn(
      [LOCAL],
      [{ id: "speech.pitch", value: 1.2, requirement: "preferred", decision: "apply" }]
    );

    await provider.run(request, context as never);

    expect(fake.utterances[0]).toMatchObject({ pitch: 1.2 });
  });

  it("falls back to the next provider when a queued required control loses support", async () => {
    const fake = fakeRuntime();
    fake.holds.add("eins");
    const other = fakeRuntime();
    const registry = new ProviderRegistry();
    registry.register(new SystemSpeechWebProvider({ runtime: fake.runtime }));
    registry.register(new SystemSpeechWebProvider({ id: "z_other", runtime: other.runtime }));
    const inderun = new IndeRun(registry, createBrowserHostServices());

    const first = await speak(inderun, { text: "eins", locale: "de-DE" });
    await tick();
    const second = await speak(inderun, {
      text: "zwei",
      locale: "de-DE",
      controls: { speakingRate: { value: 1.5, requirement: "required" } }
    });
    await tick();
    fake.state.voices = [{ ...LOCAL, localService: false }];
    fake.held.get("eins")!();
    await first.result;
    const ending = await second.result;

    expect(fake.spoken.map((call) => call.text)).toEqual(["eins"]);
    expect(other.spoken.map((call) => call.text)).toEqual(["zwei"]);
    expect(ending.provenance?.attempts[0]).toMatchObject({
      outcome: "failed",
      errorClass: "CapabilityMismatch"
    });
    expect(ending.provenance?.attempts[0]?.committed).toBeUndefined();
  });
});
