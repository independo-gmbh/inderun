import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import type { StreamEvent } from "@independo/inderun-contracts";
import {
  IndeRun,
  IndeRunException,
  ProviderRegistry,
  createCapabilityMismatch,
  createRateLimited,
  createUnavailable,
  type ProviderStreamContext,
  type ProviderStreamEvent
} from "../index.js";
import {
  MockTelemetryService,
  createFakeStreamProvider,
  createMockHostServices,
  createRequest,
  createRunOnlyProvider,
  createWallClockHostServices,
  delay,
  drain
} from "../test/stream-fakes.js";

/**
 * The Web half of the cross-SDK Mode 2 conformance catalog.
 *
 * The catalog lives in `contracts/fixtures/streaming/engine-conformance.json` and
 * is driven identically by the Swift and Kotlin suites. Each case id gets exactly
 * one handler here; the guard test below fails when the handler ids and the
 * catalog ids are not equal, so a scenario that exists on another platform and
 * not on this one is a red build rather than a review finding.
 *
 * `engine.stream.test.ts` stays as the Web suite's own regression coverage. This
 * file is only the parity contract.
 */

interface RejectedProviderExpectation {
  providerId: string;
  reasons?: string[];
  messages?: string[];
}

interface Expectations {
  eventTypes?: string[];
  sequences?: number[];
  contentTexts?: string[];
  terminalCount?: number;
  eventsAfterTerminal?: number;
  terminal?: {
    outcome?: string;
    finalText?: string;
    partialText?: string;
    reason?: string;
    finishReason?: string;
    errorClass?: string;
    usage?: Record<string, number>;
    absentFinishReason?: boolean;
    absentUsage?: boolean;
  };
  rejectsWith?: {
    errorClass?: string;
    runId?: string;
    failureCode?: string;
    rejectedProviders?: RejectedProviderExpectation[];
  };
  providerCallCounts?: Record<string, number>;
  providerInterrupted?: boolean;
  runSelectedProviderId?: string;
  streamSelectedProviderId?: string;
  handleStartedAtIsUnixEpochMillis?: boolean;
  telemetryTypes?: string[];
  telemetryTypesContain?: string[];
  telemetryForbiddenPayloadKeys?: string[];
  telemetryForbiddenPayloadValues?: string[];
  telemetryStableMessageEvents?: string[];
  noReplayOnSecondIteration?: boolean;
}

interface ConformanceCase {
  id: string;
  category: string;
  description: string;
  setup: string;
  expect: Expectations;
}

const fixturePath = join(
  dirname(fileURLToPath(import.meta.url)),
  "../../../../contracts/fixtures/streaming/engine-conformance.json"
);
const catalog = JSON.parse(readFileSync(fixturePath, "utf8")) as { cases: ConformanceCase[] };

interface Observation {
  events?: StreamEvent[];
  rejection?: IndeRunException;
  telemetry?: MockTelemetryService;
  providerCallCounts?: Record<string, number>;
  providerInterrupted?: boolean;
  runSelectedProviderId?: string;
  streamSelectedProviderId?: string;
  handleStartedAt?: number;
  wallClockRange?: [number, number];
  secondIterationEventCount?: number;
}

function terminalPayload(events: StreamEvent[]): Record<string, unknown> {
  const terminal = events.find((event) => event.type === "terminal");
  expect(terminal, "expected a terminal event").toBeDefined();
  return (terminal as StreamEvent).payload as unknown as Record<string, unknown>;
}

