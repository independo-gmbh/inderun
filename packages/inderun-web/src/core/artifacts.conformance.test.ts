import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import type {
  ArtifactReadRequest,
  MediaArtifact,
  StreamEvent,
  TaskOutput,
  TaskRequest,
  TaskResult
} from "@independo/inderun-contracts";
import { describe, expect, it } from "vitest";

import { IndeRun, IndeRunException } from "../index.js";
import {
  createUnavailable,
  ProviderRegistry,
  type ArtifactLimits,
  type ArtifactSpec,
  type ArtifactWriter,
  type ProviderAdapter,
  type ProviderStreamContext,
  type ProviderStreamEvent,
  type RunContext
} from "../provider.js";
import { createMockHostServices, drain } from "../test/stream-fakes.js";
import type { HostServices } from "./host.js";

/**
 * The Web half of the cross-SDK artifact-store catalog
 * (`contracts/fixtures/execution/artifact-lifecycle.json`, ADR 017). One handler per case id;
 * the guard test fails when the handler ids and the catalog ids differ.
 */

interface ReadExpectation {
  request: Partial<ArtifactReadRequest>;
  offset: number;
  length: number;
  totalBytes: number;
  done: boolean;
}

interface ReadRejection {
  request: Partial<ArtifactReadRequest>;
  errorClass: string;
  retryable?: boolean;
  code?: string;
  validationIssuePath?: string;
}

interface Expectations {
  output?: Record<string, unknown>;
  reads?: ReadExpectation[];
  readRejects?: ReadRejection[];
  runRejectsWith?: { errorClass: string; code?: string };
  runs?: string[];
  providerCallCounts?: Record<string, number>;
  attempts?: [string, string][];
  providerObservedCodes?: Record<string, string[]>;
  finishedReadable?: Record<string, boolean[]>;
  terminal?: { outcome?: string; absentOutput?: boolean };
  maxSerializedEventBytes?: number;
  rejectsBeforeRouting?: { errorClass: string; code: string };
  destinationWrites?: {
    destinationRef: string;
    mediaType: string;
    byteLength: number;
    bytesMatchPattern: boolean;
  }[];
}

interface CatalogCase {
  id: string;
  mode?: "stream";
  expect: Expectations;
}

const catalog = JSON.parse(
  readFileSync(
    join(
      dirname(fileURLToPath(import.meta.url)),
      "../../../../contracts/fixtures/execution/artifact-lifecycle.json"
    ),
    "utf8"
  )
) as { cases: CatalogCase[] };

const request: TaskRequest = {
  schemaVersion: "1.0",
  task: { kind: "text_to_speech" },
  speech: { text: "Hallo", locale: "de-AT" },
  delivery: { mode: "artifact", mediaTypes: ["audio/wav"] },
  constraints: { privacy: "local_required" }
};

/** byte[i] = i % 251 over [start, start + length). */
function pattern(start: number, length: number): Uint8Array {
  return Uint8Array.from({ length }, (_, index) => (start + index) % 251);
}

type Step =
  | { write: number }
  | { finish: true }
  | { returnFinished: number }
  /** Returns the first artifact this call finished, relabelled with another media type. */
  | { returnFinishedClaiming: string }
  | { returnForged: true }
  | { fail: true }
  | { waitForCancellation: true };

/** A provider scripted in the catalog's vocabulary, recording what it observed. */
class ArtifactFake implements ProviderAdapter {
  calls = 0;
  readonly finished: MediaArtifact[] = [];
  readonly observedCodes: string[] = [];
  /** Resolves once an artifact has been handed over. */
  readonly handedOver: Promise<void>;
  private markHandedOver: () => void = () => {};

  constructor(
    private readonly id: string,
    private readonly steps: Step[],
    private readonly spec: ArtifactSpec = { mediaType: "audio/wav" }
  ) {
    this.handedOver = new Promise((resolve) => (this.markHandedOver = resolve));
  }

  describe() {
    return {
      id: this.id,
      type: "local" as const,
      transport: "in_process" as const,
      supports: {
        run: true,
        streaming: true,
        realtime: false,
        tools: false,
        reasoningEvents: false,
        structuredOutput: false,
        multimodal: false
      },
      cancel: "hard" as const,
      tasks: ["text_to_speech"],
      taskCapabilities: [
        {
          kind: "text_to_speech",
          inputs: ["text" as const],
          interaction: { run: true, stream: true },
          cancel: "hard" as const,
          outputs: [{ delivery: "artifact" as const, mediaTypes: ["audio/wav"] }],
          locales: ["de-AT"]
        }
      ]
    };
  }

