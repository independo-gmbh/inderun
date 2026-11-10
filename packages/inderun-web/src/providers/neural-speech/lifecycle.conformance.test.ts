import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import type {
  AudioOutputFormat,
  ExecutionProvenance,
  ModelPackage,
  PlaybackTiming,
  ProviderReadiness,
  StreamTerminalOutcome,
  TaskRequest
} from "@independo/inderun-contracts";
import { describe, expect, it } from "vitest";

import { ArtifactStore } from "../../core/artifacts.js";
import { createUnavailable, IndeRunException } from "../../core/errors.js";
import type { HostServices } from "../../core/host.js";
import type { RunContext } from "../../core/provider.js";
import {
  generateSpeech,
  IndeRun,
  prepare,
  speak,
  toSpeechRequest,
  type SpokenSpeech
} from "../../index.js";
import { ProviderRegistry } from "../../provider.js";
import {
  createFixtureAudioOutput,
  type FixtureAudioOutput,
  type FixtureAudioOutputSession
} from "../../test/audio-output-fixture.js";
import {
  createFakeStreamProvider,
  createWallClockHostServices,
  type FakeStreamProvider
} from "../../test/stream-fakes.js";
import {
  createFixtureNeuralSpeechRuntime,
  type FixtureNeuralSpeechRuntime,
  type FixtureNeuralSpeechRuntimeOptions
} from "./fixture-runtime.js";
import { NeuralSpeechWebProvider } from "./provider.js";
import type { NeuralSpeechRuntime, PcmChunk } from "./runtime.js";

/** Mirrors `$expectKeys` in the catalog; every key is optional. */
interface Expectations {
  outcome?: "completed" | "cancelled" | "error";
  commitCount?: number;
  commitAt?: { sessionsOpened: number; firstSessionWrites: number };
  sessions?: {
    count: number;
    first?: {
      writes?: number;
      stopped?: boolean;
      discardedFrames?: "some" | "none";
      playedFrames?: "all";
    };
  };
  fallbackAsked?: boolean;
  error?: { errorClass: string; code: string };
  timing?: {
    durationMsEquals?: "synthesized";
    firstChunkDefined?: boolean;
    firstAudioDefined?: boolean;
  };
  artifact?: {
    mediaType: string;
    byteLengthEquals?: "wav";
    header?: { sampleRate: number; channels: number; bitsPerSample: number; dataBytes: "2*frames" };
  };
  runtime?: { synthesizeCalls?: number; synthesizeCallsAtMost?: number; prepareCalls?: number };
  order?: { secondOpensAfterFirstStops: boolean };
  readiness?: { before: ProviderReadiness | null; after: ProviderReadiness | null };
}

interface CatalogCase {
  id: string;
  setup: string;
  timeoutMs: number;
  expect: Expectations;
}

const catalog = JSON.parse(
  readFileSync(
    join(
      dirname(fileURLToPath(import.meta.url)),
      "../../../../../contracts/fixtures/speech/neural-speech-lifecycle.json"
    ),
    "utf8"
  )
) as { format: AudioOutputFormat; package: ModelPackage; cases: CatalogCase[] };

const TEXT = "Hallo Welt. Wie geht es dir?";
const LOCALE = "de-AT";
/** The case's profile: [neural, fallback], or [neural] alone. */
const PROFILE = "neural";

/** One case's provider, its fixtures, and what they recorded. */
interface World {
  provider: NeuralSpeechWebProvider;
  runtime: FixtureNeuralSpeechRuntime;
  audio: FixtureAudioOutput;
  fallback: FakeStreamProvider | undefined;
  engine: IndeRun;
  hostServices: HostServices;
  /** Frames the runtime produced. */
  frames(): number;
  /** Errors the neural provider threw, in order. */
  errors: unknown[];
  /** How often the engine entered the neural provider's `stream()`. */
  streamCalls(): number;
  /** Whether the first session had stopped when the second was opened. */
  firstStoppedAtSecondOpen: boolean | undefined;
}

interface WorldOptions {
  runtime?: FixtureNeuralSpeechRuntimeOptions;
  /** Default true: the host has an `audioOutput`. */
  audioOutput?: boolean;
  /** Default true: the profile is [neural, fallback]. */
  fallback?: boolean;
  /** Interrupts each session with `audio_output_interrupted` once its first write is taken. */
  interruptAfterFirstWrite?: boolean;
}