function assertCase(expected: Expectations, observed: Observation): void {
  const events = observed.events ?? [];

  if (expected.eventTypes !== undefined) {
    expect(events.map((event) => event.type)).toEqual(expected.eventTypes);
  }
  if (expected.sequences !== undefined) {
    expect(events.map((event) => event.sequence)).toEqual(expected.sequences);
  }
  if (expected.contentTexts !== undefined) {
    const texts = events
      .filter((event) => event.type === "content_delta" || event.type === "content_snapshot")
      .map((event) => (event.payload as unknown as { text: string }).text);
    expect(texts).toEqual(expected.contentTexts);
  }
  if (expected.terminalCount !== undefined) {
    expect(events.filter((event) => event.type === "terminal")).toHaveLength(
      expected.terminalCount
    );
  }
  if (expected.eventsAfterTerminal !== undefined) {
    const index = events.findIndex((event) => event.type === "terminal");
    expect(index, "expected a terminal event").toBeGreaterThanOrEqual(0);
    expect(events.length - 1 - index).toBe(expected.eventsAfterTerminal);
  }

  if (expected.terminal !== undefined) {
    const payload = terminalPayload(events);
    const { absentFinishReason, absentUsage, errorClass, usage, ...direct } = expected.terminal;
    if (Object.keys(direct).length > 0) {
      expect(payload).toMatchObject(direct);
    }
    if (errorClass !== undefined) {
      expect((payload["error"] as { errorClass?: string } | undefined)?.errorClass).toBe(
        errorClass
      );
    }
    if (usage !== undefined) {
      expect(payload["usage"]).toMatchObject(usage);
    }
    if (absentFinishReason === true) {
      expect(payload).not.toHaveProperty("finishReason");
    }
    if (absentUsage === true) {
      expect(payload).not.toHaveProperty("usage");
    }
  }

  if (expected.rejectsWith !== undefined) {
    const rejection = observed.rejection;
    expect(rejection, "expected stream() to reject").toBeInstanceOf(IndeRunException);
    const thrown = rejection as IndeRunException;
    if (expected.rejectsWith.errorClass !== undefined) {
      expect(thrown.errorClass).toBe(expected.rejectsWith.errorClass);
    }
    if (expected.rejectsWith.runId !== undefined) {
      expect(thrown.runId).toBe(expected.rejectsWith.runId);
    }
    const details = (thrown.details ?? {}) as {
      failureCode?: string;
      rejectedProviders?: Array<{
        providerId: string;
        reasons: Array<{ code: string; message: string }>;
      }>;
    };
    if (expected.rejectsWith.failureCode !== undefined) {
      expect(details.failureCode).toBe(expected.rejectsWith.failureCode);
    }
    for (const expectedProvider of expected.rejectsWith.rejectedProviders ?? []) {
      const actual = (details.rejectedProviders ?? []).find(
        (candidate) => candidate.providerId === expectedProvider.providerId
      );
      expect(
        actual,
        `expected ${expectedProvider.providerId} among rejectedProviders`
      ).toBeDefined();
      if (expectedProvider.reasons !== undefined) {
        expect((actual as { reasons: Array<{ code: string }> }).reasons.map((r) => r.code)).toEqual(
          expectedProvider.reasons
        );
      }
      if (expectedProvider.messages !== undefined) {
        expect(
          (actual as { reasons: Array<{ message: string }> }).reasons.map((r) => r.message)
        ).toEqual(expectedProvider.messages);
      }
    }
  }

  for (const [providerId, count] of Object.entries(expected.providerCallCounts ?? {})) {
    expect(observed.providerCallCounts?.[providerId], `${providerId} call count`).toBe(count);
  }
  if (expected.providerInterrupted !== undefined) {
    expect(observed.providerInterrupted).toBe(expected.providerInterrupted);
  }
  if (expected.runSelectedProviderId !== undefined) {
    expect(observed.runSelectedProviderId).toBe(expected.runSelectedProviderId);
  }
  if (expected.streamSelectedProviderId !== undefined) {
    expect(observed.streamSelectedProviderId).toBe(expected.streamSelectedProviderId);
  }
  if (expected.handleStartedAtIsUnixEpochMillis === true) {
    const [before, after] = observed.wallClockRange as [number, number];
    expect(observed.handleStartedAt).toBeGreaterThanOrEqual(before);
    expect(observed.handleStartedAt).toBeLessThanOrEqual(after);
  }

  const telemetry = observed.telemetry?.events ?? [];
  if (expected.telemetryTypes !== undefined) {
    expect(telemetry.map((event) => event.type)).toEqual(expected.telemetryTypes);
  }
  for (const type of expected.telemetryTypesContain ?? []) {
    expect(telemetry.map((event) => event.type)).toContain(type);
  }
  for (const key of expected.telemetryForbiddenPayloadKeys ?? []) {
    for (const event of telemetry) {
      expect(event.payload, `${event.type} payload must not carry '${key}'`).not.toHaveProperty(
        key
      );
    }
  }
  for (const value of expected.telemetryForbiddenPayloadValues ?? []) {
    for (const event of telemetry) {
      expect(
        JSON.stringify(event.payload),
        `${event.type} payload must not contain '${value}'`
      ).not.toContain(value);
    }
  }
  for (const type of expected.telemetryStableMessageEvents ?? []) {
    const event = telemetry.find((candidate) => candidate.type === type);
    expect(event, `expected a ${type} telemetry event`).toBeDefined();
    const message = (event as { payload: Record<string, unknown> }).payload["message"];
    expect(typeof message).toBe("string");
    expect((message as string).length).toBeGreaterThan(0);
  }

  if (expected.noReplayOnSecondIteration === true) {
    expect(observed.secondIterationEventCount).toBe(0);
  }
}

