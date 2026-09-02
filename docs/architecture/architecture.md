# Architecture

This document describes the conceptual architecture of IndeRun. It stays intentionally high level so the code and schemas remain the source of detailed behavior.

## Layers

IndeRun is organized into four layers:

- Application consumers, such as web apps, native mobile apps, and demo apps
- Public SDK surfaces, such as the TypeScript, Swift, and Kotlin entrypoints
- Engine core and host services, which own routing, orchestration, telemetry, and platform access
- Provider adapters, which wrap local runtimes, system services, or cloud APIs

The separation matters because provider-specific details should remain behind adapter boundaries whenever a normalized IndeRun shape exists.

## Execution Model

The current public execution path is Mode 1 `run()`. The engine validates the request, selects a provider deterministically, executes the request, and normalizes the result or error.

The same conceptual model is shared across platforms:

- request and result shapes come from the schema-backed contracts
- host services provide connectivity, storage, timing, HTTP, and telemetry access
- provider adapters advertise static and dynamic capability information
- routing stays deterministic for a fixed request, policy, and capability snapshot

Capacitor is treated as an app-facing bridge layer over the existing platform SDKs, not as a separate execution engine. The Capacitor package should forward canonical requests into the existing Web, Swift, and Kotlin SDKs and return the same normalized result and error shapes.

Alongside `run()`, the engine exposes `checkCapabilities()`: a read-only introspection call that returns each registered provider's static descriptor and current dynamic capability check without executing a task or producing side effects. It exists with the same shape on the TypeScript, Swift, and Kotlin engines, and is intended for UI that needs to show live provider availability before a run (for example, the Web demo's provider badges).

`IndeRun`'s method-signature surface (`run`/`checkCapabilities`) across TypeScript, Swift, and Kotlin is now generated from a versioned spec and CI-enforced — each platform's hand-written `IndeRun` class implements/conforms to the generated `IndeRunApi` interface/protocol, and CI fails on regeneration drift. `ProviderAdapter` parity is still kept in sync by convention and review, not generation. See [`api-surface-generation.md`](./api-surface-generation.md) for the research pass and current status.

### Streaming Contracts And Orchestration (Mode 2)

The canonical data shapes for Mode 2 streaming — `StreamRunHandle`, `StreamEvent`, and `StreamTerminalOutcome` — exist as versioned JSON Schema contracts with generated TypeScript, Swift, and Kotlin types (`contracts/schemas/stream-run.schema.json`, `stream-event.schema.json`, `stream-terminal-outcome.schema.json`).

All three engines implement the Mode 2 orchestrator against these contracts. `IndeRun.stream()` returns the run handle, its canonical event sequence, and a `cancel()` hook, expressed in each platform's idiom — an `AsyncIterable` on TypeScript, an `AsyncThrowingStream` on Swift, a cold single-use `Flow` on Kotlin — and is declared on the generated `IndeRunApi` surface so the three signatures cannot drift. Providers opt into streaming through a distinct adapter type (an optional `stream()` member on TypeScript, a `StreamingProviderAdapter` protocol/interface on Swift and Kotlin), which is what lets the router check that a provider both declares streaming *and* implements it before planning a route to it.

Cancellation travels through an explicit token rather than each platform's ambient cancellation mechanism. A provider is free to produce its events from a task or scope it created itself, which does not inherit cancellation from the consumer, so an explicit signal is the only thing that makes the guarantee independent of how a given provider happens to be written.

The requested interaction mode is a **routing input**, not a filter applied after routing. The shared route planner receives the mode alongside the task and constraints, and rejects providers that cannot satisfy it — either because the descriptor does not statically declare the mode (`streaming_not_supported`) or because the provider's dynamic capability snapshot reports it cannot stream in the current host environment (`streaming_unavailable`). Both codes are part of the same normalized rejection vocabulary as the privacy, cloud, offline, and availability reasons, so a refused stream carries the same inspectable explanation as any other routing failure. A stream request and a run request over the same registry may therefore legitimately produce different provider chains, while remaining subject to identical privacy, locality, availability, and policy constraints. Streaming over the network requires a host capability the buffered HTTP client cannot provide, so `HostServices` carries an optional streaming HTTP client that resolves the response head before delivering the body as incremental byte chunks. Separating head from body is what lets a provider classify a non-2xx response through the normal error taxonomy before deciding to read the body as a protocol stream. Server-sent events framing lives in each SDK core rather than in the host or the provider — the host stays a byte pipe, and one framer per platform is held to shared vectors instead of one per adapter. The OpenAI-compatible provider streams on all three platforms; see `docs/architecture/providers.md` for current per-provider status.

