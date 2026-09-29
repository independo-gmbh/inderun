# Streaming Conformance and Cross-Platform Validation

Mode 2 is implemented four times: once per SDK (TypeScript, Swift, Kotlin) plus a Capacitor bridge
that carries the result across a JS boundary. This document says what proves those implementations
agree, and — just as importantly — what they do not prove, so the gaps are chosen rather than
assumed.

Three things are kept separate throughout, because conflating them is how a suite comes to look
more convincing than it is:

| | What it covers | Where it runs |
| --- | --- | --- |
| **Automated** | Contracts, orchestration, event ordering, cancellation, routing, telemetry | CI, every push |
| **Real-device** | That the hardware and OS frameworks behave as the adapters assume | A human, on a device |
| **External-service** | That a real upstream model API behaves as the adapters assume | A human, against a live endpoint |

---

## The shared conformance catalog

[`contracts/fixtures/streaming/engine-conformance.json`](../contracts/fixtures/streaming/engine-conformance.json)
holds 33 scenarios every engine must satisfy identically. Each SDK registers one handler per case
id, and a guard test fails when the handler ids and the catalog ids are not **equal** — so a
scenario covered on one platform and not another is a red build, not something a reviewer has to
notice.

| SDK | Suite |
| --- | --- |
| TypeScript | [`packages/inderun-web/src/core/engine.conformance.test.ts`](../packages/inderun-web/src/core/engine.conformance.test.ts) |
| Swift | [`ios/IndeRun/Tests/IndeRunTests/StreamConformanceTests.swift`](../ios/IndeRun/Tests/IndeRunTests/StreamConformanceTests.swift) |
| Kotlin | [`android/inderun-kotlin/src/test/kotlin/app/independo/inderun/sdk/IndeRunStreamConformanceTest.kt`](../android/inderun-kotlin/src/test/kotlin/app/independo/inderun/sdk/IndeRunStreamConformanceTest.kt) |

### Why a catalog and not a fixture

The two files beside it — `sse-framing.json` and `openai-responses-transcript.json` — are fully
data-driven: bytes in, events out, one interpreter per language. This one is not. The setup and the
expected *observable outcome* are shared data, but the trigger (when a cancel lands relative to a
provider emit) stays in each platform's own concurrency primitives, because Swift structured
concurrency, a Kotlin cold `Flow` and JS microtasks do not coordinate identically. Encoding that
timing in JSON would make the fixture own behaviour that belongs to the engines.

What the catalog is therefore *for* is the expectation, and the guard is what makes it binding.

### What the 33 cases cover

- **success_and_ordering** (5) — delta ordering with gap-free `sequence` numbering; a snapshot
  replacing rather than appending; `finishReason` and `usage` surfaced when the provider reports
  them and absent when it does not; `StreamRunHandle.startedAt` being Unix epoch milliseconds.
- **terminal_outcomes** (4) — `completed`, `error` with its normalized class, `cancelled` with its
  partial text and reason, and that nothing is delivered after the terminal.
- **cancellation** (6) — before the first attempt (no provider entered), during emit, after the
  terminal (a no-op), two cancels where the caller's order decides the reason, during a *pre-commit*
  attempt (cancellation beats fallback), and reaching a provider blocked waiting for output.
- **routing_and_fallback** (10) — no streaming-capable provider; declared-but-not-implemented;
  dynamic capability revocation with the provider's own message; the rejection carrying its
  `failureCode` and per-provider reason codes; privacy enforced on stream routes; `Offline`
  distinguished from `CapabilityMismatch`; run and stream resolving different chains; fallback
  before commit and never after it.
- **provider_faults** (4) — a stream that ends with no terminal; a failure the provider *emits*
  rather than throws; a duplicate terminal from a buggy provider; an empty snapshot retracting
  delivered content.
- **telemetry** (3) — the event sequence for a normal completion; that a cancellation's telemetry
  carries neither the caller's reason text nor the model output; that a failure's telemetry carries
  the stable per-class message rather than the upstream's raw text.
- **lifecycle** (1) — that a second consumer never replays a finished run.

### Known divergence

`events_are_single_use` is the one case where the platforms differ in *how* they satisfy the
guarantee. Kotlin raises `IllegalStateException` on a second collect; TypeScript and Swift complete
without yielding. The shared guarantee — the run is never replayed — holds everywhere, and the
catalog asserts that rather than forcing one mechanism. Unifying it is a behaviour decision that
belongs upstream of a conformance suite; it is recorded here so it is a choice and not a surprise.

### Deliberately outside the catalog

Coverage that only one platform can have, and so has no counterpart to stay in step with:

- **Apple Foundation Models** streaming end to end through the engine, and its cancellation
  (`IndeRunTests.swift`).
- **Android ML Kit GenAI** streaming end to end, its cancellation, and a real policy rejection
  retracting delivered content (`IndeRunStreamTest.kt`).