function createWorld(options: WorldOptions = {}): World {
  const runtime = createFixtureNeuralSpeechRuntime(options.runtime);
  let frames = 0;
  const counting: NeuralSpeechRuntime = {
    availability: (pkg) => runtime.availability(pkg),
    prepare: (pkg) => runtime.prepare(pkg),
    async *synthesize(input): AsyncGenerator<PcmChunk> {
      for await (const chunk of runtime.synthesize(input)) {
        frames += chunk.samples.length;
        yield chunk;
      }
    }
  };
  const provider = new NeuralSpeechWebProvider({
    modelPackage: catalog.package,
    runtime: counting
  });

  const errors: unknown[] = [];
  let streamCalls = 0;
  const stream = provider.stream.bind(provider);
  provider.stream = async function* (request, context) {
    streamCalls += 1;
    try {
      yield* stream(request, context);
    } catch (error) {
      errors.push(error);
      throw error;
    }
  };
  const run = provider.run.bind(provider);
  provider.run = async (request, context) => {
    try {
      return await run(request, context);
    } catch (error) {
      errors.push(error);
      throw error;
    }
  };

  const audio = createFixtureAudioOutput();
  const world: World = {
    provider,
    runtime,
    audio,
    fallback: undefined,
    engine: undefined as unknown as IndeRun,
    hostServices: undefined as unknown as HostServices,
    frames: () => frames,
    errors,
    streamCalls: () => streamCalls,
    firstStoppedAtSecondOpen: undefined
  };

  const open = audio.service.open.bind(audio.service);
  audio.service.open = async (format, signal) => {
    if (audio.sessions.length === 1) world.firstStoppedAtSecondOpen = audio.sessions[0]!.stopped;
    const session = await open(format, signal);
    if (options.interruptAfterFirstWrite === true) interruptAfterFirstWrite(audio.sessions.at(-1)!);
    return session;
  };

  world.hostServices = {
    ...createWallClockHostServices(),
    ...(options.audioOutput !== false ? { audioOutput: audio.service } : {})
  };
  const registry = new ProviderRegistry();
  registry.register(provider);
  if (options.fallback !== false) {
    world.fallback = createFakeStreamProvider("fallback", {
      task: "text_to_speech",
      script: [{ event: { kind: "result", output: { type: "playback", playback: {} } } }]
    });
    registry.register(world.fallback);
  }
  // A named profile, because `auto` cannot be redefined and ranks equal targets by id, which
  // would put "fallback" first.
  world.engine = new IndeRun(registry, world.hostServices, {
    modelProfiles: {
      [PROFILE]: [provider.id, ...(world.fallback !== undefined ? ["fallback"] : [])]
    }
  });
  return world;
}

function interruptAfterFirstWrite(session: FixtureAudioOutputSession): void {
  const write = session.write.bind(session);
  session.write = async (samples) => {
    await write(samples);
    if (session.writes.length === 1) {
      session.interrupt(
        createUnavailable("Audio output was interrupted by the system.", {
          details: { code: "audio_output_interrupted" }
        })
      );
    }
  };
}

