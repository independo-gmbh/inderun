import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import type {
  StreamEvent,
  TaskOutput,
  TaskRequest,
  TaskResult
} from "@independo/inderun-contracts";
import { describe, expect, it } from "vitest";

import { IndeRun } from "./engine.js";
import { createCapabilityMismatch, createUnavailable, IndeRunException } from "./errors.js";
import type {
  ProviderAdapter,
  ProviderDescriptor,
  ProviderDynamicCapabilities,
  ProviderStreamContext,
  ProviderStreamEvent,
  RunContext,
  StreamRun
} from "./provider.js";
import { ProviderRegistry } from "./registry.js";
import type { RoutePlanner } from "./route-planner.js";
import { Router } from "./router.js";
import {
  completeControlOutcomes,
  completeOutputControls,
  controlMethodFor,
  type ControlApplicationPlan,
  type SpeechControlOutcome
} from "./task-profiles.js";
import { createMockHostServices, drain } from "../test/stream-fakes.js";

/**
 * The Web half of the three ADR 025 scenario catalogs in `contracts/fixtures/execution/`:
 * `control-plan-integrity.json` (a plan inconsistent with the request stops the run before any
 * attempt), `control-outcomes.json` (the engine validates and completes the provider's control
 * records) and `control-execution.json` (plans reach the attempt; commit, fallback and
 * cancellation keep their guarantees). One handler per case id each; the guard tests fail when
 * the handler ids and the catalog ids differ.
 */

function load<T>(name: string): { cases: T[] } {
  return JSON.parse(
    readFileSync(
      fileURLToPath(new URL(`../../../../contracts/fixtures/execution/${name}`, import.meta.url)),
      "utf8"
    )
  ) as { cases: T[] };
}

type ControlId = ControlApplicationPlan["id"];

// --- the fake --------------------------------------------------------------------------------

type Step =
  | "refuse_control"
  | "commit"
  | "report_applied"
  | "finish"
  | "fail"
  | "wait_for_cancellation"
  /** Reports exactly these records (control-outcomes cases). */
  | { report: SpeechControlOutcome[] }
  /** Finishes with exactly these records (control-outcomes cases). */
  | { finishWith: SpeechControlOutcome[] }
  /** Finishes with an output that has no speech section (control-outcomes cases). */
  | "finish_without_speech";

const RANGES: Record<ControlId, { min: number; max: number }> = {
  "speech.speakingRate": { min: 0.5, max: 2 },
  "speech.pitch": { min: 0.5, max: 2 },
  "playback.volume": { min: 0, max: 1 }
};

/** The record a fake reports for one plan entry: applied as planned, or omitted with its reason. */
function recordFor(entry: ControlApplicationPlan): SpeechControlOutcome {
  return entry.decision === "apply"
    ? {
        id: entry.id,
        requested: entry.value,
        status: "applied",
        effective: entry.value,
        method: controlMethodFor(entry.id)
      }
    : { id: entry.id, requested: entry.value, status: "not_applied", reason: entry.reason! };
}

/**
 * A speech provider in the catalogs' vocabulary (see `control-execution.json` `$comment` and
 * `$scriptSteps`): it declares the given playback controls with task-level states, lists no
 * voices, and runs its script, recording what it was handed and what `commit()` returned.
 */
class ControlFake implements ProviderAdapter {
  calls = 0;
  readonly receivedControls: Array<ControlApplicationPlan[] | undefined> = [];
  readonly commitResults: boolean[] = [];
  /** Resolves once the fake has reached `wait_for_cancellation`. */
  readonly waiting: Promise<void>;
  private markWaiting: () => void = () => {};

  constructor(
    readonly id: string,
    private readonly controls: readonly ControlId[],
    private readonly script: readonly Step[]
  ) {
    this.waiting = new Promise((resolve) => (this.markWaiting = resolve));
  }

