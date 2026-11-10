import { describe, expect, it, vi } from "vitest";

import { IndeRunException } from "../index.js";
import {
  createWebAudioOutputService,
  type WebAudioBufferLike,
  type WebAudioContextLike,
  type WebAudioSourceLike
} from "./browser-audio-output.js";

interface FakeSource extends WebAudioSourceLike {
  startedAt: number | undefined;
  stopCalls: number;
  buffer: WebAudioBufferLike & { data: Float32Array };
  end(): void;
}

function fakeAudioContext(
  options: {
    state?: "suspended" | "running";
    resume?: () => Promise<void>;
    baseLatency?: number;
    outputLatency?: number;
    sampleRate?: number;
  } = {}
) {
  const sources: FakeSource[] = [];
  const stateListeners: (() => void)[] = [];
  const context = {
    state: options.state ?? "running",
    currentTime: 0,
    sampleRate: options.sampleRate ?? 48000,
    baseLatency: options.baseLatency,
    outputLatency: options.outputLatency,
    destination: {},
    addEventListener(type: string, listener: () => void) {
      if (type === "statechange") stateListeners.push(listener);
    },
    resume:
      options.resume ??
      (async () => {
        (context as { state: string }).state = "running";
      }),
    createBuffer(_channels: number, length: number, rate: number) {
      const data = new Float32Array(length);
      return { duration: length / rate, sampleRate: rate, data, getChannelData: () => data };
    },
    createBufferSource() {
      const source: FakeSource = {
        buffer: null as unknown as FakeSource["buffer"],
        onended: null,
        startedAt: undefined,
        stopCalls: 0,
        connect: () => undefined,
        start(when?: number) {
          source.startedAt = when;
        },
        stop() {
          source.stopCalls += 1;
        },
        end() {
          source.onended?.();
        }
      };
      sources.push(source);
      return source;
    }
  } as unknown as WebAudioContextLike & { currentTime: number };
  return {
    context,
    sources,
    advance(seconds: number) {
      context.currentTime = seconds;
    },
    /** Sets the context state and fires `statechange`, as the browser does. */
    setState(state: "suspended" | "running" | "closed" | "interrupted") {
      (context as { state: string }).state = state;
      for (const listener of stateListeners) listener();
    },
    stateListenerCount: () => stateListeners.length
  };
}

const format = { sampleRate: 24000, channels: 1, encoding: "pcm_s16le" } as const;
const tick = async () => {
  for (let i = 0; i < 5; i += 1) await Promise.resolve();
};