function bounded<T>(promise: Promise<T>, ms: number, label: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${label} did not settle within ${ms} ms`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

async function until(condition: () => boolean, ms: number, label: string): Promise<void> {
  const deadline = Date.now() + ms;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error(`${label} did not happen within ${ms} ms`);
    await new Promise((resolve) => setTimeout(resolve, 1));
  }
}

function speechRequest(overrides: Partial<TaskRequest> = {}): TaskRequest {
  return {
    schemaVersion: "1.0",
    task: { kind: "text_to_speech" },
    speech: { text: TEXT, locale: LOCALE },
    delivery: { mode: "playback" },
    ...overrides
  };
}

/** A `RunContext` for a direct provider call, whose `commit()` records the fixture's state. */
function directContext(world: World, voice?: RunContext["voice"]) {
  let commitAt: Observation["commitAt"];
  let commits = 0;
  const commit = () => {
    commits += 1;
    commitAt ??= {
      sessionsOpened: world.audio.sessions.length,
      firstSessionWrites: world.audio.sessions[0]?.writes.length ?? 0
    };
    return true;
  };
  const context: RunContext = {
    runId: "direct-run",
    hostServices: world.hostServices,
    ...(voice !== undefined ? { voice } : {}),
    commit,
    artifacts: new ArtifactStore().attempt(commit)
  };
  return { context, commitCount: () => (commits > 0 ? 1 : 0), commitAt: () => commitAt };
}

/** What a speak run ended with, from the facade's result or rejection. */
interface Ending {
  outcome: StreamTerminalOutcome["outcome"];
  provenance?: ExecutionProvenance;
  error?: IndeRunException;
}

async function ending(playback: { result: Promise<SpokenSpeech> }, ms: number): Promise<Ending> {
  try {
    const spoken = await bounded(playback.result, ms, "speak");
    return {
      outcome: spoken.outcome.outcome,
      ...(spoken.provenance !== undefined ? { provenance: spoken.provenance } : {})
    };
  } catch (error) {
    if (!(error instanceof IndeRunException)) throw error;
    return {
      outcome: "error",
      error,
      ...(error.provenance !== undefined ? { provenance: error.provenance } : {})
    };
  }
}

function speakText(world: World, text = TEXT) {
  return speak(world.engine, { text, locale: LOCALE, model: PROFILE });
}

/** Whether the engine's provenance reports the neural attempt committed. */
function neuralCommits(world: World, provenance: ExecutionProvenance | undefined): number {
  const attempt = provenance?.attempts.find((entry) => entry.providerId === world.provider.id);
  return attempt?.committed === true ? 1 : 0;
}

function observedError(error: unknown): Observation["error"] {
  if (!(error instanceof IndeRunException)) return undefined;
  return { errorClass: error.errorClass, code: error.details?.["code"] };
}

interface Observation {
  world: World;
  outcome?: Ending["outcome"];
  commitCount?: number;
  commitAt?: { sessionsOpened: number; firstSessionWrites: number };
  fallbackAsked?: boolean;
  error?: { errorClass: string; code: unknown };
  timing?: PlaybackTiming;
  artifact?: { mediaType: string; bytes: Uint8Array };
  readiness?: { before: ProviderReadiness | null; after: ProviderReadiness | null };
  secondOpensAfterFirstStops?: boolean;
}

/** The run `playback_commits_before_first_write` and `playback_reports_timing` share. */
async function directPlayback(catalogCase: CatalogCase): Promise<Observation> {
  const world = createWorld();
  const direct = directContext(world);
  const result = await bounded(
    world.provider.run(speechRequest(), direct.context),
    catalogCase.timeoutMs,
    "direct run"
  );
  return {
    world,
    commitCount: direct.commitCount(),
    ...(direct.commitAt() !== undefined ? { commitAt: direct.commitAt()! } : {}),
    ...(result.output.playback?.timing !== undefined
      ? { timing: result.output.playback.timing }
      : {})
  };
}

async function readAll(engine: IndeRun, artifactId: string, ms: number): Promise<Uint8Array> {
  const parts: Uint8Array[] = [];
  let offset = 0;
  for (;;) {
    const chunk = await bounded(engine.readArtifact({ artifactId, offset }), ms, "readArtifact");
    parts.push(chunk.bytes);
    offset += chunk.bytes.byteLength;
    if (chunk.done) break;
  }
  const bytes = new Uint8Array(offset);
  let at = 0;
  for (const part of parts) {
    bytes.set(part, at);
    at += part.byteLength;
  }
  return bytes;
}

async function readiness(world: World): Promise<ProviderReadiness | null> {
  const snapshot = (await world.engine.checkCapabilities()).find(
    (entry) => entry.providerId === world.provider.id
  );
  return snapshot?.capabilities.taskCapabilities?.[0]?.readiness ?? null;
}

/** One handler per catalog id; every wait is bounded by the case's `timeoutMs`. */
const handlers: Record<string, (catalogCase: CatalogCase) => Promise<Observation>> = {
  playback_commits_before_first_write: directPlayback,
  playback_reports_timing: directPlayback,

  async cancel_while_waiting_plays_nothing({ timeoutMs }) {
    const world = createWorld({ runtime: { delayMs: 40 } });
    const textA = "Heute scheint die Sonne über den Bergen, und wir gehen raus.";
    expect(textA).toHaveLength(60);

    const a = await speakText(world, textA);
    await until(
      () => (world.audio.sessions[0]?.writes.length ?? 0) > 0,
      timeoutMs,
      "A's first write"
    );
    const b = await speakText(world);
    await until(() => world.streamCalls() === 2, timeoutMs, "B reaching the provider");
    expect(world.audio.sessions[0]!.stopped).toBe(false);
    b.cancel();

    const [endA, endB] = await Promise.all([ending(a, timeoutMs), ending(b, timeoutMs)]);
    expect(endA.outcome).toBe("completed");
    return {
      world,
      outcome: endB.outcome,
      commitCount: neuralCommits(world, endB.provenance)
    };
  },

  async cancel_mid_stream_stops_audio_once({ timeoutMs }) {
    const world = createWorld({ runtime: { delayMs: 5 } });
    const text =
      "Der Wind weht leise über die Wiesen am Rand des alten Dorfes, wo die Kinder spielen und lachen. Am Abend kehren alle müde nach Hause zurück und erzählen einander von den kleinen Abenteuern des Tages!!";
    expect(text).toHaveLength(200);

    // Driven through stream() rather than speak(), which stops reading at the first terminal.
    const run = await world.engine.stream(
      toSpeechRequest({ text, locale: LOCALE, model: PROFILE }, "playback")
    );
    const terminals: StreamTerminalOutcome[] = [];
    const consumed = (async () => {
      for await (const event of run.events) {
        if (event.type === "terminal") {
          terminals.push(event.payload as unknown as StreamTerminalOutcome);
        }
      }
    })();
    await until(() => (world.audio.sessions[0]?.writes.length ?? 0) > 0, timeoutMs, "first write");
    run.cancel();
    await bounded(consumed, timeoutMs, "stream");

    expect(terminals).toHaveLength(1);
    return {
      world,
      outcome: terminals[0]!.outcome,
      commitCount: neuralCommits(world, terminals[0]!.provenance)
    };
  },

  async missing_audio_output_refuses_before_commit({ timeoutMs }) {
    const world = createWorld({ audioOutput: false });
    const end = await ending(await speakText(world), timeoutMs);
    const attempt = end.provenance?.attempts.find(
      (entry) => entry.providerId === world.provider.id
    );
    const error = observedError(world.errors[0]);
    // The provenance records the refusal's class; the provider's own error carries its code.
    expect(attempt?.errorClass).toBe(error?.errorClass);
    return {
      world,
      outcome: end.outcome,
      fallbackAsked: world.fallback!.callCount() > 0,
      commitCount: neuralCommits(world, end.provenance),
      ...(error !== undefined ? { error } : {})
    };
  },

  async unknown_voice_refused_before_commit({ timeoutMs }) {
    const world = createWorld();
    const direct = directContext(world, { id: "ghost", locale: LOCALE });
    let error: Observation["error"];
    try {
      await bounded(world.provider.run(speechRequest(), direct.context), timeoutMs, "direct run");
    } catch (thrown) {
      error = observedError(thrown);
    }
    return { world, commitCount: direct.commitCount(), ...(error !== undefined ? { error } : {}) };
  },

  async artifact_is_wav_of_the_samples({ timeoutMs }) {
    const world = createWorld();
    const generated = await bounded(
      generateSpeech(world.engine, { text: TEXT, locale: LOCALE, model: PROFILE }),
      timeoutMs,
      "generateSpeech"
    );
    return {
      world,
      outcome: "completed",
      commitCount: neuralCommits(world, generated.provenance),
      artifact: {
        mediaType: generated.artifact.mediaType,
        bytes: await readAll(world.engine, generated.artifact.id, timeoutMs)
      }
    };
  },

  async artifact_over_cap_fails_before_commit({ timeoutMs }) {
    const world = createWorld({ runtime: { msPerCharacter: 50000 }, fallback: false });
    const text = "Servus!";
    expect(text).toHaveLength(7);
    try {
      await bounded(
        generateSpeech(world.engine, { text, locale: LOCALE, model: PROFILE }),
        timeoutMs,
        "generateSpeech"
      );
    } catch (error) {
      if (!(error instanceof IndeRunException)) throw error;
      return {
        world,
        outcome: "error",
        commitCount: neuralCommits(world, error.provenance),
        error: observedError(error)!
      };
    }
    return { world, outcome: "completed" };
  },

  async interruption_after_commit_fails_without_fallback({ timeoutMs }) {
    const world = createWorld({ interruptAfterFirstWrite: true });
    const end = await ending(await speakText(world), timeoutMs);
    return {
      world,
      outcome: end.outcome,
      commitCount: neuralCommits(world, end.provenance),
      fallbackAsked: world.fallback!.callCount() > 0,
      ...(end.error !== undefined ? { error: observedError(end.error)! } : {})
    };
  },

  async utterances_play_one_at_a_time({ timeoutMs }) {
    const world = createWorld({ runtime: { delayMs: 2 } });
    const first = await speakText(world);
    const second = await speakText(world);
    const endings = await Promise.all([ending(first, timeoutMs), ending(second, timeoutMs)]);
    const failed = endings.find((end) => end.outcome !== "completed");
    return {
      world,
      outcome: failed?.outcome ?? "completed",
      ...(world.firstStoppedAtSecondOpen !== undefined
        ? { secondOpensAfterFirstStops: world.firstStoppedAtSecondOpen }
        : {})
    };
  },

  async capabilities_never_load({ timeoutMs }) {
    const world = createWorld();
    await bounded(world.engine.checkCapabilities(), timeoutMs, "checkCapabilities");
    const before = await bounded(readiness(world), timeoutMs, "checkCapabilities");
    expect(world.runtime.prepareCalls).toBe(0);

    const preparation = await prepare(world.engine);
    await bounded(preparation.result, timeoutMs, "prepare");
    const after = await bounded(readiness(world), timeoutMs, "checkCapabilities");
    return { world, readiness: { before, after } };
  }
};

function assertCase(expected: Expectations, observed: Observation): void {
  const { world } = observed;
  if (expected.outcome !== undefined) expect(observed.outcome).toBe(expected.outcome);
  if (expected.commitCount !== undefined) expect(observed.commitCount).toBe(expected.commitCount);
  if (expected.commitAt !== undefined) expect(observed.commitAt).toEqual(expected.commitAt);
  if (expected.sessions !== undefined) {
    expect(world.audio.sessions).toHaveLength(expected.sessions.count);
    const first = expected.sessions.first;
    if (first !== undefined) {
      const session = world.audio.sessions[0]!;
      if (first.writes !== undefined) {
        expect(session.writes.length).toBeGreaterThanOrEqual(first.writes);
      }
      if (first.stopped !== undefined) expect(session.stopped).toBe(first.stopped);
      if (first.discardedFrames === "some") expect(session.discardedFrames).toBeGreaterThan(0);
      if (first.discardedFrames === "none") expect(session.discardedFrames).toBe(0);
      if (first.playedFrames === "all") {
        expect(session.writtenFrames).toBeGreaterThan(0);
        expect(session.playedFrames).toBe(session.writtenFrames);
      }
    }
  }
  if (expected.fallbackAsked !== undefined) {
    expect(observed.fallbackAsked).toBe(expected.fallbackAsked);
  }
  if (expected.error !== undefined) {
    expect(observed.error).toEqual({
      errorClass: expected.error.errorClass,
      code: expected.error.code
    });
  }
  if (expected.timing !== undefined) {
    const timing = observed.timing ?? {};
    const { firstChunkMs, firstAudioMs, durationMs } = timing;
    if (expected.timing.durationMsEquals === "synthesized") {
      expect(durationMs).toBeCloseTo(
        (world.frames() / catalog.package.speech!.sampleRate) * 1000,
        6
      );
    }
    if (expected.timing.firstChunkDefined !== undefined) {
      expect(firstChunkMs !== undefined).toBe(expected.timing.firstChunkDefined);
    }
    if (expected.timing.firstAudioDefined !== undefined) {
      expect(firstAudioMs !== undefined).toBe(expected.timing.firstAudioDefined);
    }
  }
  if (expected.artifact !== undefined) {
    const artifact = observed.artifact!;
    const frames = world.frames();
    expect(artifact.mediaType).toBe(expected.artifact.mediaType);
    if (expected.artifact.byteLengthEquals === "wav") {
      expect(artifact.bytes.byteLength).toBe(44 + 2 * frames);
    }
    const header = expected.artifact.header;
    if (header !== undefined) {
      const view = new DataView(
        artifact.bytes.buffer,
        artifact.bytes.byteOffset,
        artifact.bytes.byteLength
      );
      expect(view.getUint32(24, true)).toBe(header.sampleRate);
      expect(view.getUint16(22, true)).toBe(header.channels);
      expect(view.getUint16(34, true)).toBe(header.bitsPerSample);
      expect(view.getUint32(40, true)).toBe(2 * frames);
    }
  }
  if (expected.runtime !== undefined) {
    const { synthesizeCalls, synthesizeCallsAtMost, prepareCalls } = expected.runtime;
    if (synthesizeCalls !== undefined) {
      expect(world.runtime.synthesized).toHaveLength(synthesizeCalls);
    }
    if (synthesizeCallsAtMost !== undefined) {
      expect(world.runtime.synthesized.length).toBeLessThanOrEqual(synthesizeCallsAtMost);
    }
    if (prepareCalls !== undefined) expect(world.runtime.prepareCalls).toBe(prepareCalls);
  }
  if (expected.order !== undefined) {
    expect(observed.secondOpensAfterFirstStops).toBe(expected.order.secondOpensAfterFirstStops);
  }
  if (expected.readiness !== undefined) {
    expect(observed.readiness).toEqual(expected.readiness);
  }
}

describe("neural speech lifecycle conformance", () => {
  it("implements every case in the shared catalog, and no others", () => {
    expect(Object.keys(handlers).sort()).toEqual(catalog.cases.map((entry) => entry.id).sort());
  });

  for (const catalogCase of catalog.cases) {
    it(catalogCase.id, async () => {
      assertCase(catalogCase.expect, await handlers[catalogCase.id]!(catalogCase));
    });
  }
});