  describe(): ProviderDescriptor {
    return {
      id: this.id,
      type: "local",
      transport: "in_process",
      supports: {
        run: true,
        streaming: true,
        realtime: false,
        tools: false,
        reasoningEvents: false,
        structuredOutput: false,
        multimodal: false
      },
      cancel: "soft",
      tasks: ["text_to_speech"],
      taskCapabilities: [
        {
          kind: "text_to_speech",
          inputs: ["text"],
          interaction: { run: true, stream: true },
          cancel: "soft",
          outputs: [{ delivery: "playback" }],
          locales: ["de-AT"],
          ...(this.controls.length > 0
            ? {
                controls: this.controls.map((id) => ({
                  id,
                  valueKind: "number" as const,
                  phase: id === "playback.volume" ? ("playback" as const) : ("synthesis" as const),
                  lifetime: "utterance" as const,
                  deliveries: ["playback" as const]
                }))
              }
            : {})
        }
      ]
    };
  }

  async capabilities(): Promise<ProviderDynamicCapabilities> {
    return {
      available: true,
      ...(this.controls.length > 0
        ? {
            taskCapabilities: [
              {
                kind: "text_to_speech",
                controlStates: this.controls.map((id) => ({
                  id,
                  delivery: "playback" as const,
                  available: true,
                  range: RANGES[id]
                }))
              }
            ]
          }
        : {})
    };
  }

  async run(request: TaskRequest, context: RunContext): Promise<TaskResult> {
    for await (const event of this.steps(context)) {
      if (event.kind === "result") {
        return {
          schemaVersion: "1.1",
          runId: request.requestId ?? "run",
          output: event.output,
          finishReason: "stop",
          telemetry: { providerUsed: this.id, totalMs: 0 }
        };
      }
    }
    throw new Error(`${this.id} ended its run without a result`);
  }

  stream(
    _request: TaskRequest,
    context: ProviderStreamContext
  ): AsyncIterable<ProviderStreamEvent> {
    return this.steps(context, context.signal);
  }

  private async *steps(
    context: RunContext,
    signal?: AbortSignal
  ): AsyncGenerator<ProviderStreamEvent> {
    this.calls++;
    this.receivedControls.push(context.controls);
    const plan = context.controls ?? [];
    const applied = () => plan.filter((entry) => entry.decision === "apply").map(recordFor);
    const finish = (controls: SpeechControlOutcome[] | undefined): ProviderStreamEvent => ({
      kind: "result",
      output: {
        type: "playback",
        playback: {},
        speech: { locale: "de-AT", ...(controls !== undefined ? { controls } : {}) }
      },
      finishReason: "stop"
    });
    for (const step of this.script) {
      if (typeof step === "object") {
        if ("report" in step) context.reportSpeech({ locale: "de-AT", controls: step.report });
        else yield finish(step.finishWith);
        continue;
      }
      switch (step) {
        case "refuse_control":
          throw createCapabilityMismatch("The platform refused a required speech control.", {
            providerId: this.id,
            details: { code: "speech_control_unsupported" }
          });
        case "commit":
          this.commitResults.push(context.commit());
          break;
        case "report_applied":
          context.reportSpeech({ locale: "de-AT", controls: applied() });
          break;
        case "finish":
          yield finish(context.controls === undefined ? undefined : plan.map(recordFor));
          break;
        case "finish_without_speech":
          yield {
            kind: "result",
            output: { type: "playback", playback: {} },
            finishReason: "stop"
          };
          break;
        case "fail":
          throw createUnavailable("The fake failed.", { providerId: this.id, retryable: false });
        case "wait_for_cancellation":
          this.markWaiting();
          await new Promise<void>((resolve) => {
            if (signal === undefined || signal.aborted) return resolve();
            signal.addEventListener("abort", () => resolve(), { once: true });
          });
          break;
      }
    }
  }
}

// --- running a case ----------------------------------------------------------------------------

