/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

/**
 * The canonical Mode 2 streaming event union, discriminated by 'type'. Every variant shares
 * an envelope of schemaVersion, runId, sequence, timestamp, and type. 'sequence' is the
 * ordering authority for events within a run (a monotonically increasing integer starting
 * at 0 per runId) — consumers must order by 'sequence', not by arrival order, since a
 * bridge hop (e.g. a future Capacitor bridge) could reorder delivery. Known event types are
 * split into user-visible content ('content_delta', 'content_snapshot') and
 * mechanical/diagnostic types ('lifecycle', 'diagnostic', 'terminal') so SDKs can
 * distinguish what belongs in a chat UI from what is orchestration detail. Forward
 * compatibility: this union closes with an open 'unknown_event' branch so a consumer built
 * against an older revision of this schema does not hard-fail when a newer, additive minor
 * revision introduces a new known type; per contracts/README.md's schema evolution policy,
 * SDKs must treat an unrecognized 'type' as ignore-or-pass-through-for-diagnostics, never
 * as a hard error. Design seam only; no engine or provider implementation exists yet (see
 * docs/architecture/architecture.md).
 */
export type StreamEvent = {
    /**
     * Event-specific diagnostic metadata. It must not contain prompt payloads or raw secrets,
     * matching the same guardrail as TelemetryEvent.payload.
     *
     * Structurally identical to StreamTerminalOutcome
     * (contracts/schemas/stream-terminal-outcome.schema.json), duplicated by value here rather
     * than by $ref, matching this repo's schema convention of no cross-file references. Keep
     * both shapes in sync; a cross-check test asserts a shared fixture validates against both
     * schemas.
     *
     * Optional event-specific payload for the unrecognized type. It must not contain prompt
     * payloads or raw secrets.
     */
    payload?: Payload;
    /**
     * Opaque run identifier this event belongs to, matching StreamRunHandle.runId.
     */
    runId: string;
    /**
     * Contract schema version used to interpret this event payload.
     */
    schemaVersion: "1.0";
    /**
     * Zero-based, monotonically increasing event index within this run. The ordering authority;
     * do not rely on delivery/arrival order.
     *
     * Zero-based, monotonically increasing event index within this run. This is always the
     * highest sequence number for the run: the terminal event.
     */
    sequence: number;
    /**
     * Wall-clock event timestamp in Unix epoch milliseconds.
     */
    timestamp: number;
    /**
     * User-visible content: an incremental text increment since the previous content_delta or
     * content_snapshot event. Mirrors ProviderDescriptor.streamingStyle 'tokens'/'chunks'
     * (packages/inderun-web/src/core/provider.ts) — providers reporting either style normalize
     * to content_delta.
     *
     * User-visible content: the full cumulative text produced so far. Mirrors
     * ProviderDescriptor.streamingStyle 'snapshots' (packages/inderun-web/src/core/provider.ts)
     * — providers reporting that style normalize to content_snapshot rather than
     * content_delta.
     *
     * Mechanical/diagnostic: a run lifecycle transition (e.g. provider selection, execution
     * start). Not user-visible content; not part of the generated text.
     *
     * Mechanical/diagnostic: free-form orchestration or provider diagnostic detail. Not
     * user-visible content.
     *
     * Terminal: the last event of the run, carrying the mutually-exclusive
     * completion/error/cancellation outcome. No further StreamEvent is delivered for this runId
     * after this event.
     *
     * Forward-compatibility catch-all: any event type not among the known constants above.
     * Exists so a consumer validating against this revision of the schema does not hard-fail
     * when a future additive revision introduces a new known event type; SDKs must ignore or
     * pass through such events for diagnostics rather than treating them as an error.
     */
    type: string;
    [property: string]: unknown;
}

/**
 * Event-specific diagnostic metadata. It must not contain prompt payloads or raw secrets,
 * matching the same guardrail as TelemetryEvent.payload.
 *
 * Optional event-specific payload for the unrecognized type. It must not contain prompt
 * payloads or raw secrets.
 */
export type Payload = {
    /**
     * The incremental text produced since the previous content event.
     *
     * The full cumulative text produced by the run so far.
     */
    text?: string;
    /**
     * The lifecycle phase reached.
     */
    phase?:         Phase;
    finalText?:     string;
    outcome?:       Outcome;
    runId?:         string;
    schemaVersion?: "1.0";
    telemetry?:     Telemetry;
    usage?:         Usage;
    error?:         Error;
    partialText?:   string;
    reason?:        string;
    [property: string]: unknown;
}

export type Error = {
    details?:      { [key: string]: unknown };
    errorClass:    ErrorClass;
    message:       string;
    providerId?:   string;
    retryable?:    boolean;
    retryAfterMs?: number;
    schemaVersion: "1.0";
    [property: string]: unknown;
}

export type ErrorClass = "CapabilityMismatch" | "Offline" | "AuthError" | "RateLimited" | "Timeout" | "Unavailable" | "Internal";

export type Outcome = "completed" | "error" | "cancelled";

/**
 * The lifecycle phase reached.
 */
export type Phase = "provider_selected" | "started";

export type Telemetry = {
    providerUsed: string;
    totalMs:      number;
    [property: string]: unknown;
}

export type Usage = {
    inputTokens?:  number;
    outputTokens?: number;
    totalTokens?:  number;
    [property: string]: unknown;
}