- **ARC teardown** — a stream outliving the engine that created it (`StreamOrchestrationTests`).
- **Web** — an empty registry, where the planner has nothing to reject at all
  (`engine.stream.test.ts`).

---

## The rest of the automated surface

| Suite | What it proves |
| --- | --- |
| `sse-framing.json` (3 SDKs) | The server-sent events framer in each core, against one set of byte-level vectors including chunk boundaries inside multi-byte UTF-8 |
| `openai-responses-transcript.json` (3 SDKs) | The OpenAI Responses event mapping in each adapter, against one set of transcripts |
| Per-provider adapter suites | Each provider's own event, error and cancellation contract against a fake runtime |
| Route planner (Rust, plus its WASM and FFI bindings) | Provider selection and rejection codes, from one implementation shared by all three SDKs |

### The Capacitor bridge

The bridge is a separate repository
([`independo-gmbh/capacitor-inderun`](https://github.com/independo-gmbh/capacitor-inderun)) and its
job is **transport**, not orchestration: it carries the canonical event sequence across the JS
boundary and performs no routing, no fallback and no terminal decisions of its own. Engine scenarios
therefore do not re-apply to it, and it does not drive this catalog.

What it does prove, automatically: 37 Vitest cases over the JS reassembler — ordering by `sequence`
rather than arrival, duplicates dropped, post-terminal events dropped, an unrecognized event type
passed through, a sequence gap that never closes surfacing as a transport error rather than an
invented ending, cancel before the first event / mid-stream / after the terminal, concurrent runs
kept separate, and listener registration and removal — plus 20 streaming XCTest cases and 19
streaming JUnit cases over the native codecs, registries and pumps.

What it cannot prove without a device is in [Real-device validation](#real-device-validation).

---

## Real-device validation

The on-device provider suites drive **fake runtimes**. They prove each adapter's event, error and
cancellation contract; they do not prove that the hardware chunks incrementally, reports finish
reasons, or stops generating when cancelled. Only these checklists do:

| Platform | Checklist | Needs |
| --- | --- | --- |
| iOS / macOS | [`ios/SampleApps/IndeRunDemo/README.md`](../ios/SampleApps/IndeRunDemo/README.md) § Manual Streaming Test (Mode 2) | An Apple Intelligence–capable device |
| Android | [`android/inderun-demo-app/README.md`](../android/inderun-demo-app/README.md) § Manual Streaming Test (Mode 2) | A device with AICore and Gemini Nano ready |
| Web | [`packages/inderun-web-demo/README.md`](../packages/inderun-web-demo/README.md) § Manual Streaming Test (Mode 2) | A real browser — jsdom does not stream a `fetch` body |
| Capacitor | `example-app/README.md` in the bridge repository | A real iOS and Android device |

The Capacitor checklist is the only one that exercises Capacitor's actual listener transport and
plugin teardown (`deinit` on iOS, `handleOnDestroy` on Android), which no unit suite can reach.

---

## External-service validation

Anything that goes through [`@independo/inderun-demo-proxy`](../packages/inderun-demo-proxy) to a
real upstream — OpenAI, or a local Ollama — is external-service validation. The OpenAI adapter's
automated coverage replays recorded transcripts, so it proves the mapping and not that a live
endpoint still emits those events in that shape.

Run it when the upstream's streaming protocol may have changed, and when validating a new
OpenAI-compatible endpoint. The setup is in each demo README's *Demo Proxy Setup* section. No demo
ever embeds a credential: the browser or device sends `auth: "none"` and the proxy holds the key.

---

## Expected failure modes

Three distinct surfaces, listed together because conflating them is the most common misreading of
Mode 2:

| Surface | Cause | What the caller sees |
| --- | --- | --- |
| **Rejection** | Request validation, or routing finds no streaming-capable provider | `stream()` throws. No run handle, no events. The error carries the plan's `failureCode` and per-provider reason codes. |
| **Terminal `error` outcome** | A provider failed after content was committed, or the whole chain failed | A normal `StreamEvent` with `type: "terminal"` and `payload.outcome: "error"`. The iteration **completes**; it does not throw. |
| **Terminal `cancelled` outcome** | The caller cancelled | A normal terminal event carrying the partial text and the reason. Not an error. |

A fourth exists only across the Capacitor bridge: a **transport fault** — the native pump failing,
or a `sequence` gap that never closes — makes the JS iterable throw. That says the transport failed,
not that the run did, and the bridge never synthesizes a terminal to paper over it.

---

## Running it

```sh
pnpm test:js                      # TypeScript, including the conformance suite
cd android && ./gradlew test      # Kotlin, including the conformance suite
swift test                        # Swift, including the conformance suite
```

The load-bearing check is the guard, not the case count. To confirm it still works, add a case id to
the catalog and check that all three language suites go red, then remove it. Android declares
`contracts/fixtures/streaming` as an input of every test task for this reason — without it Gradle
reports the suites up to date after a fixture-only change and skips them, which is exactly when they
most need to run.