type Mode = "run" | "stream";

interface Observation {
  outcome: "completed" | "failed" | "cancelled";
  output?: TaskOutput;
  error?: IndeRunException | { errorClass: string; details?: Record<string, unknown> };
  provenance?: NonNullable<TaskResult["provenance"]>;
  events?: StreamEvent[];
  terminal?: Record<string, unknown>;
}

function engineWith(fakes: ControlFake[], planner?: RoutePlanner): IndeRun {
  const registry = new ProviderRegistry();
  for (const fake of fakes) registry.register(fake);
  const engine = new IndeRun(registry, createMockHostServices());
  if (planner !== undefined) Reflect.set(engine, "router", new Router(registry, planner));
  return engine;
}

/**
 * Runs `request` in `mode`. A stream is drained to its terminal; with `cancelWhen`, it is
 * cancelled once `cancelWhen` resolves.
 */
async function observe(
  engine: IndeRun,
  request: TaskRequest,
  mode: Mode,
  cancelWhen?: Promise<void>
): Promise<Observation> {
  if (mode === "run") {
    try {
      const result = await engine.run(request);
      return { outcome: "completed", output: result.output, provenance: result.provenance! };
    } catch (error) {
      const exception = error as IndeRunException;
      return { outcome: "failed", error: exception, provenance: exception.provenance! };
    }
  }
  let run: StreamRun;
  try {
    run = await engine.stream(request);
  } catch (error) {
    const exception = error as IndeRunException;
    return { outcome: "failed", error: exception, provenance: exception.provenance! };
  }
  const draining = drain(run.events);
  if (cancelWhen !== undefined) {
    await cancelWhen;
    run.cancel();
  }
  const events = await draining;
  const terminal = events.at(-1)!.payload as Record<string, unknown>;
  const outcome = terminal.outcome as string;
  return {
    outcome: outcome === "error" ? "failed" : (outcome as Observation["outcome"]),
    ...("output" in terminal ? { output: terminal.output as TaskOutput } : {}),
    ...(outcome === "error" ? { error: terminal.error as Observation["error"] } : {}),
    provenance: terminal.provenance as Observation["provenance"],
    events,
    terminal
  };
}

// --- control-plan-integrity.json ---------------------------------------------------------------

interface PlanIntegrityCase {
  id: string;
  request: TaskRequest;
  candidateControls: ControlApplicationPlan[] | null;
  fallbackCandidateControls?: ControlApplicationPlan[] | null;
  expected: { refused: boolean; errorClass?: string; detailsCode?: string; attemptCount?: number };
}

const planIntegrity = load<PlanIntegrityCase>("control-plan-integrity.json");

/** A planner that returns the case's candidate(s) verbatim, a missing plan as an absent key. */
function injectedPlanner(entry: PlanIntegrityCase): RoutePlanner {
  const candidate = (providerId: string, order: number, controls: unknown) => ({
    providerId,
    order,
    ...(controls === null ? {} : { controls: controls as ControlApplicationPlan[] })
  });
  const candidates = [candidate("tts", 0, entry.candidateControls)];
  if ("fallbackCandidateControls" in entry) {
    candidates.push(candidate("tts_fallback", 1, entry.fallbackCandidateControls));
  }
  return {
    async planRoute() {
      return {
        routePlan: {
          selectedProviderId: "tts",
          fallbackProviderIds: candidates.slice(1).map((c) => c.providerId),
          candidates,
          rejectedProviders: [],
          explanation: { summary: "injected" }
        }
      };
    }
  };
}

