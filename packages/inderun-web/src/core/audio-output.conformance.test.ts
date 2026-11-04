import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import type { AudioOutputFormat, AudioOutputService } from "@independo/inderun-contracts";
import { describe, expect, it } from "vitest";

import { IndeRunException } from "../index.js";
import { createUnavailable } from "./errors.js";
import { createFixtureAudioOutput } from "../test/audio-output-fixture.js";

/** Mirrors `$expectKeys` in the catalog; every key is optional. */
interface Expectations {
  afterOpen?: { firstAudioDefined: boolean };
  afterWrites?: { firstAudioDefined: boolean; waitAtMostMs?: number; firstAudioAtMostMs?: number };
  drain?: { elapsedAtLeastMs: number; timeoutMs: number };
  stop?: { throws: boolean; calls?: number; writeSettlesWithinMs?: number };
  writeAfterStop?: { elapsedAtMostMs: number; throws: boolean };
  drainAfterStop?: { elapsedAtMostMs: number; throws: boolean };
  independence?: { stoppedDrainAtMostMs: number; otherDrainAtLeastMs: number; timeoutMs: number };
  openRejectsWith?: { errorClass: string; code: string };
}

interface CatalogCase {
  id: string;
  expect: Expectations;
}

const catalog = JSON.parse(
  readFileSync(
    join(
      dirname(fileURLToPath(import.meta.url)),
      "../../../../contracts/fixtures/host/audio-output-lifecycle.json"
    ),
    "utf8"
  )
) as { cases: CatalogCase[] };

interface Target {
  service: AudioOutputService;
  now(): number;
}

interface Observation {
  firstAudioDefinedAfterOpen?: boolean;
  firstAudioDefinedAfterWrites?: boolean;
  firstAudioMs?: number;
  drainElapsedMs?: number;
  stopThrew?: boolean;
  stopCalls?: number;
  writeSettledAfterStopMs?: number;
  writeAfterStopElapsedMs?: number;
  writeAfterStopThrew?: boolean;
  drainAfterStopElapsedMs?: number;
  drainAfterStopThrew?: boolean;
  stoppedDrainElapsedMs?: number;
  otherDrainElapsedMs?: number;
  openRejection?: IndeRunException;
}

const format: AudioOutputFormat = { sampleRate: 24000, channels: 1, encoding: "pcm_s16le" };

/** 440 Hz at -14 dBFS. */
function tone(ms: number, sampleRate = format.sampleRate): Int16Array {
  const frames = Math.round((sampleRate * ms) / 1000);
  const amplitude = 32767 * 10 ** (-14 / 20);
  const samples = new Int16Array(frames);
  for (let i = 0; i < frames; i++) {
    samples[i] = Math.round(amplitude * Math.sin((2 * Math.PI * 440 * i) / sampleRate));
  }
  return samples;
}