  async capabilities() {
    return { available: true };
  }

  async run(_request: TaskRequest, context: RunContext): Promise<TaskResult> {
    const output = await this.play(context);
    return {
      schemaVersion: "1.0",
      runId: context.runId,
      output: output!,
      finishReason: "stop",
      telemetry: { providerUsed: this.id, totalMs: 0 }
    };
  }

  async *stream(
    _request: TaskRequest,
    context: ProviderStreamContext
  ): AsyncGenerator<ProviderStreamEvent> {
    const output = await this.play(context);
    if (output !== undefined) yield { kind: "result", output };
  }

  private async play(context: RunContext | ProviderStreamContext): Promise<TaskOutput | undefined> {
    this.calls++;
    // `returnFinished` indexes the artifacts this call finished.
    const firstOfCall = this.finished.length;
    let writer: ArtifactWriter | undefined;
    let written = 0;
    const observe = <T>(action: () => T): T => {
      try {
        return action();
      } catch (error) {
        const code = (error as IndeRunException).details?.["code"];
        if (typeof code === "string") this.observedCodes.push(code);
        throw error;
      }
    };
    for (const step of this.steps) {
      if ("write" in step) {
        writer ??= context.artifacts.create(this.spec);
        const current = writer;
        observe(() => current.write(pattern(written, step.write)));
        written += step.write;
      } else if ("finish" in step) {
        writer ??= context.artifacts.create(this.spec);
        const current = writer;
        this.finished.push(observe(() => current.finish()));
        writer = undefined;
        written = 0;
        this.markHandedOver();
      } else if ("returnFinished" in step) {
        return { type: "artifact", artifact: this.finished[firstOfCall + step.returnFinished]! };
      } else if ("returnFinishedClaiming" in step) {
        return {
          type: "artifact",
          artifact: { ...this.finished[firstOfCall]!, mediaType: step.returnFinishedClaiming }
        };
      } else if ("returnForged" in step) {
        return {
          type: "artifact",
          artifact: {
            id: "art_forged",
            mediaType: "audio/wav",
            owner: "engine",
            lifetime: "until_disposed"
          }
        };
      } else if ("fail" in step) {
        throw createUnavailable("provider failed after handoff");
      } else {
        const signal = (context as ProviderStreamContext).signal;
        await new Promise<void>((resolve) => {
          if (signal.aborted) resolve();
          signal.addEventListener("abort", () => resolve(), { once: true });
        });
        return undefined;
      }
    }
    return undefined;
  }
}

interface Observation {
  engine: IndeRun;
  attempts?: { providerId: string; outcome: string }[];
  output?: TaskOutput;
  rejection?: IndeRunException;
  runOutcomes?: string[];
  events?: StreamEvent[];
  fakes: ArtifactFake[];
  destinationWrites?: { destinationRef: string; artifact: MediaArtifact; bytes: Uint8Array }[];
}

function engineWith(
  fakes: ArtifactFake[],
  limits?: ArtifactLimits,
  host: HostServices = createMockHostServices()
): IndeRun {
  const registry = new ProviderRegistry();
  for (const fake of fakes) registry.register(fake);
  return new IndeRun(registry, host, limits ? { artifacts: limits } : {});
}

async function runCase(
  fakes: ArtifactFake[],
  limits?: ArtifactLimits,
  host?: HostServices,
  runRequest: TaskRequest = request
): Promise<Observation> {
  const engine = engineWith(fakes, limits, host);
  try {
    const result = await engine.run(runRequest);
    return {
      engine,
      output: result.output,
      fakes,
      attempts: result.provenance?.attempts
    } as Observation;
  } catch (error) {
    return {
      engine,
      rejection: error as IndeRunException,
      fakes,
      attempts: (error as IndeRunException).provenance?.attempts
    } as Observation;
  }
}

const destinationRequest: TaskRequest = {
  ...request,
  delivery: { mode: "artifact", mediaTypes: ["audio/wav"], destinationRef: "dest_greeting" }
};