// --- handlers -------------------------------------------------------------

type Handler = () => Promise<Observation>;

const handlers: Record<string, Handler> = {
  async deltas_then_completed() {
    const registry = new ProviderRegistry();
    registry.register(
      createFakeStreamProvider("p1", {
        script: [
          { event: { kind: "delta", text: "Hello" } },
          { event: { kind: "delta", text: " world" } },
          { event: { kind: "done", finalText: "Hello world" } }
        ]
      })
    );
    const engine = new IndeRun(registry, createMockHostServices());
    return { events: await drain((await engine.stream(createRequest())).events) };
  },

  async snapshot_replaces_cumulative_text() {
    const registry = new ProviderRegistry();
    registry.register(
      createFakeStreamProvider("p1", {
        script: [
          { event: { kind: "snapshot", text: "Loc" } },
          { event: { kind: "snapshot", text: "Local first" } },
          { event: { kind: "done", finalText: "Local first" } }
        ]
      })
    );
    const engine = new IndeRun(registry, createMockHostServices());
    return { events: await drain((await engine.stream(createRequest())).events) };
  },

  async completed_carries_finish_reason_and_usage() {
    const registry = new ProviderRegistry();
    registry.register(
      createFakeStreamProvider("p1", {
        script: [
          { event: { kind: "delta", text: "trunc" } },
          {
            event: {
              kind: "done",
              finalText: "trunc",
              finishReason: "length",
              usage: { inputTokens: 2, outputTokens: 1, totalTokens: 3 }
            }
          }
        ]
      })
    );
    const engine = new IndeRun(registry, createMockHostServices());
    return { events: await drain((await engine.stream(createRequest())).events) };
  },

  async completed_omits_finish_reason_when_absent() {
    const registry = new ProviderRegistry();
    registry.register(
      createFakeStreamProvider("p1", {
        script: [
          { event: { kind: "delta", text: "a" } },
          { event: { kind: "done", finalText: "a" } }
        ]
      })
    );
    const engine = new IndeRun(registry, createMockHostServices());
    return { events: await drain((await engine.stream(createRequest())).events) };
  },

  async handle_started_at_is_unix_epoch_millis() {
    const registry = new ProviderRegistry();
    registry.register(
      createFakeStreamProvider("p1", { script: [{ event: { kind: "done", finalText: "ok" } }] })
    );
    const engine = new IndeRun(registry, createWallClockHostServices());
    const before = Date.now();
    const { handle, events } = await engine.stream(createRequest());
    const after = Date.now();
    await drain(events);
    return { handleStartedAt: handle.startedAt, wallClockRange: [before, after] };
  },

  async terminal_error_carries_error_class() {
    const registry = new ProviderRegistry();
    registry.register(
      createFakeStreamProvider("p1", {
        script: [{ event: { kind: "delta", text: "partial " } }],
        throwAfter: createRateLimited("upstream is throttling")
      })
    );
    const engine = new IndeRun(registry, createMockHostServices());
    return { events: await drain((await engine.stream(createRequest())).events) };
  },

  async all_providers_fail_pre_commit_yields_single_error() {
    const registry = new ProviderRegistry();
    const first = createFakeStreamProvider("p1", {
      script: [],
      throwImmediately: new Error("boom")
    });
    const second = createFakeStreamProvider("p2", {
      script: [],
      throwImmediately: new Error("boom")
    });
    registry.register(first);
    registry.register(second);
    const engine = new IndeRun(registry, createMockHostServices());
    return {
      events: await drain((await engine.stream(createRequest())).events),
      providerCallCounts: { p1: first.callCount(), p2: second.callCount() }
    };
  },

  async cancelled_carries_partial_text_and_reason() {
    const registry = new ProviderRegistry();
    registry.register(
      createFakeStreamProvider("p1", {
        script: [{ event: { kind: "delta", text: "one" } }, { waitForCancellation: true }]
      })
    );
    const engine = new IndeRun(registry, createMockHostServices());
    const { events, cancel } = await engine.stream(createRequest());
    const received: StreamEvent[] = [];
    for await (const event of events) {
      received.push(event);
      if (event.type === "content_delta") cancel("user stopped");
    }
    return { events: received };
  },

  async no_events_are_delivered_after_the_terminal() {
    const registry = new ProviderRegistry();
    registry.register(
      createFakeStreamProvider("p1", {
        script: [
          { event: { kind: "delta", text: "a" } },
          { event: { kind: "done", finalText: "a" } },
          { event: { kind: "delta", text: "b" } }
        ]
      })
    );
    const engine = new IndeRun(registry, createMockHostServices());
    return { events: await drain((await engine.stream(createRequest())).events) };
  },

  async cancel_before_first_attempt_forecloses_every_provider() {
    const registry = new ProviderRegistry();
    const first = createFakeStreamProvider("p1", { script: [{ waitForCancellation: true }] });
    const second = createFakeStreamProvider("p2", {
      script: [{ event: { kind: "done", finalText: "never" } }]
    });
    registry.register(first);
    registry.register(second);
    const engine = new IndeRun(registry, createMockHostServices());
    const { events, cancel } = await engine.stream(createRequest());
    cancel();
    return {
      events: await drain(events),
      providerCallCounts: { p1: first.callCount(), p2: second.callCount() }
    };
  },

  async cancel_during_emit_stops_further_deltas() {
    const registry = new ProviderRegistry();
    registry.register(
      createFakeStreamProvider("p1", {
        script: [
          { event: { kind: "delta", text: "one" } },
          { waitForCancellation: true },
          { event: { kind: "delta", text: " two" } },
          { event: { kind: "done", finalText: "one two" } }
        ]
      })
    );
    const engine = new IndeRun(registry, createMockHostServices());
    const { events, cancel } = await engine.stream(createRequest());
    const received: StreamEvent[] = [];
    for await (const event of events) {
      received.push(event);
      if (event.type === "content_delta") cancel();
    }
    return { events: received };
  },

  async cancel_after_terminal_is_a_no_op() {
    const registry = new ProviderRegistry();
    registry.register(
      createFakeStreamProvider("p1", {
        script: [
          { event: { kind: "delta", text: "done" } },
          { event: { kind: "done", finalText: "done" } }
        ]
      })
    );
    const engine = new IndeRun(registry, createMockHostServices());
    const { events, cancel } = await engine.stream(createRequest());
    const received = await drain(events);
    cancel("too late");
    // Anything the cancel could still produce would arrive after this point.
    await new Promise((resolve) => setTimeout(resolve, 5));
    return { events: received };
  },

  async concurrent_cancels_yield_one_outcome_first_reason_wins() {
    const registry = new ProviderRegistry();
    registry.register(
      createFakeStreamProvider("p1", {
        script: [{ event: { kind: "delta", text: "one" } }, { waitForCancellation: true }]
      })
    );
    const engine = new IndeRun(registry, createMockHostServices());
    const { events, cancel } = await engine.stream(createRequest());
    const collector = drain(events);
    cancel("first");
    cancel("second");
    return { events: await collector };
  },

  async cancel_during_pre_commit_attempt_forecloses_next_route() {
    const registry = new ProviderRegistry();
    const failing = createFakeStreamProvider("p1", { script: [] });
    const failingState = { callCount: 0 };
    // eslint-disable-next-line require-yield -- the point of this provider is to fail without emitting
    failing.stream = async function* (
      _request,
      context: ProviderStreamContext
    ): AsyncGenerator<ProviderStreamEvent> {
      failingState.callCount++;
      // Fails only after the caller has had a chance to cancel, and without ever
      // emitting content, so the run is still pre-commit when the failure lands.
      await delay(20, context.signal);
      throw new Error("boom before any content");
    };
    failing.callCount = () => failingState.callCount;
    const fallback = createFakeStreamProvider("p2", {
      script: [{ event: { kind: "done", finalText: "never" } }]
    });
    registry.register(failing);
    registry.register(fallback);
    const engine = new IndeRun(registry, createMockHostServices());
    const { events, cancel } = await engine.stream(createRequest());
    const collector = drain(events);
    cancel("mid-attempt");
    return {
      events: await collector,
      providerCallCounts: { p1: failing.callCount(), p2: fallback.callCount() }
    };
  },

  async cancel_unblocks_a_provider_waiting_for_output() {
    const registry = new ProviderRegistry();
    const provider = createFakeStreamProvider("p1", {
      script: [{ event: { kind: "delta", text: "one" } }, { waitForCancellation: true }]
    });
    registry.register(provider);
    const engine = new IndeRun(registry, createMockHostServices());
    const { events, cancel } = await engine.stream(createRequest());
    const received: StreamEvent[] = [];
    for await (const event of events) {
      received.push(event);
      if (event.type === "content_delta") cancel();
    }
    return { events: received, providerInterrupted: provider.wasInterrupted() };
  },

  async no_streaming_capable_provider_rejects_with_run_id() {
    const registry = new ProviderRegistry();
    registry.register(createRunOnlyProvider("p_run_only"));
    const engine = new IndeRun(registry, createMockHostServices());
    return captureRejection(() => engine.stream(createRequest({ requestId: "req-42" })));
  },

  async declared_streaming_without_implementation_rejected() {
    const registry = new ProviderRegistry();
    const provider = createFakeStreamProvider("p_declared_only", {
      script: [],
      implementsStream: false
    });
    registry.register(provider);
    const engine = new IndeRun(registry, createMockHostServices());
    const observed = await captureRejection(() => engine.stream(createRequest()));
    return { ...observed, providerCallCounts: { p_declared_only: provider.callCount() } };
  },

  async dynamic_capability_revocation_rejected_with_reason() {
    const registry = new ProviderRegistry();
    registry.register(
      createFakeStreamProvider("p_revoked", {
        script: [],
        streamingAvailable: false,
        streamingUnavailableReason: "Host has no chunked HTTP capability."
      })
    );
    const engine = new IndeRun(registry, createMockHostServices());
    return captureRejection(() => engine.stream(createRequest()));
  },

  async routing_rejection_carries_failure_code_and_reason_codes() {
    const registry = new ProviderRegistry();
    registry.register(createRunOnlyProvider("p_run_only"));
    const engine = new IndeRun(registry, createMockHostServices());
    return captureRejection(() => engine.stream(createRequest()));
  },

  async privacy_constraint_enforced_on_stream_routes() {
    const registry = new ProviderRegistry();
    registry.register(createFakeStreamProvider("p_cloud_streaming", { type: "cloud", script: [] }));
    const engine = new IndeRun(registry, createMockHostServices());
    return captureRejection(() =>
      engine.stream(createRequest({ constraints: { privacy: "local_required" } }))
    );
  },

  async offline_host_with_cloud_stream_provider_reports_offline() {
    const registry = new ProviderRegistry();
    registry.register(createFakeStreamProvider("p_cloud_streaming", { type: "cloud", script: [] }));
    const engine = new IndeRun(registry, createMockHostServices({ online: false }));
    return captureRejection(() =>
      engine.stream(createRequest({ constraints: { privacy: "cloud_allowed" } }))
    );
  },

  async offline_host_with_local_stream_provider_reports_capability_mismatch() {
    const registry = new ProviderRegistry();
    registry.register(createRunOnlyProvider("p_local_run_only"));
    const engine = new IndeRun(registry, createMockHostServices({ online: false }));
    return captureRejection(() =>
      engine.stream(createRequest({ constraints: { privacy: "cloud_allowed" } }))
    );
  },

  async run_and_stream_resolve_different_chains() {
    const registry = new ProviderRegistry();
    const runOnly = createRunOnlyProvider("a_run_only");
    const streaming = createFakeStreamProvider("b_streaming", {
      script: [{ event: { kind: "done", finalText: "streamed" } }]
    });
    registry.register(runOnly);
    registry.register(streaming);
    const engine = new IndeRun(registry, createMockHostServices());

    const result = await engine.run(createRequest());
    const { handle, events } = await engine.stream(createRequest());
    await drain(events);

    return {
      runSelectedProviderId: result.telemetry.providerUsed,
      streamSelectedProviderId: handle.providerId,
      providerCallCounts: { a_run_only: runOnly.callCount() }
    };
  },

  async pre_commit_failure_falls_back() {
    const registry = new ProviderRegistry();
    const failing = createFakeStreamProvider("p1_failing", {
      script: [],
      throwImmediately: new Error("boom before any content")
    });
    const healthy = createFakeStreamProvider("p2_healthy", {
      script: [{ event: { kind: "done", finalText: "recovered" } }]
    });
    registry.register(failing);
    registry.register(healthy);
    const engine = new IndeRun(registry, createMockHostServices());
    return {
      events: await drain((await engine.stream(createRequest())).events),
      providerCallCounts: { p1_failing: failing.callCount(), p2_healthy: healthy.callCount() }
    };
  },

  async post_commit_failure_never_falls_back() {
    const registry = new ProviderRegistry();
    const failing = createFakeStreamProvider("p1", {
      script: [{ event: { kind: "delta", text: "partial " } }],
      throwAfter: new Error("boom")
    });
    const healthy = createFakeStreamProvider("p2_healthy", {
      script: [{ event: { kind: "done", finalText: "never" } }]
    });
    registry.register(failing);
    registry.register(healthy);
    const engine = new IndeRun(registry, createMockHostServices());
    return {
      events: await drain((await engine.stream(createRequest())).events),
      providerCallCounts: { p2_healthy: healthy.callCount() }
    };
  },

  async stream_ending_without_terminal_is_a_provider_fault() {
    const registry = new ProviderRegistry();
    registry.register(
      createFakeStreamProvider("p1", { script: [{ event: { kind: "delta", text: "a" } }] })
    );
    const engine = new IndeRun(registry, createMockHostServices());
    return { events: await drain((await engine.stream(createRequest())).events) };
  },

  async provider_emitted_failure_behaves_like_a_throw() {
    const registry = new ProviderRegistry();
    const emitting = createFakeStreamProvider("p1", {
      script: [{ event: { kind: "error", error: createRateLimited("slow down") } }]
    });
    const healthy = createFakeStreamProvider("p2_healthy", {
      script: [{ event: { kind: "done", finalText: "recovered" } }]
    });
    registry.register(emitting);
    registry.register(healthy);
    const engine = new IndeRun(registry, createMockHostServices());
    return {
      events: await drain((await engine.stream(createRequest())).events),
      providerCallCounts: { p1: emitting.callCount(), p2_healthy: healthy.callCount() }
    };
  },

  async duplicate_terminal_suppressed() {
    const registry = new ProviderRegistry();
    registry.register(
      createFakeStreamProvider("p1", {
        script: [
          { event: { kind: "delta", text: "first" } },
          { event: { kind: "done", finalText: "first" } },
          { event: { kind: "done", finalText: "second" } }
        ]
      })
    );
    const engine = new IndeRun(registry, createMockHostServices());
    return { events: await drain((await engine.stream(createRequest())).events) };
  },

  async empty_snapshot_retracts_delivered_content() {
    const registry = new ProviderRegistry();
    registry.register(
      createFakeStreamProvider("p1", {
        script: [
          { event: { kind: "delta", text: "rejected text" } },
          { event: { kind: "snapshot", text: "" } }
        ],
        throwAfter: createCapabilityMismatch("The response was rejected by a policy check.")
      })
    );
    const engine = new IndeRun(registry, createMockHostServices());
    return { events: await drain((await engine.stream(createRequest())).events) };
  },

  async telemetry_sequence_for_a_normal_completion() {
    const registry = new ProviderRegistry();
    registry.register(
      createFakeStreamProvider("p1", {
        script: [
          { event: { kind: "delta", text: "Hello" } },
          { event: { kind: "done", finalText: "Hello" } }
        ]
      })
    );
    const telemetry = new MockTelemetryService();
    const engine = new IndeRun(registry, createMockHostServices(), telemetry);
    await drain((await engine.stream(createRequest())).events);
    return { telemetry };
  },

  async stream_cancelled_telemetry_carries_no_raw_error_detail() {
    const registry = new ProviderRegistry();
    registry.register(
      createFakeStreamProvider("p1", {
        script: [{ event: { kind: "delta", text: "one" } }, { waitForCancellation: true }]
      })
    );
    const telemetry = new MockTelemetryService();
    const engine = new IndeRun(registry, createMockHostServices(), telemetry);
    const { events, cancel } = await engine.stream(createRequest());
    for await (const event of events) {
      if (event.type === "content_delta") cancel("secret user text");
    }
    return { telemetry };
  },

  async stream_failed_telemetry_carries_a_stable_message() {
    const registry = new ProviderRegistry();
    registry.register(
      createFakeStreamProvider("p1", {
        script: [{ event: { kind: "delta", text: "partial " } }],
        throwAfter: createUnavailable("upstream said: sk-secret leaked")
      })
    );
    const telemetry = new MockTelemetryService();
    const engine = new IndeRun(registry, createMockHostServices(), telemetry);
    await drain((await engine.stream(createRequest())).events);
    return { telemetry };
  },

  async events_are_single_use() {
    const registry = new ProviderRegistry();
    registry.register(
      createFakeStreamProvider("p1", {
        script: [
          { event: { kind: "delta", text: "a" } },
          { event: { kind: "done", finalText: "a" } }
        ]
      })
    );
    const engine = new IndeRun(registry, createMockHostServices());
    const { events } = await engine.stream(createRequest());
    const first = await drain(events);
    // The Web SDK completes an exhausted sequence rather than raising; Kotlin
    // raises. Both satisfy the shared guarantee, which is that the run is never
    // replayed -- see the `$divergence` note on this case in the catalog.
    const second = await drain(events);
    return { events: first, secondIterationEventCount: second.length };
  }
};

async function captureRejection(start: () => Promise<unknown>): Promise<Observation> {
  try {
    await start();
  } catch (error) {
    return { rejection: error as IndeRunException };
  }
  throw new Error("expected stream() to reject, but it resolved");
}

describe("Mode 2 engine conformance", () => {
  it("implements every case in the shared catalog, and no others", () => {
    const catalogIds = catalog.cases.map((entry) => entry.id).sort();
    expect(catalogIds.length).toBeGreaterThan(0);
    expect(Object.keys(handlers).sort()).toEqual(catalogIds);
  });

  for (const conformanceCase of catalog.cases) {
    it(`${conformanceCase.category}: ${conformanceCase.id}`, async () => {
      const handler = handlers[conformanceCase.id];
      expect(handler, `no handler for '${conformanceCase.id}'`).toBeDefined();
      assertCase(conformanceCase.expect, await (handler as Handler)());
    });
  }
});
