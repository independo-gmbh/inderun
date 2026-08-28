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

The TypeScript Engine core (`packages/inderun-web/src/core/`) implements the Mode 2 orchestrator against these contracts: `IndeRun.stream()` returns a `StreamRunHandle` plus an `AsyncIterable<StreamEvent>` and a `cancel()` function.

The requested interaction mode is a **routing input**, not a filter applied after routing. The shared route planner receives the mode alongside the task and constraints, and rejects providers that cannot satisfy it — either because the descriptor does not statically declare the mode (`streaming_not_supported`) or because the provider's dynamic capability snapshot reports it cannot stream in the current host environment (`streaming_unavailable`). Both codes are part of the same normalized rejection vocabulary as the privacy, cloud, offline, and availability reasons, so a refused stream carries the same inspectable explanation as any other routing failure. A stream request and a run request over the same registry may therefore legitimately produce different provider chains, while remaining subject to identical privacy, locality, availability, and policy constraints. No shipped provider (OpenAI, ONNX Runtime, web system-model) implements `stream()` yet — the orchestrator is proven against a deterministic test-only provider — because real network streaming needs a host-services capability (chunked/SSE HTTP) that does not exist yet; see `docs/architecture/providers.md` for current per-provider status.

`StreamEvent` distinguishes user-visible content (`content_delta`, `content_snapshot`) from mechanical/diagnostic events (`lifecycle`, `diagnostic`, `terminal`), and every event carries a `sequence` number that is the ordering authority for a run — consumers must order by `sequence`, not by delivery order, since a bridge hop could reorder events. `StreamTerminalOutcome` expresses completion, error, and cancellation as a closed set of mutually exclusive outcomes, always the last thing produced for a run, consistent with the cancellation guarantee below. Unlike the terminal outcome, `StreamEvent.type` is an open set: schemas tolerate an unrecognized event type via a catch-all branch, and SDKs must treat one as ignore-or-pass-through-for-diagnostics rather than an error, so future additive event types don't break existing consumers. See `contracts/README.md` for the full schema evolution and compatibility policy.

An **Event Gate** (`packages/inderun-web/src/core/event-gate.ts`), one instance per run, is the structural mechanism behind the guarantees below: it assigns each run's `sequence` numbers and enforces, via a first-writer-wins terminate operation, that exactly one terminal `StreamEvent` is ever produced and that no event is admitted after it.

## Cancellation And Fallback

Cancellation produces exactly one terminal `cancelled` outcome and no further user-visible events after the cancel point; repeated or concurrent `cancel()` calls are idempotent by construction (first-writer-wins in the Event Gate). The engine normalizes `ProviderDescriptor.cancel`'s three values (`hard`/`soft`/`none`) into that single caller-facing guarantee: `cancel` only ever affects how promptly a provider stops emitting internally (immediate teardown for `hard`, stop-relaying-only for `soft`, engine-enforced-regardless for `none`) — never whether the caller sees a correct, single outcome.

Cancellation always forecloses fallback, and with it any further route attempt: once a signal is observed as aborted, the engine synthesizes the `cancelled` terminal outcome and stops, regardless of whether any content has been delivered yet, and no additional provider from the planned chain is tried. Independent of cancellation, streaming fallback itself is narrower than Mode 1's: a provider failure is only fallback-eligible *before* the first content event (`content_delta`/`content_snapshot`) has been admitted for the run. Once one has been delivered, the run is committed to that provider — a later provider failure becomes a terminal `error` outcome, never a silent provider swap, since splicing partial text from two different providers would be both undetectable to the caller and a leak of provider-specific mechanics.

Because the whole candidate chain comes from the planner rather than from a post-hoc filter, every fallback candidate is mode-compatible *and* constraint-compatible by construction: a `local_required` stream can never fall back to a cloud provider.

Fallback should be predictable and inspectable. If a preferred provider cannot execute, the engine should use the same normalized routing and error model rather than exposing provider-specific control flow to the app.

This also applies to the route *planner* itself, not just providers: on Web, routing is planned by the shared Rust/WASM core by default, with an in-process TypeScript re-implementation as a fallback when the WASM module is unavailable. That degradation must be inspectable rather than silent — the `route_decided` telemetry event's payload carries `plannerSource` (`"wasm"` or `"fallback"`) and, when the fallback was caused by a planner failure, `plannerUnavailableReason` (one of `"import_failed"`, `"invalid_module_shape"`, `"init_failed"`, `"plan_failed"`). See `docs/architecture/providers.md` for the loading mechanism and `packages/inderun-web/src/route-planner.ts` for the reason taxonomy.

## Security And Parity

Credentials must be referenced through secure storage, not embedded in request payloads. Cross-platform behavior should stay aligned even when the underlying runtime differs by OS or provider.

Bridge packages may accept minimal provider bootstrap options when the underlying platform SDK cannot infer required cloud-provider configuration from the canonical request alone. That bootstrap must stay limited to provider registration inputs and must not duplicate routing or orchestration semantics.

## Out Of Scope

Mode 4 submit/jobs infrastructure is out of scope for the current phase. The architecture may leave room for it, but this document should not spec that future work in detail.