/**
 * A host whose destination service accepts every reference and records each write. With
 * `blockWrites`, a write waits for `release()`; `writeStarted` resolves when one begins.
 */
function destinationHost(options: { failWrites?: boolean; blockWrites?: boolean } = {}) {
  const writes: NonNullable<Observation["destinationWrites"]> = [];
  let markStarted = () => {};
  let release = () => {};
  const writeStarted = new Promise<void>((resolve) => (markStarted = resolve));
  const released = new Promise<void>((resolve) => (release = resolve));
  const host: HostServices = {
    ...createMockHostServices(),
    artifactDestinations: {
      accepts: async () => true,
      write: async (destinationRef, artifact, bytes) => {
        markStarted();
        if (options.blockWrites) await released;
        if (options.failWrites) throw new Error("disk full at /private/dest_greeting");
        writes.push({ destinationRef, artifact, bytes: bytes.slice() });
      }
    }
  };
  return { host, writes, writeStarted, release };
}

const handlers: Record<string, () => Promise<Observation>> = {
  async destination_unsupported_refused_before_routing() {
    const fake = new ArtifactFake("p1", [{ write: 10 }, { finish: true }, { returnFinished: 0 }]);
    return runCase([fake], undefined, createMockHostServices(), destinationRequest);
  },
  async destination_written_and_store_released() {
    const { host, writes } = destinationHost();
    const fake = new ArtifactFake("p1", [{ write: 1000 }, { finish: true }, { returnFinished: 0 }]);
    const observed = await runCase([fake], undefined, host, destinationRequest);
    return { ...observed, destinationWrites: writes };
  },
  async cancel_during_destination_write_is_cancelled() {
    const { host, writes, writeStarted, release } = destinationHost({ blockWrites: true });
    const fake = new ArtifactFake("p1", [{ write: 10 }, { finish: true }, { returnFinished: 0 }]);
    const engine = engineWith([fake], undefined, host);
    const { events, cancel } = await engine.stream(destinationRequest);
    const collector = drain(events);
    await writeStarted;
    cancel();
    release();
    const received = await collector;
    const terminal = received.find((event) => event.type === "terminal")!;
    const output = (terminal.payload as unknown as { output?: TaskOutput }).output;
    return {
      engine,
      fakes: [fake],
      events: received,
      destinationWrites: writes,
      ...(output ? { output } : {})
    };
  },
  async destination_write_failure_is_terminal() {
    const { host } = destinationHost({ failWrites: true });
    return runCase(
      [
        new ArtifactFake("p1", [{ write: 10 }, { finish: true }, { returnFinished: 0 }]),
        new ArtifactFake("p2", [{ write: 10 }, { finish: true }, { returnFinished: 0 }])
      ],
      undefined,
      host,
      destinationRequest
    );
  },
  read_full: () =>
    runCase([
      new ArtifactFake("p1", [{ write: 1000 }, { finish: true }, { returnFinished: 0 }], {
        mediaType: "audio/wav",
        durationMs: 500
      })
    ]),
  chunked_reads_cover_bytes_once: () =>
    runCase([
      new ArtifactFake("p1", [
        { write: 300 },
        { write: 300 },
        { write: 400 },
        { finish: true },
        { returnFinished: 0 }
      ])
    ]),
  read_is_bounded_by_the_engine_limit: () =>
    runCase([new ArtifactFake("p1", [{ write: 1000 }, { finish: true }, { returnFinished: 0 }])], {
      maxReadBytes: 256
    }),
  repeated_reads_identical: () =>
    runCase([new ArtifactFake("p1", [{ write: 1000 }, { finish: true }, { returnFinished: 0 }])]),
  read_at_end_is_empty_and_beyond_end_is_rejected: () =>
    runCase([new ArtifactFake("p1", [{ write: 1000 }, { finish: true }, { returnFinished: 0 }])]),
  async dispose_is_idempotent_then_not_found() {
    const observed = await runCase([
      new ArtifactFake("p1", [{ write: 10 }, { finish: true }, { returnFinished: 0 }])
    ]);
    await observed.engine.disposeArtifact(observed.output!.artifact!);
    await observed.engine.disposeArtifact(observed.output!.artifact!);
    return observed;
  },
  unknown_id_not_found: async () => ({ engine: engineWith([]), fakes: [] }),
  post_handoff_failure_is_terminal_and_disposes: () =>
    runCase([
      new ArtifactFake("p1", [{ write: 10 }, { finish: true }, { fail: true }]),
      new ArtifactFake("p2", [{ write: 10 }, { finish: true }, { returnFinished: 0 }])
    ]),
  stored_media_type_decides_the_match: () =>
    runCase([
      new ArtifactFake(
        "p1",
        [{ write: 10 }, { finish: true }, { returnFinishedClaiming: "audio/wav" }],
        { mediaType: "audio/mpeg" }
      ),
      new ArtifactFake("p2", [{ write: 10 }, { finish: true }, { returnFinished: 0 }])
    ]),
  too_large_is_pre_commit_and_falls_back: () =>
    runCase(
      [
        new ArtifactFake("p1", [{ write: 101 }, { finish: true }, { returnFinished: 0 }]),
        new ArtifactFake("p2", [{ write: 50 }, { finish: true }, { returnFinished: 0 }])
      ],
      { maxArtifactBytes: 100 }
    ),
  async store_full_refuses_handoff_until_disposed() {
    const fake = new ArtifactFake("p1", [{ write: 100 }, { finish: true }, { returnFinished: 0 }]);
    const engine = engineWith([fake], { maxStoreBytes: 150 });
    const runOutcomes: string[] = [];
    let rejection: IndeRunException | undefined;
    const first = await engine.run(request);
    runOutcomes.push("succeeded");
    await engine.run(request).then(
      () => runOutcomes.push("succeeded"),
      (error: unknown) => {
        rejection = error as IndeRunException;
        runOutcomes.push("rejected");
      }
    );
    await engine.disposeArtifact(first.output.artifact!);
    await engine.run(request).then(
      () => runOutcomes.push("succeeded"),
      () => runOutcomes.push("rejected")
    );
    return { engine, fakes: [fake], runOutcomes, ...(rejection ? { rejection } : {}) };
  },
  unreturned_artifacts_disposed: () =>
    runCase([
      new ArtifactFake("p1", [
        { write: 10 },
        { finish: true },
        { write: 20 },
        { finish: true },
        { returnFinished: 1 }
      ])
    ]),
  foreign_artifact_is_output_mismatch: () =>
    runCase([
      new ArtifactFake("p1", [{ returnForged: true }]),
      new ArtifactFake("p2", [{ write: 10 }, { finish: true }, { returnFinished: 0 }])
    ]),
  async cancelled_stream_disposes_artifact() {
    const fake = new ArtifactFake("p1", [
      { write: 10 },
      { finish: true },
      { waitForCancellation: true }
    ]);
    const engine = engineWith([fake]);
    const { events, cancel } = await engine.stream(request);
    const collector = drain(events);
    await fake.handedOver;
    cancel();
    return { engine, fakes: [fake], events: await collector };
  },
  async events_carry_no_media_bytes() {
    const fake = new ArtifactFake("p1", [
      { write: 1048576 },
      { finish: true },
      { returnFinished: 0 }
    ]);
    const engine = engineWith([fake]);
    const events = await drain((await engine.stream(request)).events);
    const terminal = events.find((event) => event.type === "terminal")!;
    const output = (terminal.payload as unknown as { output?: TaskOutput }).output;
    return { engine, fakes: [fake], events, ...(output ? { output } : {}) };
  }
};