`StreamEvent` distinguishes user-visible content (`content_delta`, `content_snapshot`) from mechanical/diagnostic events (`lifecycle`, `diagnostic`, `terminal`), and every event carries a `sequence` number that is the ordering authority for a run — consumers must order by `sequence`, not by delivery order, since a bridge hop could reorder events. `StreamTerminalOutcome` expresses completion, error, and cancellation as a closed set of mutually exclusive outcomes, always the last thing produced for a run, consistent with the cancellation guarantee below. Unlike the terminal outcome, `StreamEvent.type` is an open set: schemas tolerate an unrecognized event type via a catch-all branch, and SDKs must treat one as ignore-or-pass-through-for-diagnostics rather than an error, so future additive event types don't break existing consumers. See `contracts/README.md` for the full schema evolution and compatibility policy.

An **Event Gate** (`packages/inderun-web/src/core/event-gate.ts`), one instance per run, is the structural mechanism behind the guarantees below: it assigns each run's `sequence` numbers and enforces, via a first-writer-wins terminate operation, that exactly one terminal `StreamEvent` is ever produced and that no event is admitted after it.

## Cancellation And Fallback

Cancellation produces exactly one terminal `cancelled` outcome and no further user-visible events after the cancel point; repeated or concurrent `cancel()` calls are idempotent by construction (first-writer-wins in the Event Gate). The engine normalizes `ProviderDescriptor.cancel`'s three values (`hard`/`soft`/`none`) into that single caller-facing guarantee: `cancel` only ever affects how promptly a provider stops emitting internally (immediate teardown for `hard`, stop-relaying-only for `soft`, engine-enforced-regardless for `none`) — never whether the caller sees a correct, single outcome.

Cancellation always forecloses fallback, and with it any further route attempt: once a signal is observed as aborted, the engine synthesizes the `cancelled` terminal outcome and stops, regardless of whether any content has been delivered yet, and no additional provider from the planned chain is tried. Independent of cancellation, streaming fallback itself is narrower than Mode 1's: a provider failure is only fallback-eligible *before* the first content event (`content_delta`/`content_snapshot`) has been admitted for the run. Once one has been delivered, the run is committed to that provider — a later provider failure becomes a terminal `error` outcome, never a silent provider swap, since splicing partial text from two different providers would be both undetectable to the caller and a leak of provider-specific mechanics.

Because the whole candidate chain comes from the planner rather than from a post-hoc filter, every fallback candidate is mode-compatible *and* constraint-compatible by construction: a `local_required` stream can never fall back to a cloud provider.

Fallback should be predictable and inspectable. If a preferred provider cannot execute, the engine should use the same normalized routing and error model rather than exposing provider-specific control flow to the app.

The route *planner* is deliberately not covered by that fallback principle. All three SDKs have exactly one planner — the shared Rust core — and a planner that cannot answer fails the request with an `Internal` error carrying the reason, rather than re-planning locally. A second planner would have to restate the ranking and rejection rules, and a restatement that drifts turns a load failure into a silent change of *which provider runs*: issue #164 records that drift on Web, and issues #171 and #172 the same on iOS and Android, where the restatement was not a fallback at all but the only planner that ever ran.

How the core is reached differs by platform, and so does the reason vocabulary. The Web SDK fetches and instantiates a WASM module at runtime, so it can fail to load (`"import_failed"`, `"invalid_module_shape"`, `"init_failed"`, `"plan_failed"`). The Swift SDK links the core from an XCFramework, so a missing planner is a build-time link error and cannot be a runtime state; only encoding and decoding failures remain (`"input_encode_failed"`, `"plan_failed"`, `"invalid_plan_shape"`). The Kotlin SDK loads the core with `System.loadLibrary` from the AAR's `jniLibs`, so an absent library is a runtime state again (`"library_unavailable"`, `"plan_failed"`, `"invalid_plan_shape"`). Web's `route_decided` telemetry event still carries `plannerSource` and `plannerUnavailableReason`; with a single planner they are always `"wasm"` and `null`. The Swift and Kotlin SDKs never carried either field on that event, and adding them now would only ever report constants. See `docs/architecture/providers.md` for the distribution mechanisms, and `packages/inderun-web/src/core/route-planner.ts`, `ios/IndeRun/Sources/IndeRunCore/SharedRoutePlanner.swift` and `android/inderun-core/src/main/kotlin/app/independo/inderun/core/SharedCoreRoutePlanner.kt` for the reason taxonomies.

## Security And Parity

Credentials must be referenced through secure storage, not embedded in request payloads. Cross-platform behavior should stay aligned even when the underlying runtime differs by OS or provider.

Bridge packages may accept minimal provider bootstrap options when the underlying platform SDK cannot infer required cloud-provider configuration from the canonical request alone. That bootstrap must stay limited to provider registration inputs and must not duplicate routing or orchestration semantics.

## Out Of Scope

Mode 4 submit/jobs infrastructure is out of scope for the current phase. The architecture may leave room for it, but this document should not spec that future work in detail.