async function runPlanIntegrityCase(entry: PlanIntegrityCase): Promise<void> {
  for (const mode of ["run", "stream"] as const) {
    const fakes = [
      new ControlFake("tts", [], ["commit", "finish"]),
      new ControlFake("tts_fallback", [], ["commit", "finish"])
    ];
    const observation = await observe(
      engineWith(fakes, injectedPlanner(entry)),
      entry.request,
      mode
    );
    if (!entry.expected.refused) {
      expect(observation.outcome, mode).toBe("completed");
      expect(fakes[0]!.receivedControls, mode).toEqual([entry.candidateControls ?? undefined]);
      continue;
    }
    expect(observation.outcome, mode).toBe("failed");
    expect(observation.error).toBeInstanceOf(IndeRunException);
    expect(observation.error!.errorClass, mode).toBe(entry.expected.errorClass);
    expect(observation.error!.details?.code, mode).toBe(entry.expected.detailsCode);
    expect(observation.provenance!.attemptCount, mode).toBe(entry.expected.attemptCount);
    expect(
      fakes.map((fake) => fake.calls),
      mode
    ).toEqual([0, 0]);
  }
}

const planIntegrityHandlers: Record<string, (entry: PlanIntegrityCase) => Promise<void>> = {
  consistent_plan: runPlanIntegrityCase,
  no_controls_no_plan: runPlanIntegrityCase,
  required_plan_missing: runPlanIntegrityCase,
  required_plan_empty: runPlanIntegrityCase,
  required_plan_omitted: runPlanIntegrityCase,
  plan_value_differs: runPlanIntegrityCase,
  plan_requirement_differs: runPlanIntegrityCase,
  preferred_plan_missing: runPlanIntegrityCase,
  plan_for_unrequested_control: runPlanIntegrityCase,
  plan_without_request: runPlanIntegrityCase,
  duplicate_plan_entry: runPlanIntegrityCase,
  fallback_candidate_inconsistent: runPlanIntegrityCase,
  omit_without_reason: runPlanIntegrityCase,
  apply_with_reason: runPlanIntegrityCase
};

// --- control-outcomes.json -------------------------------------------------------------------

interface OutcomeCase {
  id: string;
  request: TaskRequest;
  /** Null: the provider's output has no speech section at all. */
  reported: SpeechControlOutcome[] | null;
  cancelled?: boolean;
  expected: {
    failed: boolean;
    controls?: SpeechControlOutcome[];
    errorClass?: string;
    detailsCode?: string;
  };
}

const outcomes = load<OutcomeCase>("control-outcomes.json");
const ALL_CONTROLS: ControlId[] = ["speech.speakingRate", "speech.pitch", "playback.volume"];

/** A completed run (both modes) whose provider reports the case's records in its output. */
async function runCompletedOutcomeCase(entry: OutcomeCase): Promise<void> {
  for (const mode of ["run", "stream"] as const) {
    const fake = new ControlFake("tts", ALL_CONTROLS, ["commit", { finishWith: entry.reported! }]);
    const observation = await observe(engineWith([fake]), entry.request, mode);
    // The helper the engine calls gives the same answer on its own.
    const direct = completeControlOutcomes(entry.request, entry.reported!, "completed", "tts");
    if (entry.expected.failed) {
      expect(observation.outcome, mode).toBe("failed");
      expect(observation.error!.errorClass, mode).toBe(entry.expected.errorClass);
      expect(observation.error!.details?.code, mode).toBe(entry.expected.detailsCode);
      expect(direct).toBeInstanceOf(IndeRunException);
    } else {
      expect(observation.outcome, mode).toBe("completed");
      expect(observation.output!.speech!.controls, mode).toEqual(entry.expected.controls);
      expect(direct).toEqual(entry.expected.controls);
    }
    // Nothing is replayed after a failure that followed the commit.
    expect(fake.calls, mode).toBe(1);
  }
}