async function assertCase(expected: Expectations, observed: Observation): Promise<void> {
  const { engine } = observed;
  const artifact = observed.output?.artifact;

  if (expected.output !== undefined) {
    expect(artifact, "expected an artifact output").toBeDefined();
    const { id, ...fields } = artifact!;
    expect(id).toMatch(/^.+$/);
    expect(fields).toEqual(expected.output);
  }
  for (const read of expected.reads ?? []) {
    const chunk = await engine.readArtifact({ artifactId: artifact!.id, ...read.request });
    expect({
      offset: chunk.offset,
      length: chunk.bytes.byteLength,
      totalBytes: chunk.totalBytes,
      done: chunk.done
    }).toEqual({
      offset: read.offset,
      length: read.length,
      totalBytes: read.totalBytes,
      done: read.done
    });
    expect(chunk.bytes).toEqual(pattern(read.offset, read.length));
  }
  for (const rejected of expected.readRejects ?? []) {
    const error = await engine
      .readArtifact({ artifactId: artifact?.id ?? "art_unknown", ...rejected.request })
      .then(
        () => undefined,
        (caught: unknown) => caught as IndeRunException
      );
    expect(error, "expected readArtifact to throw").toBeInstanceOf(IndeRunException);
    expect(error!.errorClass).toBe(rejected.errorClass);
    if (rejected.retryable !== undefined) expect(error!.retryable).toBe(rejected.retryable);
    if (rejected.code !== undefined) expect(error!.details?.["code"]).toBe(rejected.code);
    if (rejected.validationIssuePath !== undefined) {
      const issues = error!.details?.["validationIssues"] as { path: string }[];
      expect(issues.map((issue) => issue.path)).toContain(rejected.validationIssuePath);
    }
  }
  if (expected.runRejectsWith !== undefined) {
    expect(observed.rejection, "expected run() to throw").toBeInstanceOf(IndeRunException);
    expect(observed.rejection!.errorClass).toBe(expected.runRejectsWith.errorClass);
    if (expected.runRejectsWith.code !== undefined) {
      expect(observed.rejection!.details?.["code"]).toBe(expected.runRejectsWith.code);
    }
  }
  if (expected.runs !== undefined) expect(observed.runOutcomes).toEqual(expected.runs);
  for (const [providerId, count] of Object.entries(expected.providerCallCounts ?? {})) {
    expect(observed.fakes.find((fake) => fake.describe().id === providerId)?.calls).toBe(count);
  }
  if (expected.attempts !== undefined) {
    const attempts = (
      observed as Observation & { attempts?: { providerId: string; outcome: string }[] }
    ).attempts;
    expect(attempts?.map((attempt) => [attempt.providerId, attempt.outcome])).toEqual(
      expected.attempts
    );
  }
  for (const [providerId, codes] of Object.entries(expected.providerObservedCodes ?? {})) {
    expect(observed.fakes.find((fake) => fake.describe().id === providerId)?.observedCodes).toEqual(
      codes
    );
  }
  for (const [providerId, readable] of Object.entries(expected.finishedReadable ?? {})) {
    const fake = observed.fakes.find((candidate) => candidate.describe().id === providerId)!;
    const actual = await Promise.all(
      fake.finished.map((finished) =>
        engine.readArtifact({ artifactId: finished.id }).then(
          () => true,
          () => false
        )
      )
    );
    expect(actual).toEqual(readable);
  }
  if (expected.terminal !== undefined) {
    const terminal = observed.events?.find((event) => event.type === "terminal");
    const payload = terminal?.payload as unknown as Record<string, unknown>;
    if (expected.terminal.outcome !== undefined)
      expect(payload["outcome"]).toBe(expected.terminal.outcome);
    if (expected.terminal.absentOutput === true) expect(payload).not.toHaveProperty("output");
  }
  if (expected.rejectsBeforeRouting !== undefined) {
    expect(observed.rejection, "expected run() to throw").toBeInstanceOf(IndeRunException);
    expect(observed.rejection!.errorClass).toBe(expected.rejectsBeforeRouting.errorClass);
    expect(observed.rejection!.details?.["code"]).toBe(expected.rejectsBeforeRouting.code);
    expect(observed.attempts ?? []).toEqual([]);
  }
  if (expected.destinationWrites !== undefined) {
    expect(
      (observed.destinationWrites ?? []).map((write) => ({
        destinationRef: write.destinationRef,
        mediaType: write.artifact.mediaType,
        byteLength: write.bytes.byteLength,
        bytesMatchPattern:
          JSON.stringify([...write.bytes]) ===
          JSON.stringify([...pattern(0, write.bytes.byteLength)])
      }))
    ).toEqual(expected.destinationWrites);
  }
  if (expected.maxSerializedEventBytes !== undefined) {
    for (const event of observed.events ?? []) {
      expect(JSON.stringify(event).length).toBeLessThan(expected.maxSerializedEventBytes);
    }
  }
}

describe("artifact store conformance", () => {
  it("implements every case in the shared catalog, and no others", () => {
    expect(Object.keys(handlers).sort()).toEqual(catalog.cases.map((entry) => entry.id).sort());
  });

  for (const catalogCase of catalog.cases) {
    it(catalogCase.id, async () => {
      await assertCase(catalogCase.expect, await handlers[catalogCase.id]!());
    });
  }
});
