# Streaming (Mode 2)

Mode 2 delivers a task's output incrementally and can be cancelled while it runs. `stream()` hands
back three things — a handle identifying the run, the run's event sequence, and a cancel hook — and
the guarantees below hold identically on every SDK.

This is the contract. [streaming-conformance.md](streaming-conformance.md) is how it is proven:
33 shared scenarios every engine must satisfy, plus what is only checkable on a real device.

---

## What `stream()` returns

The shape is the same everywhere; only the idiom differs.

| SDK | Signature | `events` | Cancel | Example |
| --- | --- | --- | --- | --- |
| TypeScript | `stream(request): Promise<StreamRun>` | `AsyncIterable<StreamEvent>` | `cancel(reason?)` | [`@independo/inderun-web`](../packages/inderun-web/README.md#streaming) |
| Swift | `stream(request:) async throws -> StreamRun` | `AsyncThrowingStream<StreamEvent, Error>` | `cancel(reason:)` | [iOS SDK](../ios/IndeRun/README.md#streaming) |
| Kotlin | `suspend stream(request): StreamRun` | cold, single-use `Flow<StreamEvent>` | `cancel(reason)` | [Android SDK](../android/README.md#streaming) |
| Capacitor | `stream(request): Promise<StreamRun>` | `AsyncIterable<StreamEvent>` | `cancel(reason?)` | [capacitor-inderun](https://github.com/independo-gmbh/capacitor-inderun#streaming-mode-2) |

`handle` carries `runId` and `startedAt` (Unix epoch milliseconds), and `providerId` once route
selection has completed. Every event of the run repeats that `runId`.

The Kotlin `Flow` being **cold** is the one behavioral difference worth knowing: the run does not
start until something collects it.

## Event types

An event's `type` says what it is; `payload` is shaped per type.

| `type` | Payload | What a consumer does with it |
| --- | --- | --- |
| `content_delta` | `{ text }` | **Append** to the run's text so far |
| `content_snapshot` | `{ text }` | **Replace** the run's text so far — an empty one **retracts** what was already delivered |
| `terminal` | a [terminal outcome](#terminal-outcomes) | Exactly one per run, always last |
| `lifecycle` | `{ phase: "provider_selected" \| "started" }` | Diagnostics only — see below |
| `diagnostic` | open; never prompts or secrets | Diagnostics only — see below |
| anything else | — | **Ignore or log. Never an error.** |

Two of those need qualifying.

**`lifecycle` and `diagnostic` are contract seams, not current behavior.** The schema defines them
so future additive revisions do not break consumers, but no shipped engine or provider emits either
one today. Treat them exactly as you treat an unrecognized type.

**`content_snapshot` is not optional to handle.** A provider's declared `streamingStyle` does not
tell you which content type you will see. The Apple Foundation Models provider emits nothing but
snapshots, and a provider of *any* style may emit an empty snapshot to retract content — which is
how the Android ML Kit provider clears a half-generated response that Gemini Nano rejected on a
policy check. A consumer that implements only the delta branch leaves rejected text on screen.

## Ordering and the single terminal

**Order by `sequence`, not by arrival.** It is a monotonically increasing integer starting at 0 per
run, and it is the ordering authority — delivery order is not, because a bridge hop can reorder
events in transit. The SDKs' own `events` already yields in `sequence` order; if you attach a raw
listener on the Capacitor bridge instead, ordering is yours to enforce.

**Exactly one `terminal` event is produced per run, and nothing follows it.** That is structural
rather than conventional: an Event Gate instance per run assigns the sequence numbers and admits a
terminal on a first-writer-wins basis, so a duplicate terminal, a late content event, or two
concurrent cancels cannot produce a second ending.

## Terminal outcomes

Three, mutually exclusive, and unlike `type` this set is **closed** — it will not grow.

| `outcome` | Carries | Means |
| --- | --- | --- |
| `completed` | `finalText`, `telemetry`, optional `finishReason` and `usage` | The run finished |
| `error` | `error` (an `IndeRunError`, same `errorClass` taxonomy as `run()`) | The run failed after starting |
| `cancelled` | `partialText`, optional `reason` | The run was cancelled |

`finalText` and `partialText` are the run's cumulative text, so a consumer that only wants the
result can ignore every content event and read the terminal. `telemetry.providerUsed` is how you
learn which provider actually served the run.

`finishReason` is `stop`, `length`, or `error` — the last meaning the provider reported a non-fatal
issue on an otherwise completed run, not that the run failed. Both `finishReason` and `usage` are
optional because not every provider reports them; see [what streams today](#what-streams-today).

## The three failure surfaces

Conflating these is the easiest mistake to make, because two of them are not exceptions.

| Surface | When | How it reaches you |
| --- | --- | --- |
| **Rejection** | Request validation, or no registered provider can serve the stream | `stream()` itself rejects/throws. No handle, no events, nothing to iterate |
| **Terminal `error`** | A provider failed, or the whole planned chain did | **Not** an exception. Your loop ends normally and the last event is a `terminal` whose outcome is `error` |
| **Transport fault** | Only across the Capacitor bridge: events were lost or could not be encoded | `events` throws an `Internal` `IndeRunError` |

So a run that fails *after starting* ends your loop normally. Branch on the terminal's `outcome` to
tell completion from failure from cancellation.

A rejection carries its diagnostics: the error's `details` hold the plan's `failureCode` and the
full `rejectedProviders` list, each with normalized reason codes such as `streaming_not_supported`,
`streaming_unavailable`, `privacy_constraint`, or `offline`. That is the only channel through which
a caller learns *why* each provider was refused, on every platform.

## Cancellation

- `cancel()` is **idempotent**. Calling it twice, concurrently, or after the terminal is a no-op.
- It produces **exactly one `cancelled` terminal**, carrying whatever text had already been
  delivered — including when nothing had been delivered yet.
- It **forecloses fallback**. Once cancellation is observed, no further provider from the planned
  chain is attempted.
- A provider's declared cancellation behavior (`hard` / `soft` / `none`) changes only how promptly
  that provider stops producing internally. It never changes what the caller sees.

Cancellation travels on an explicit token rather than the platform's ambient cancellation, because a
provider may produce its events from a task or scope it created itself, which would not inherit
cancellation from the consumer.

## Fallback

Streaming fallback is **narrower than Mode 1's**: a provider failure is fallback-eligible only
*before* the first content event has been admitted for the run. Once one has, the run is committed
to that provider and a later failure becomes a terminal `error` — never a silent provider swap,
since splicing partial text from two providers would be undetectable to the caller.

The candidate chain comes from the planner rather than from a filter applied afterwards, so every
fallback candidate is mode- and constraint-compatible by construction. A `local_required` stream can
never fall back to cloud.

## What streams today

The [provider matrix](architecture/providers.md#provider-matrix) is authoritative. What it means for
a consumer:

| Provider family | Streams | Consumer-visible consequences |
| --- | --- | --- |
| OpenAI-compatible | Web, iOS, Android | Token `content_delta`s. Needs a host with a streaming HTTP client, and an endpoint that speaks the OpenAI **Responses** API with `"stream": true` over `text/event-stream` |
| Apple Foundation Models | iOS / macOS | `content_snapshot` only. Reports neither a finish reason nor token usage, so completion is always `stop` with no `usage` |
| Android ML Kit GenAI | Android | `content_delta`. No token usage. A policy rejection emits an empty snapshot to retract, then fails `CapabilityMismatch` |
| ONNX Runtime | — | Mode 1 only |
| Web system-model (Chrome Prompt API) | — | Mode 1 only |

A stream request that no registered provider can serve is refused at routing time with a reason
naming each provider, rather than failing partway through. On-device providers need nothing from the
host; network providers need a host that can deliver a response body incrementally — all three
default host implementations provide one, and a host without it still runs Mode 1.

## Known divergence

`events` is single-use on every platform — a run is never replayed — but the platforms disagree on
how a second consumer finds out. Kotlin raises `IllegalStateException` on a second collect;
TypeScript and Swift complete without yielding. The shared guarantee is the no-replay, not the
signal. Recorded rather than forced: unifying it is a behavior decision, not a documentation one.

## Not in v0.3

Realtime sessions (Mode 3, `openSession()`) are unimplemented; the descriptor carries the seam and
nothing more. Task kinds other than `text_to_text` do not stream because they do not exist yet.

`run()` and `stream()` are the canonical `v0.3.0` execution API and deliberately not the final
developer ergonomics —
[Milestone 4](https://github.com/independo-gmbh/inderun/milestones) adds a familiar text-generation
facade and ecosystem adapters on top of them.