describe("createWebAudioOutputService", () => {
  it("creates no AudioContext before the first open", async () => {
    const factory = vi.fn(() => fakeAudioContext({ state: "running" }).context);
    const service = createWebAudioOutputService({ audioContext: factory });
    expect(factory).not.toHaveBeenCalled();
    await service.open(format);
    await service.open(format);
    expect(factory).toHaveBeenCalledTimes(1);
  });

  it("refuses an unsupported format before touching the context", async () => {
    const factory = vi.fn();
    await expect(
      createWebAudioOutputService({ audioContext: factory }).open({ ...format, sampleRate: 4000 })
    ).rejects.toMatchObject({
      errorClass: "CapabilityMismatch",
      details: { code: "audio_format_unsupported" }
    });
    expect(factory).not.toHaveBeenCalled();
  });

  it("reports audio_output_failed when the context cannot be created", async () => {
    const service = createWebAudioOutputService({
      audioContext: () => {
        throw new ReferenceError("AudioContext is not defined");
      }
    });
    await expect(service.open(format)).rejects.toMatchObject({
      errorClass: "Unavailable",
      details: { code: "audio_output_failed" }
    });
  });

  it("refuses to open when the context stays suspended after resume", async () => {
    const resume = vi.fn(async () => {});
    const { context } = fakeAudioContext({ state: "suspended", resume });
    await expect(
      createWebAudioOutputService({ audioContext: () => context }).open(format)
    ).rejects.toMatchObject({ errorClass: "Unavailable", details: { code: "audio_not_allowed" } });
    expect(resume).toHaveBeenCalledTimes(1);
  });

  it("opens once resume() brings a suspended context to running", async () => {
    const resume = vi.fn(async () => {
      (context as { state: string }).state = "running";
    });
    const { context } = fakeAudioContext({ state: "suspended", resume });
    const session = await createWebAudioOutputService({ audioContext: () => context }).open(format);
    expect(resume).toHaveBeenCalledTimes(1);
    expect(context.state).toBe("running");
    expect(session.firstAudioMs()).toBeUndefined();
  });

  it("refuses to open when resume() does not settle within the timeout", async () => {
    const { context } = fakeAudioContext({
      state: "suspended",
      resume: () => new Promise(() => {})
    });
    await expect(
      createWebAudioOutputService({ audioContext: () => context, resumeTimeoutMs: 20 }).open(format)
    ).rejects.toMatchObject({ details: { code: "audio_not_allowed" } });
  });

  it("rejects open when the signal aborts while resuming", async () => {
    const controller = new AbortController();
    const { context } = fakeAudioContext({
      state: "suspended",
      resume: () => new Promise(() => {})
    });
    const opening = createWebAudioOutputService({ audioContext: () => context }).open(
      format,
      controller.signal
    );
    controller.abort();
    await expect(opening).rejects.toMatchObject({ name: "AbortError" });
  });

  it("rejects open at once when the signal is already aborted", async () => {
    const controller = new AbortController();
    controller.abort();
    const factory = vi.fn();
    await expect(
      createWebAudioOutputService({ audioContext: factory }).open(format, controller.signal)
    ).rejects.toMatchObject({ name: "AbortError" });
  });

  it("makes no sound at open", async () => {
    const { context, sources } = fakeAudioContext({ state: "running" });
    const session = await createWebAudioOutputService({ audioContext: () => context }).open(format);
    expect(sources).toHaveLength(0);
    expect(session.firstAudioMs()).toBeUndefined();
  });

  it("schedules writes back to back from 20 ms ahead at the session sample rate", async () => {
    const fake = fakeAudioContext({ state: "running", sampleRate: 48000 });
    fake.advance(1.0);
    const session = await createWebAudioOutputService({ audioContext: () => fake.context }).open(
      format
    );
    await session.write(Int16Array.from({ length: 4800 }, () => 16384));
    await session.write(new Int16Array(2400));
    expect(fake.sources.map((s) => s.startedAt)).toEqual([1.02, 1.22]);
    expect(fake.sources[0]!.buffer.sampleRate).toBe(24000);
    expect(fake.sources[0]!.buffer.getChannelData(0)[0]).toBeCloseTo(0.5);
  });

  it("waits in write once the scheduled lead exceeds maxLeadSeconds", async () => {
    const fake = fakeAudioContext({ state: "running" });
    const session = await createWebAudioOutputService({
      audioContext: () => fake.context,
      maxLeadSeconds: 1
    }).open(format);
    await session.write(new Int16Array(14400));
    let settled = false;
    const second = session.write(new Int16Array(14400)).then(() => {
      settled = true;
    });
    await tick();
    expect(settled).toBe(false);
    fake.advance(0.62);
    fake.sources[0]!.end();
    await second;
    expect(settled).toBe(true);
  });

  describe("backpressure wake-up", () => {
    // A chunk longer than maxLeadSeconds: the write must return once the lead has fallen to the
    // limit, while the chunk is still playing, so the next write continues it without a gap.
    it("releases a write when the lead falls to maxLeadSeconds, before the chunk ends", async () => {
      vi.useFakeTimers();
      try {
        const fake = fakeAudioContext({ state: "running" });
        const session = await createWebAudioOutputService({
          audioContext: () => fake.context,
          maxLeadSeconds: 1
        }).open(format);
        let settled = false;
        const long = session.write(new Int16Array(48000)).then(() => {
          settled = true;
        });
        await tick();
        expect(settled).toBe(false);
        fake.advance(1.02);
        await vi.advanceTimersByTimeAsync(1020);
        await tick();
        expect(settled).toBe(true);
        await long;
        // Still inside the first chunk: the next write is scheduled at its end, not 20 ms from now.
        fake.advance(1.5);
        await session.write(new Int16Array(2400));
        expect(fake.sources.map((s) => s.startedAt)).toEqual([0.02, 2.02]);
      } finally {
        vi.useRealTimers();
      }
    });

    it("keeps waiting when the timer fires before the lead has fallen enough", async () => {
      vi.useFakeTimers();
      try {
        const fake = fakeAudioContext({ state: "running" });
        const session = await createWebAudioOutputService({
          audioContext: () => fake.context,
          maxLeadSeconds: 1
        }).open(format);
        let settled = false;
        const long = session.write(new Int16Array(48000)).then(() => {
          settled = true;
        });
        fake.advance(0.5);
        await vi.advanceTimersByTimeAsync(1020);
        await tick();
        expect(settled).toBe(false);
        fake.advance(1.02);
        await vi.advanceTimersByTimeAsync(520);
        await tick();
        expect(settled).toBe(true);
        await long;
      } finally {
        vi.useRealTimers();
      }
    });

    it("clears the wake-up timer when stop releases the write", async () => {
      vi.useFakeTimers();
      try {
        const fake = fakeAudioContext({ state: "running" });
        const session = await createWebAudioOutputService({
          audioContext: () => fake.context,
          maxLeadSeconds: 1
        }).open(format);
        const long = session.write(new Int16Array(48000));
        await tick();
        // The lead wake-up and the wall-clock bound.
        expect(vi.getTimerCount()).toBe(2);
        session.stop();
        await long;
        expect(vi.getTimerCount()).toBe(0);
      } finally {
        vi.useRealTimers();
      }
    });
  });

  it("drain resolves when the last started source has ended", async () => {
    const fake = fakeAudioContext({ state: "running" });
    const session = await createWebAudioOutputService({ audioContext: () => fake.context }).open(
      format
    );
    await session.write(new Int16Array(2400));
    await session.write(new Int16Array(2400));
    let drained = false;
    const draining = session.drain().then(() => {
      drained = true;
    });
    fake.sources[0]!.end();
    await tick();
    expect(drained).toBe(false);
    fake.sources[1]!.end();
    await draining;
    expect(drained).toBe(true);
  });

  it("drain resolves at once when nothing was written", async () => {
    const fake = fakeAudioContext({ state: "running" });
    const session = await createWebAudioOutputService({ audioContext: () => fake.context }).open(
      format
    );
    await session.drain();
  });

  it("stop stops every live source and settles drain and a waiting write", async () => {
    const fake = fakeAudioContext({ state: "running" });
    const session = await createWebAudioOutputService({
      audioContext: () => fake.context,
      maxLeadSeconds: 1
    }).open(format);
    await session.write(new Int16Array(14400));
    const pendingWrite = session.write(new Int16Array(14400));
    const pendingDrain = session.drain();
    await tick();
    session.stop();
    await Promise.all([pendingWrite, pendingDrain]);
    expect(fake.sources.map((s) => s.stopCalls)).toEqual([1, 1]);
    await session.write(new Int16Array(240));
    await session.drain();
    expect(fake.sources).toHaveLength(2);
    session.stop();
    expect(fake.sources.map((s) => s.stopCalls)).toEqual([1, 1]);
  });

  it("tolerates a source that already ended when stop is called", async () => {
    const fake = fakeAudioContext({ state: "running" });
    const session = await createWebAudioOutputService({ audioContext: () => fake.context }).open(
      format
    );
    await session.write(new Int16Array(240));
    fake.sources[0]!.stop = () => {
      throw new DOMException("already ended", "InvalidStateError");
    };
    expect(() => session.stop()).not.toThrow();
  });

  it("firstAudioMs is undefined until currentTime passes the first start", async () => {
    const fake = fakeAudioContext({ state: "running", baseLatency: 0.01 });
    fake.advance(1.0);
    const session = await createWebAudioOutputService({ audioContext: () => fake.context }).open(
      format
    );
    await session.write(new Int16Array(2400));
    expect(session.firstAudioMs()).toBeUndefined();
    fake.advance(1.03);
    // Within 0.5 ms: the value includes open()'s own wall-clock time, about 0 here.
    expect(session.firstAudioMs()).toBeCloseTo(30, 0);
  });

  it("prefers outputLatency over baseLatency", async () => {
    const fake = fakeAudioContext({ state: "running", baseLatency: 0.01, outputLatency: 0.05 });
    const session = await createWebAudioOutputService({ audioContext: () => fake.context }).open(
      format
    );
    await session.write(new Int16Array(2400));
    fake.advance(0.5);
    // Within 0.5 ms: the value includes open()'s own wall-clock time, about 0 here.
    expect(session.firstAudioMs()).toBeCloseTo(70, 0);
  });

  it("firstAudioMs stays undefined when stop lands before the first start", async () => {
    const fake = fakeAudioContext({ state: "running", baseLatency: 0.01 });
    fake.advance(1.0);
    const session = await createWebAudioOutputService({ audioContext: () => fake.context }).open(
      format
    );
    await session.write(new Int16Array(2400));
    session.stop();
    fake.advance(2.0);
    expect(session.firstAudioMs()).toBeUndefined();
  });

  it("counts the time open() waited for resume() in firstAudioMs", async () => {
    // A suspended context's currentTime does not advance, so only the wall clock sees the wait.
    const fake = fakeAudioContext({
      state: "suspended",
      resume: async () => {
        await new Promise((resolve) => setTimeout(resolve, 100));
        (fake.context as { state: string }).state = "running";
      }
    });
    const session = await createWebAudioOutputService({ audioContext: () => fake.context }).open(
      format
    );
    await session.write(new Int16Array(2400));
    fake.advance(0.05);
    // 100 ms of resume wait plus the 20 ms scheduled start.
    expect(session.firstAudioMs()).toBeGreaterThanOrEqual(119);
  });

  it("keeps firstAudioMs when stop lands after the first start", async () => {
    const fake = fakeAudioContext({ state: "running" });
    const session = await createWebAudioOutputService({ audioContext: () => fake.context }).open(
      format
    );
    await session.write(new Int16Array(12000));
    fake.advance(0.3);
    session.stop();
    // Within 0.5 ms: the value includes open()'s own wall-clock time, about 0 here.
    expect(session.firstAudioMs()).toBeCloseTo(20, 0);
  });

  describe("when the context stops running after open", () => {
    const interrupted = {
      errorClass: "Unavailable",
      details: { code: "audio_output_interrupted" }
    };

    it("registers one statechange listener for the shared context", async () => {
      const fake = fakeAudioContext({ state: "running" });
      const service = createWebAudioOutputService({ audioContext: () => fake.context });
      await service.open(format);
      await service.open(format);
      expect(fake.stateListenerCount()).toBe(1);
    });

    it("ends a playing session: a pending drain and a backpressured write reject", async () => {
      const fake = fakeAudioContext({ state: "running" });
      const session = await createWebAudioOutputService({
        audioContext: () => fake.context,
        maxLeadSeconds: 1
      }).open(format);
      await session.write(new Int16Array(14400));
      const pendingWrite = session.write(new Int16Array(14400));
      const pendingDrain = session.drain();
      pendingWrite.catch(() => undefined);
      pendingDrain.catch(() => undefined);
      await tick();
      fake.setState("interrupted");
      await expect(pendingWrite).rejects.toMatchObject(interrupted);
      await expect(pendingDrain).rejects.toMatchObject(interrupted);
      expect(fake.sources.map((s) => s.stopCalls)).toEqual([1, 1]);
    });

    it("keeps the ending error: a later write and drain throw it, stop() stays quiet", async () => {
      const fake = fakeAudioContext({ state: "running" });
      const session = await createWebAudioOutputService({ audioContext: () => fake.context }).open(
        format
      );
      await session.write(new Int16Array(2400));
      fake.setState("suspended");
      await expect(session.write(new Int16Array(240))).rejects.toMatchObject(interrupted);
      await expect(session.drain()).rejects.toMatchObject(interrupted);
      expect(fake.sources).toHaveLength(1);
      expect(() => session.stop()).not.toThrow();
      await expect(session.write(new Int16Array(240))).rejects.toMatchObject(interrupted);
    });

    it("clears firstAudioMs when the context stops before the first start", async () => {
      const fake = fakeAudioContext({ state: "running" });
      fake.advance(1.0);
      const session = await createWebAudioOutputService({ audioContext: () => fake.context }).open(
        format
      );
      await session.write(new Int16Array(2400));
      fake.setState("suspended");
      fake.advance(2.0);
      expect(session.firstAudioMs()).toBeUndefined();
    });

    it("leaves a session with nothing live alone", async () => {
      const fake = fakeAudioContext({ state: "running" });
      const service = createWebAudioOutputService({ audioContext: () => fake.context });
      const playing = await service.open(format);
      const idle = await service.open(format);
      const drained = await service.open(format);
      await playing.write(new Int16Array(2400));
      await drained.write(new Int16Array(240));
      fake.sources[1]!.end();
      await drained.drain();
      fake.setState("suspended");
      await expect(playing.drain()).rejects.toMatchObject(interrupted);
      fake.setState("running");
      await idle.write(new Int16Array(240));
      await drained.write(new Int16Array(240));
      expect(fake.sources).toHaveLength(4);
      idle.stop();
      drained.stop();
    });

    it("ends a session whose write finds the context not running", async () => {
      const fake = fakeAudioContext({ state: "running" });
      const session = await createWebAudioOutputService({ audioContext: () => fake.context }).open(
        format
      );
      fake.setState("suspended");
      await expect(session.write(new Int16Array(240))).rejects.toMatchObject(interrupted);
      expect(fake.sources).toHaveLength(0);
      await expect(session.drain()).rejects.toMatchObject(interrupted);
    });

    it("falls back to onstatechange where addEventListener is missing", async () => {
      const fake = fakeAudioContext({ state: "running" });
      const context = fake.context as unknown as {
        addEventListener?: unknown;
        onstatechange?: (() => void) | null;
        state: string;
      };
      delete context.addEventListener;
      const session = await createWebAudioOutputService({
        audioContext: () => fake.context
      }).open(format);
      await session.write(new Int16Array(2400));
      const pendingDrain = session.drain();
      pendingDrain.catch(() => undefined);
      context.state = "suspended";
      context.onstatechange?.();
      await expect(pendingDrain).rejects.toMatchObject(interrupted);
    });
  });
});

