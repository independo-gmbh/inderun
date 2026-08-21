# Providers

This document explains the provider concept in IndeRun and records the provider families that currently exist in the repository.

## Vocabulary

- A provider is an execution backend chosen by routing.
- A runtime is the underlying system, framework, or API the provider wraps.
- Routing chooses providers, not models.

## Provider Contract

Every provider should define:

- a stable descriptor
- a dynamic capability check against the current host
- the interaction modes it supports
- its cancellation behavior
- normalized error and telemetry behavior

The code and public types should define the exact field shapes and behavior. This document only records the concept and the repository-level mapping.

## Error Model

There is one normalized error taxonomy (the `errorClass` values) shared across
every platform, defined by the `IndeRunError` schema in
`@independo/inderun-contracts`. Two names refer to it by layer, and both are
intentional:

- Native SDKs (TS/Web, Swift, Kotlin) throw an `IndeRunException` that carries an `errorClass`.
- The serialized, transport-facing form is the `IndeRunError` contract shape — this is what the Capacitor bridge re-throws across the JS boundary.

The class-to-cause mapping lives in code (provider adapters and the error
factories), not in prose.

The error model does not fork for streaming: `StreamTerminalOutcome`'s
`error` branch (`contracts/schemas/stream-terminal-outcome.schema.json`)
reuses the same `errorClass` taxonomy as `IndeRunError` rather than
introducing a stream-specific error vocabulary. See
[Streaming Contracts And Orchestration (Mode 2)](./architecture.md#streaming-contracts-and-orchestration-mode-2)
for the schemas and the orchestrator that now consumes them.

`ProviderDescriptor.cancel` (`hard` / `soft` / `none`) now has concrete,
tested engine-level semantics rather than being purely descriptive metadata:
the Mode 2 orchestrator normalizes all three into one caller-facing
guarantee — exactly one terminal outcome, idempotent cancellation. See
[Cancellation And Fallback](./architecture.md#cancellation-and-fallback).

## Provider Matrix

| Provider family | Web | iOS/macOS | Android | Classification | Task support | Interaction modes | Capability check | Credentials / model loading | Key limitations |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| OpenAI-compatible | Supported | Supported | Supported | Cloud | `text_to_text` | `run` (Mode 1) | Cheap unauthenticated `GET` probe against the configured endpoint, cached (`healthCheckCacheMs`, default 5000ms) | `authContextRef`; no raw secrets in payloads | No dedicated health endpoint; 4xx on the probe still counts as `available: true` |
| Apple Foundation Models | Not applicable | Supported | Not applicable | Platform-local | `text_to_text` | `run` (Mode 1) | Static host-service check (OS/device support) | None — OS-managed model | iOS/macOS only; model availability gated by OS |
| Android ML Kit GenAI (Gemini Nano) | Not applicable | Not applicable | Supported | Platform-local | `text_to_text` | `run` (Mode 1) | Static host-service check (device/OS support) | None — OS-managed model | Android only; device-tier gated |
| ONNX Runtime (`local.onnx.genai.*`) | Shipped (`@independo/inderun-web/onnx`) | Shipped (`IndeRunOnnxProviders` SwiftPM, iOS 16+/macOS 14+) | Shipped (`inderun-onnx-providers` Gradle module) | Custom/developer-supplied local | `text_to_text` | `run` (Mode 1) | Static + dynamic host capability check per platform | Developer supplies model + tokenizer files; no Hub network/download APIs called today | Android requires `libc++_shared.so` packaged by the consumer app; see [onnx-runtime-provider-family.md](onnx-runtime-provider-family.md) |
| Web system-model (`local.system-model.web`) | Shipped (`@independo/inderun-web/system-model`, Chrome Prompt API `LanguageModel`) | Not applicable | Not applicable | Browser-local | `text_to_text` | `run` (Mode 1) | Runtime feature-detection against the browser API | None — browser-managed model/download | Desktop Chrome 138+ only; degrades honestly (`capability_unavailable`) elsewhere; see [web-system-model-provider-family.md](web-system-model-provider-family.md) |

Streaming (`stream`) is not implemented by any shipped provider today — every row above still declares `supports.streaming: false`. Do not read this table as implying streaming support. The Mode 2 *orchestrator* (route selection, Event Gate, cancellation) is implemented in the TypeScript Engine core and proven end-to-end against a deterministic test-only provider; real provider streaming (e.g. OpenAI SSE) is blocked on a host-services chunked/SSE HTTP capability that does not exist yet. Realtime sessions (`openSession`, Mode 3) remain fully unimplemented. See [Streaming Contracts And Orchestration (Mode 2)](./architecture.md#streaming-contracts-and-orchestration-mode-2).

### Demos & Tests per Family

- **OpenAI-compatible** — `packages/inderun-web/src/providers/openai/provider.test.ts` (reachability, auth, rate-limit/timeout/unavailable/internal error mapping); iOS/Android per-provider suites in `ios/IndeRun/Tests/IndeRunTests` and `android/*/src/test`; live in every sample/demo app below.
- **Apple Foundation Models** — `ios/IndeRun/Tests/IndeRunTests` (descriptor, unavailable capability, run success, error mapping); demoed in `ios/SampleApps/IndeRunDemo`.
- **Android ML Kit GenAI** — `AndroidMlKitGenAiProviderTest.kt`; demoed in `android/inderun-demo-app`.
- **ONNX Runtime** — `packages/inderun-web/src/providers/onnx/{provider,transformers-runtime}.test.ts` (capability rejection, `local_required` no-fallback, runtime-error → error-class mapping); Apple/Android equivalents in the same test trees as above; demoed in `ios/SampleApps/IndeRunDemo` and `android/inderun-demo-app`.
- **Web system-model** — `packages/inderun-web/src/providers/system-model/{provider,chrome-runtime}.test.ts` (availability states, error mapping, `local_required` behavior). Not yet wired into `packages/inderun-web-demo` (tracked as a follow-up) — the web demo currently covers cloud + ONNX only.
- **Route selection/rejection + normalized errors** — `rust/inderun-route-core/src/tests.rs` is the canonical suite for rejection reasons (`rejected_providers[].reasons[].code`) and deterministic fallback ordering; `packages/inderun-web/src/core/engine.test.ts` covers the same at the TS engine layer (`CapabilityMismatch`/`Offline`/`Unavailable`, telemetry). The iOS and Android demo app READMEs each document an "Expected Failure Modes" section with concrete triggering scenarios per `errorClass`.

To run this coverage: `pnpm test:js` (Web/TS provider + engine tests), `cargo test -p inderun_route_core` (routing/rejection), `swift test` (iOS), `cd android && ./gradlew test` (Android). See each package's README for demo-app run instructions.

## Provider Notes

Implementation nuance not captured by the matrix above:

- **OpenAI-compatible reachability probe.** The `>= 5xx`-or-network-failure vs. everything-else
  (including 4xx) split exists because OpenAI-compatible servers have no dedicated health
  endpoint — a 4xx just means the probe request itself was rejected (method/auth mismatch), not
  that the service is down. Excluding a failing provider as a routing candidate up front means an
  unreachable endpoint fails fast with `Unavailable` instead of being attempted and timing out
  mid-request. The result is cached (`healthCheckCacheMs`) because the same `capabilities()` call
  backs both the router (every `run()`) and `checkCapabilities()` (UI introspection) — see
  `docs/architecture/architecture.md`.
- **ONNX Apple platform floor.** Shipping `IndeRunOnnxProviders` raised the whole SDK's Apple
  minimums to iOS 16 / macOS 14, not just for ONNX users — SwiftPM has no per-target platform
  override in a single manifest, so this was a package-wide, breaking bump. Implementation and
  known-issue details: [onnx-runtime-provider-family.md](onnx-runtime-provider-family.md).
- **ONNX Android native dependency.** `local.onnx.genai.android` requires `libc++_shared.so` per
  ABI; the module gets AGP to package it via a no-op CMake native target because
  `ai.djl.android:tokenizer-native`'s prebuilt `libdjl_tokenizer.so` links it dynamically without
  shipping it. Details: [Android Implementation](onnx-runtime-provider-family.md#android-implementation).
- **Web system-model** — the browser owns model availability/download/execution, unlike the
  developer-supplied ONNX family. Details: [web-system-model-provider-family.md](web-system-model-provider-family.md).
- Shared route planning: Rust core used by the TypeScript/Web side and WASM wrapper
  (`@independo/inderun-route-core-wasm`). The Web SDK's default `WasmRoutePlanner`
  (`packages/inderun-web/src/route-planner.ts`) loads it via a static, literal dynamic
  `import()` so bundlers (Vite et al.) can statically resolve and chunk it — see #109 for why
  a variable specifier silently never loads in a bundled browser build. If the module fails to
  import, initialize, or plan (network failure, unsupported environment, etc.), the planner
  degrades to the in-process TypeScript fallback planner and reports the reason via the
  `route_decided` telemetry event's `plannerSource`/`plannerUnavailableReason` fields (see
  `docs/architecture/architecture.md`) rather than failing the request or staying silent.

## Provider Authoring Workflow

To add a new provider:

1. Define the static descriptor (`describe`) — provider id, supported task kinds, supported interaction modes (`run` is implemented by all shipped providers; `stream` is implementable via the optional `ProviderAdapter.stream()` method and the Mode 2 orchestrator, though no shipped provider does so yet — see the Provider Matrix note above; `openSession`/Mode 3 remains a descriptor seam only), and declared cancellation behavior (`hard` / `soft` / `none`, now enforced by the Mode 2 orchestrator for streaming providers).
2. Implement the dynamic capability check (`capabilities(host)`) against the current host — static/OS checks first, then any runtime probe (network reachability, browser feature-detection, etc.), matching the pattern used by the existing providers in the matrix above.
3. Implement `run()` against the normalized `IndeRunApi` request/response shapes. Do not leak provider-specific request/response fields through the public API.
4. Map provider-specific failures onto the shared `errorClass` taxonomy (`IndeRunException` / `IndeRunError`, see [Error Model](#error-model)) in the adapter — do not invent a parallel error shape.
5. Resolve any credentials through `authContextRef`; never place raw secrets in request payloads.
6. Add tests/fixtures that distinguish "provider unavailable" (capability check fails, route rejected) from "provider available but `run()` failed" (normalized error surfaced).
7. Update this document: add a row to the [Provider Matrix](#provider-matrix) and, if there's implementation nuance worth recording, a bullet under [Provider Notes](#provider-notes). If the provider needs deeper documentation (e.g. a multi-platform family like ONNX Runtime), add a dedicated `docs/architecture/<family>.md` and link it from here.

See CLAUDE.md §5 for the durable version of the contract expectations above.

## Current Guidance

- Provider-specific behavior should stay behind provider adapters.
- Cloud credentials should be resolved through `authContextRef`.
- Capability checks should determine whether a provider is usable before execution.
- If a provider only supports Mode 1 today, this document should not imply shipping support for streaming or realtime sessions.
- Bridge layers such as Capacitor may pass provider bootstrap inputs like model or endpoint into existing provider adapters, but they should not add provider-specific execution branches beyond that registration step.

## What Belongs Elsewhere

Detailed request mapping, error tables, and per-provider option shapes belong in code comments, schema descriptions, and package-level README files for the relevant SDK or provider package.