/** A completed run (both modes) whose provider's output has no speech section at all. */
async function runNoSpeechSectionCase(entry: OutcomeCase): Promise<void> {
  expect(entry.reported).toBeNull();
  for (const mode of ["run", "stream"] as const) {
    const fake = new ControlFake("tts", ALL_CONTROLS, ["commit", "finish_without_speech"]);
    const observation = await observe(engineWith([fake]), entry.request, mode);
    const direct = completeOutputControls(entry.request, { type: "playback", playback: {} }, "tts");
    if (entry.expected.failed) {
      expect(observation.outcome, mode).toBe("failed");
      expect(observation.error!.errorClass, mode).toBe(entry.expected.errorClass);
      expect(observation.error!.details?.code, mode).toBe(entry.expected.detailsCode);
      expect(direct).toBeInstanceOf(IndeRunException);
    } else {
      // Passed unchanged: no section is invented, so there are no records either.
      expect(entry.expected.controls).toBeUndefined();
      expect(observation.outcome, mode).toBe("completed");
      expect(observation.output!.speech, mode).toBeUndefined();
      expect(direct).toEqual({ type: "playback", playback: {} });
    }
    expect(fake.calls, mode).toBe(1);
  }
}

/** A cancelled stream whose provider reported the case's records before the stop. */
async function runCancelledOutcomeCase(entry: OutcomeCase): Promise<void> {
  const fake = new ControlFake("tts", ALL_CONTROLS, [
    "commit",
    { report: entry.reported! },
    "wait_for_cancellation"
  ]);
  const observation = await observe(engineWith([fake]), entry.request, "stream", fake.waiting);
  expect(entry.expected.failed).toBe(false);
  expect(observation.outcome).toBe("cancelled");
  expect(observation.output!.speech!.controls).toEqual(entry.expected.controls);
  expect(completeControlOutcomes(entry.request, entry.reported!, "cancelled", "tts")).toEqual(
    entry.expected.controls
  );
}

const outcomeHandlers: Record<string, (entry: OutcomeCase) => Promise<void>> = {
  complete_records: runCompletedOutcomeCase,
  preferred_record_missing: runCompletedOutcomeCase,
  required_record_missing: runCompletedOutcomeCase,
  required_not_applied: runCompletedOutcomeCase,
  duplicate_record: runCompletedOutcomeCase,
  unrequested_record: runCompletedOutcomeCase,
  requested_value_differs: runCompletedOutcomeCase,
  volume_reported_as_synthesis: runCompletedOutcomeCase,
  cancelled_keeps_known_records: runCancelledOutcomeCase,
  preferred_only_no_speech_section: runNoSpeechSectionCase,
  required_no_speech_section: runNoSpeechSectionCase
};

// --- control-execution.json ------------------------------------------------------------------

interface ExecutionCase {
  id: string;
  modes: Mode[];
  cancelWhen?: "waiting";
  request: TaskRequest;
  providers: Array<{ id: string; controls: ControlId[]; script: Step[] }>;
  expect: {
    outcome: Observation["outcome"];
    errorClass?: string;
    providerCallCounts?: Record<string, number>;
    receivedControls?: Record<string, ControlApplicationPlan[]>;
    attempts?: [string, string][];
    attemptErrorClasses?: Record<string, string>;
    committedAttempts?: string[];
    fallbackOccurred?: boolean;
    commitResults?: Record<string, boolean[]>;
    output?: TaskOutput;
    absentOutput?: boolean;
    eventTypes?: string[];
  };
}

const execution = load<ExecutionCase>("control-execution.json");