describe("bounded output waits", () => {
  const stalledService = (maxLeadSeconds = 10) => {
    const fake = fakeAudioContext({ state: "running" });
    const service = createWebAudioOutputService({
      audioContext: () => fake.context,
      maxLeadSeconds
    });
    return { fake, service };
  };
  const ms = (n: number) => new Int16Array((24000 * n) / 1000);

  /** Settles a promise into a record so a rejection never goes unhandled. */
  function observe(promise: Promise<void>) {
    const state: { settled: boolean; error?: unknown } = { settled: false };
    promise.then(
      () => {
        state.settled = true;
      },
      (error: unknown) => {
        state.settled = true;
        state.error = error;
      }
    );
    return state;
  }

  function expectStall(error: unknown) {
    expect(error).toBeInstanceOf(IndeRunException);
    expect((error as IndeRunException).errorClass).toBe("Unavailable");
    expect((error as IndeRunException).details?.["code"]).toBe("audio_output_failed");
  }

  it("drain rejects with audio_output_failed after written duration + grace", async () => {
    vi.useFakeTimers();
    try {
      const { service } = stalledService();
      const session = await service.open(format);
      await session.write(ms(500));
      const draining = observe(session.drain());
      await vi.advanceTimersByTimeAsync(520 + 2000 - 1);
      expect(draining.settled).toBe(false);
      await vi.advanceTimersByTimeAsync(2);
      expect(draining.settled).toBe(true);
      expectStall(draining.error);
    } finally {
      vi.useRealTimers();
    }
  });

  it("honours outputWaitGraceMs", async () => {
    vi.useFakeTimers();
    try {
      const fake = fakeAudioContext({ state: "running" });
      const session = await createWebAudioOutputService({
        audioContext: () => fake.context,
        outputWaitGraceMs: 100
      }).open(format);
      await session.write(ms(500));
      const draining = observe(session.drain());
      await vi.advanceTimersByTimeAsync(600 + 20 + 1);
      expectStall(draining.error);
    } finally {
      vi.useRealTimers();
    }
  });

  it("drain_bound_counts_only_unplayed_audio", async () => {
    vi.useFakeTimers();
    try {
      const { fake, service } = stalledService();
      const session = await service.open(format);
      for (let i = 0; i < 4; i += 1) await session.write(ms(500));
      // Scheduled end is 0.02 + 2.0 s. 1 500 ms played, the clock then freezes with 500 ms left.
      fake.advance(1.52);
      for (const source of fake.sources.slice(0, 3)) source.end();
      const draining = observe(session.drain());
      await vi.advanceTimersByTimeAsync(500 + 2000 - 1);
      expect(draining.settled).toBe(false);
      await vi.advanceTimersByTimeAsync(2);
      expectStall(draining.error);
    } finally {
      vi.useRealTimers();
    }
  });

  it("stop_releases_a_stalled_drain", async () => {
    vi.useFakeTimers();
    try {
      const { service } = stalledService();
      const session = await service.open(format);
      await session.write(ms(500));
      const draining = observe(session.drain());
      await vi.advanceTimersByTimeAsync(100);
      session.stop();
      await vi.advanceTimersByTimeAsync(0);
      expect(draining.settled).toBe(true);
      expect(draining.error).toBeUndefined();
      await vi.advanceTimersByTimeAsync(10_000);
      expect(vi.getTimerCount()).toBe(0);
    } finally {
      vi.useRealTimers();
    }
  });

  it("write backpressure wait is bounded", async () => {
    vi.useFakeTimers();
    try {
      const { service } = stalledService(1);
      const session = await service.open(format);
      await session.write(ms(500));
      // 1 500 ms of lead against a 1 000 ms limit: the wait is for 520 ms of audio, plus grace.
      const blocked = observe(session.write(ms(1000)));
      await vi.advanceTimersByTimeAsync(520 + 2000 - 1);
      expect(blocked.settled).toBe(false);
      await vi.advanceTimersByTimeAsync(2);
      expect(blocked.settled).toBe(true);
      expectStall(blocked.error);
    } finally {
      vi.useRealTimers();
    }
  });

  it("after a failure write is ignored and drain resolves at once", async () => {
    vi.useFakeTimers();
    try {
      const { fake, service } = stalledService();
      const session = await service.open(format);
      await session.write(ms(500));
      const draining = observe(session.drain());
      await vi.advanceTimersByTimeAsync(3000);
      expectStall(draining.error);
      const sourcesBefore = fake.sources.length;
      await session.write(ms(100));
      await session.drain();
      expect(fake.sources.length).toBe(sourcesBefore);
      expect(fake.sources[0]!.stopCalls).toBe(1);
      session.stop();
    } finally {
      vi.useRealTimers();
    }
  });
});