/** Wall time; the fixture's own clock is virtual. */
function settle(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function bounded<T>(promise: Promise<T>, ms: number, label: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${label} did not settle within ${ms} ms`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

/** Runs `action`, returning whether it threw. */
async function threw(action: () => unknown): Promise<boolean> {
  try {
    await action();
    return false;
  } catch {
    return true;
  }
}

/** Every wait and bound a handler uses comes from the case's own expectations. */
const handlers: Record<string, (target: Target, expected: Expectations) => Promise<Observation>> = {
  async open_makes_no_sound({ service }) {
    const session = await service.open(format);
    await settle(200);
    const firstAudioDefinedAfterOpen = session.firstAudioMs() !== undefined;
    session.stop();
    return { firstAudioDefinedAfterOpen };
  },
  async first_write_starts_playback({ service }, expected) {
    const waitMs = expected.afterWrites?.waitAtMostMs ?? 0;
    const session = await service.open(format);
    const firstAudioDefinedAfterOpen = session.firstAudioMs() !== undefined;
    await session.write(tone(200));
    const deadline = Date.now() + waitMs;
    while (session.firstAudioMs() === undefined && Date.now() < deadline) await settle(10);
    const firstAudioMs = session.firstAudioMs();
    await bounded(session.drain(), waitMs, "drain");
    session.stop();
    return {
      firstAudioDefinedAfterOpen,
      firstAudioDefinedAfterWrites: firstAudioMs !== undefined,
      ...(firstAudioMs !== undefined ? { firstAudioMs } : {})
    };
  },
  async drain_waits_for_everything_written({ service, now }, expected) {
    const session = await service.open(format);
    const from = now();
    await session.write(tone(200));
    await session.write(tone(200));
    await bounded(session.drain(), expected.drain!.timeoutMs, "drain");
    const drainElapsedMs = now() - from;
    session.stop();
    return { drainElapsedMs };
  },
  async stop_discards_buffered_audio({ service, now }, expected) {
    const session = await service.open(format);
    const inFlight = session.write(tone(3000));
    await settle(100);
    const stopThrew = await threw(() => session.stop());
    const stoppedAt = now();
    await bounded(inFlight, expected.stop!.writeSettlesWithinMs!, "in-flight write");
    const writeSettledAfterStopMs = now() - stoppedAt;
    const drainFrom = now();
    const drainAfterStopThrew = await threw(() =>
      bounded(session.drain(), expected.stop!.writeSettlesWithinMs!, "drain after stop")
    );
    return {
      stopThrew,
      writeSettledAfterStopMs,
      drainAfterStopElapsedMs: now() - drainFrom,
      drainAfterStopThrew
    };
  },
  async stop_is_idempotent({ service, now }, expected) {
    const session = await service.open(format);
    await session.write(tone(200));
    let stopThrew = false;
    let stopCalls = 0;
    for (let call = 0; call < expected.stop!.calls!; call++) {
      stopCalls++;
      stopThrew = (await threw(() => session.stop())) || stopThrew;
    }
    const drainFrom = now();
    const drainAfterStopThrew = await threw(() =>
      bounded(session.drain(), expected.drainAfterStop!.elapsedAtMostMs, "drain after stop")
    );
    return {
      stopThrew,
      stopCalls,
      drainAfterStopElapsedMs: now() - drainFrom,
      drainAfterStopThrew
    };
  },
  async write_after_stop_is_ignored({ service, now }, expected) {
    const session = await service.open(format);
    session.stop();
    const from = now();
    const writeAfterStopThrew = await threw(() =>
      bounded(
        session.write(tone(200)),
        expected.writeAfterStop!.elapsedAtMostMs,
        "write after stop"
      )
    );
    const writeAfterStopElapsedMs = now() - from;
    await settle(300);
    return {
      writeAfterStopElapsedMs,
      writeAfterStopThrew,
      firstAudioDefinedAfterWrites: session.firstAudioMs() !== undefined
    };
  },
  async drain_after_stop_resolves_at_once({ service, now }, expected) {
    const session = await service.open(format);
    await session.write(tone(200));
    session.stop();
    const from = now();
    const drainAfterStopThrew = await threw(() =>
      bounded(session.drain(), expected.drainAfterStop!.elapsedAtMostMs, "drain after stop")
    );
    return { drainAfterStopElapsedMs: now() - from, drainAfterStopThrew };
  },
  async sessions_are_independent({ service, now }, expected) {
    const timeoutMs = expected.independence!.timeoutMs;
    const a = await service.open(format);
    const b = await service.open(format);
    const from = now();
    await a.write(tone(1000));
    await b.write(tone(1000));
    a.stop();
    const stoppedFrom = now();
    await bounded(a.drain(), timeoutMs, "drain of the stopped session");
    const stoppedDrainElapsedMs = now() - stoppedFrom;
    await bounded(b.drain(), timeoutMs, "drain of the other session");
    const otherDrainElapsedMs = now() - from;
    b.stop();
    return { stoppedDrainElapsedMs, otherDrainElapsedMs };
  },
  async unsupported_format_refused({ service }) {
    try {
      const session = await service.open({ ...format, sampleRate: 4000 });
      session.stop();
    } catch (error) {
      if (error instanceof IndeRunException) return { openRejection: error };
      throw error;
    }
    return {};
  }
};

function assertCase(expected: Expectations, observed: Observation): void {
  if (expected.afterOpen) {
    expect(observed.firstAudioDefinedAfterOpen).toBe(expected.afterOpen.firstAudioDefined);
  }
  if (expected.afterWrites) {
    expect(observed.firstAudioDefinedAfterWrites).toBe(expected.afterWrites.firstAudioDefined);
    if (expected.afterWrites.firstAudioAtMostMs !== undefined) {
      expect(observed.firstAudioMs).toBeLessThanOrEqual(expected.afterWrites.firstAudioAtMostMs);
    }
  }
  if (expected.drain) {
    expect(observed.drainElapsedMs).toBeGreaterThanOrEqual(expected.drain.elapsedAtLeastMs);
  }
  if (expected.stop) {
    expect(observed.stopThrew).toBe(expected.stop.throws);
    if (expected.stop.calls !== undefined) expect(observed.stopCalls).toBe(expected.stop.calls);
    if (expected.stop.writeSettlesWithinMs !== undefined) {
      expect(observed.writeSettledAfterStopMs).toBeLessThanOrEqual(
        expected.stop.writeSettlesWithinMs
      );
    }
  }
  if (expected.writeAfterStop) {
    expect(observed.writeAfterStopElapsedMs).toBeLessThanOrEqual(
      expected.writeAfterStop.elapsedAtMostMs
    );
    expect(observed.writeAfterStopThrew).toBe(expected.writeAfterStop.throws);
  }
  if (expected.drainAfterStop) {
    expect(observed.drainAfterStopElapsedMs).toBeLessThanOrEqual(
      expected.drainAfterStop.elapsedAtMostMs
    );
    expect(observed.drainAfterStopThrew).toBe(expected.drainAfterStop.throws);
  }
  if (expected.independence) {
    expect(observed.stoppedDrainElapsedMs).toBeLessThanOrEqual(
      expected.independence.stoppedDrainAtMostMs
    );
    expect(observed.otherDrainElapsedMs).toBeGreaterThanOrEqual(
      expected.independence.otherDrainAtLeastMs
    );
  }
  if (expected.openRejectsWith) {
    expect(observed.openRejection).toBeInstanceOf(IndeRunException);
    expect(observed.openRejection!.errorClass).toBe(expected.openRejectsWith.errorClass);
    expect(observed.openRejection!.details?.["code"]).toBe(expected.openRejectsWith.code);
  }
}

describe("audio output conformance", () => {
  it("implements every case in the shared catalog, and no others", () => {
    expect(Object.keys(handlers).sort()).toEqual(catalog.cases.map((entry) => entry.id).sort());
  });

  describe("fixture service", () => {
    for (const catalogCase of catalog.cases) {
      it(catalogCase.id, async () => {
        const fixture = createFixtureAudioOutput();
        assertCase(
          catalogCase.expect,
          await handlers[catalogCase.id]!(
            { service: fixture.service, now: fixture.now },
            catalogCase.expect
          )
        );
        if (catalogCase.id === "stop_discards_buffered_audio") {
          // 3000 ms at 24000 Hz: the buffered audio was discarded, not played.
          expect(fixture.sessions[0]!.discardedFrames).toBe(72000);
        }
      });
    }
  });

  describe("fixture session endings", () => {
    it("a write and a drain after interrupt throw its error", async () => {
      const fixture = createFixtureAudioOutput();
      const session = await fixture.service.open(format);
      await session.write(tone(200));
      const error = createUnavailable("Audio output was interrupted by the system.", {
        details: { code: "audio_output_interrupted" }
      });
      fixture.sessions[0]!.interrupt(error);
      await expect(session.write(tone(200))).rejects.toBe(error);
      await expect(session.drain()).rejects.toBe(error);
      expect(fixture.sessions[0]!.stopped).toBe(true);
      expect(fixture.sessions[0]!.writtenFrames).toBe(4800);
      expect(fixture.sessions[0]!.discardedFrames).toBe(4800);
    });

    it("a write and a drain after stop return without effect", async () => {
      const fixture = createFixtureAudioOutput();
      const session = await fixture.service.open(format);
      session.stop();
      await session.write(tone(200));
      await session.drain();
      expect(fixture.sessions[0]!.writtenFrames).toBe(0);
    });
  });
});