async function runExecutionCase(entry: ExecutionCase): Promise<void> {
  for (const mode of entry.modes) {
    const fakes = entry.providers.map(
      (provider) => new ControlFake(provider.id, provider.controls, provider.script)
    );
    const byId = (id: string) => fakes.find((fake) => fake.id === id)!;
    const cancelWhen =
      entry.cancelWhen === "waiting" ? Promise.race(fakes.map((fake) => fake.waiting)) : undefined;
    const observation = await observe(engineWith(fakes), entry.request, mode, cancelWhen);
    const expected = entry.expect;
    const provenance = observation.provenance!;

    expect(observation.outcome, mode).toBe(expected.outcome);
    if (expected.errorClass !== undefined) {
      expect(observation.error!.errorClass, mode).toBe(expected.errorClass);
    }
    for (const [id, count] of Object.entries(expected.providerCallCounts ?? {})) {
      expect(byId(id).calls, `${mode} ${id} calls`).toBe(count);
    }
    for (const [id, controls] of Object.entries(expected.receivedControls ?? {})) {
      expect(byId(id).receivedControls, `${mode} ${id} controls`).toEqual([controls]);
    }
    if (expected.attempts !== undefined) {
      expect(
        provenance.attempts.map((attempt) => [attempt.providerId, attempt.outcome]),
        mode
      ).toEqual(expected.attempts);
    }
    for (const [id, errorClass] of Object.entries(expected.attemptErrorClasses ?? {})) {
      expect(
        provenance.attempts.find((attempt) => attempt.providerId === id)?.errorClass,
        mode
      ).toBe(errorClass);
    }
    if (expected.committedAttempts !== undefined) {
      expect(
        provenance.attempts
          .filter((attempt) => attempt.committed === true)
          .map((attempt) => attempt.providerId),
        mode
      ).toEqual(expected.committedAttempts);
    }
    if (expected.fallbackOccurred !== undefined) {
      expect(provenance.fallbackOccurred, mode).toBe(expected.fallbackOccurred);
    }
    for (const [id, results] of Object.entries(expected.commitResults ?? {})) {
      expect(byId(id).commitResults, `${mode} ${id} commits`).toEqual(results);
    }
    if (expected.output !== undefined) expect(observation.output, mode).toEqual(expected.output);
    if (expected.absentOutput === true)
      expect(observation.terminal, mode).not.toHaveProperty("output");
    if (expected.eventTypes !== undefined && mode === "stream") {
      expect(
        observation.events!.map((event) => event.type),
        mode
      ).toEqual(expected.eventTypes);
    }
  }
}

const executionHandlers: Record<string, (entry: ExecutionCase) => Promise<void>> = {
  precommit_control_refusal_falls_back_once: runExecutionCase,
  postcommit_failure_is_not_replayed: runExecutionCase,
  cancel_before_commit_runs_nothing: runExecutionCase,
  cancel_after_commit_keeps_known_records: runExecutionCase,
  late_callback_after_cancel_is_suppressed: runExecutionCase,
  plan_reaches_provider: runExecutionCase
};

// --- suites ----------------------------------------------------------------------------------

function conformance<T extends { id: string }>(
  name: string,
  catalog: { cases: T[] },
  handlers: Record<string, (entry: T) => Promise<void>>
): void {
  describe(name, () => {
    it("implements every case in the shared catalog, and no others", () => {
      const ids = catalog.cases.map((entry) => entry.id).sort();
      expect(ids.length).toBeGreaterThan(0);
      expect(Object.keys(handlers).sort()).toEqual(ids);
    });
    for (const entry of catalog.cases) {
      it(entry.id, async () => {
        const handler = handlers[entry.id];
        expect(handler, `no handler for '${entry.id}'`).toBeDefined();
        await handler!(entry);
      });
    }
  });
}

conformance("control-plan-integrity.json", planIntegrity, planIntegrityHandlers);
conformance("control-outcomes.json", outcomes, outcomeHandlers);
conformance("control-execution.json", execution, executionHandlers);

describe("speech control routing", () => {
  it("fails CapabilityMismatch with speech_control_unsupported when no provider supports a required control", async () => {
    const fake = new ControlFake("tts", [], ["commit", "finish"]);
    const request = execution.cases.find(
      (entry) => entry.id === "postcommit_failure_is_not_replayed"
    )!.request;
    for (const mode of ["run", "stream"] as const) {
      const observation = await observe(engineWith([fake]), request, mode);
      expect(observation.outcome, mode).toBe("failed");
      expect(observation.error!.errorClass, mode).toBe("CapabilityMismatch");
      const rejected = observation.error!.details?.rejectedProviders as Array<{
        providerId: string;
        reasons: Array<{ code: string }>;
      }>;
      expect(
        rejected.map((provider) => provider.providerId),
        mode
      ).toEqual(["tts"]);
      expect(
        rejected[0]!.reasons.map((reason) => reason.code),
        mode
      ).toContain("speech_control_unsupported");
      expect(observation.provenance!.attemptCount, mode).toBe(0);
      expect(observation.provenance!.routeRejections, mode).toEqual([
        { providerId: "tts", codes: expect.arrayContaining(["speech_control_unsupported"]) }
      ]);
    }
    expect(fake.calls).toBe(0);
  });

  it("leaves a request without controls exactly as before", async () => {
    const fake = new ControlFake("tts", ALL_CONTROLS, ["commit", "finish"]);
    const request: TaskRequest = {
      schemaVersion: "1.1",
      task: { kind: "text_to_speech" },
      speech: { text: "Guten Morgen!", locale: "de-AT" },
      delivery: { mode: "playback" }
    };
    const observation = await observe(engineWith([fake]), request, "run");
    expect(fake.receivedControls).toEqual([undefined]);
    expect(observation.output).toEqual({
      type: "playback",
      playback: {},
      speech: { locale: "de-AT" }
    });
  });

  it("refuses records on a request without controls", async () => {
    const fake = new ControlFake("tts", ALL_CONTROLS, [
      "commit",
      {
        finishWith: [
          {
            id: "speech.pitch",
            requested: 1,
            status: "applied",
            effective: 1,
            method: "platform_synthesis"
          }
        ]
      }
    ]);
    const request: TaskRequest = {
      schemaVersion: "1.1",
      task: { kind: "text_to_speech" },
      speech: { text: "Guten Morgen!", locale: "de-AT" },
      delivery: { mode: "playback" }
    };
    const observation = await observe(engineWith([fake]), request, "run");
    expect(observation.outcome).toBe("failed");
    expect(observation.error!.details?.code).toBe("output_mismatch");
  });

  it("refuses a completed output without a speech section when the request has controls", async () => {
    const fake = new ControlFake("tts", ALL_CONTROLS, []);
    fake.run = async (request: TaskRequest, context: RunContext) => {
      context.commit();
      return {
        schemaVersion: "1.1",
        runId: request.requestId ?? "run",
        output: { type: "playback", playback: {} },
        finishReason: "stop",
        telemetry: { providerUsed: "tts", totalMs: 0 }
      };
    };
    const request = outcomes.cases.find(
      (entry) => entry.id === "preferred_record_missing"
    )!.request;
    const observation = await observe(engineWith([fake]), request, "run");
    expect(observation.outcome).toBe("failed");
    expect(observation.error!.details?.code).toBe("output_mismatch");
  });

  it("drops a report that breaks the record rules from a cancelled terminal", async () => {
    const entry = outcomes.cases.find((c) => c.id === "cancelled_keeps_known_records")!;
    const fake = new ControlFake("tts", ALL_CONTROLS, [
      "commit",
      {
        report: [
          {
            id: "speech.speakingRate",
            requested: 0.85,
            status: "applied",
            effective: 0.85,
            method: "playback_attenuation"
          }
        ]
      },
      "wait_for_cancellation"
    ]);
    const observation = await observe(engineWith([fake]), entry.request, "stream", fake.waiting);
    expect(observation.outcome).toBe("cancelled");
    expect(
      observation.output!.speech!.controls!.map((record) => [
        record.id,
        record.status,
        record.reason
      ])
    ).toEqual([
      ["speech.speakingRate", "not_applied", "not_reported"],
      ["speech.pitch", "not_applied", "not_reported"],
      ["playback.volume", "not_applied", "not_reported"]
    ]);
  });
});
