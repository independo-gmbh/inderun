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
- whether those modes and its cancellation behavior are actually available on the current host, when the runtime can take them away from a provider that otherwise declares them
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
| OpenAI-compatible | Supported | Supported | Supported | Cloud | `text_to_text` | `run` (Mode 1), `stream` (Mode 2, `tokens`, cancel `hard`) | Cheap unauthenticated `GET` probe against the configured endpoint, cached (`healthCheckCacheMs`, default 5000ms); reports `streamingAvailable: false` when the host has no `HttpStreamingClientService` | `authContextRef`; no raw secrets in payloads | No dedicated health endpoint; 4xx on the probe still counts as `available: true`; streaming requires a Responses-API-compatible SSE endpoint |
| Apple Foundation Models | Not applicable | Supported | Not applicable | Platform-local | `text_to_text` | `run` (Mode 1) | Static host-service check (OS/device support) | None — OS-managed model | iOS/macOS only; model availability gated by OS |
| Android ML Kit GenAI (Gemini Nano) | Not applicable | Not applicable | Supported | Platform-local | `text_to_text` | `run` (Mode 1) | Static host-service check (device/OS support) | None — OS-managed model | Android only; device-tier gated |
| ONNX Runtime (`local.onnx.genai.*`) | Shipped (`@independo/inderun-web/onnx`) | Shipped (`IndeRunOnnxProviders` SwiftPM, iOS 16+/macOS 14+) | Shipped (`inderun-onnx-providers` Gradle module) | Custom/developer-supplied local | `text_to_text` | `run` (Mode 1) | Static + dynamic host capability check per platform | Developer supplies model + tokenizer files; no Hub network/download APIs called today | Android requires `libc++_shared.so` packaged by the consumer app; see [onnx-runtime-provider-family.md](onnx-runtime-provider-family.md) |
| Web system-model (`local.system-model.web`) | Shipped (`@independo/inderun-web/system-model`, Chrome Prompt API `LanguageModel`) | Not applicable | Not applicable | Browser-local | `text_to_text` | `run` (Mode 1) | Runtime feature-detection against the browser API | None — browser-managed model/download | Desktop Chrome 138+ only; degrades honestly (`capability_unavailable`) elsewhere; see [web-system-model-provider-family.md](web-system-model-provider-family.md) |

The OpenAI-compatible family is the only one that streams today; every other row still declares `supports.streaming: false`, and the local/platform families are tracked separately (see the Milestone 3 issues for Apple Foundation Models and ML Kit streaming). Eligibility for a mode is decided by the shared route planner from the static declaration plus the dynamic capability snapshot, so a stream request that no registered provider can satisfy is refused at routing time with a normalized rejection reason naming each provider, rather than failing later without explanation — see [Streaming Contracts And Orchestration (Mode 2)](./architecture.md#streaming-contracts-and-orchestration-mode-2).

Streaming over the network needs a host capability the buffered `HttpClientService` cannot provide, so hosts may additionally expose an optional `HttpStreamingClientService` that resolves the response head first and delivers the body as incremental byte chunks. All three default host implementations provide it. A host that does not is a supported configuration: Mode 1 keeps working there, and providers report `streamingAvailable: false` with a reason, which the planner surfaces as a `streaming_unavailable` rejection.

Realtime sessions (`openSession`, Mode 3) remain fully unimplemented.

### Demos & Tests per Family

- **OpenAI-compatible** — `packages/inderun-web/src/providers/openai/provider.test.ts` (reachability, auth, rate-limit/timeout/unavailable/internal error mapping); iOS/Android per-provider suites in `ios/IndeRun/Tests/IndeRunTests` and `android/*/src/test`; live in every sample/demo app below.
- **Apple Foundation Models** — `ios/IndeRun/Tests/IndeRunTests` (descriptor, unavailable capability, run success, error mapping); demoed in `ios/SampleApps/IndeRunDemo`.
- **Android ML Kit GenAI** — `AndroidMlKitGenAiProviderTest.kt`; demoed in `android/inderun-demo-app`.
- **ONNX Runtime** — `packages/inderun-web/src/providers/onnx/{provider,transformers-runtime}.test.ts` (capability rejection, `local_required` no-fallback, runtime-error → error-class mapping); Apple/Android equivalents in the same test trees as above; demoed in `ios/SampleApps/IndeRunDemo` and `android/inderun-demo-app`.
- **Web system-model** — `packages/inderun-web/src/providers/system-model/{provider,chrome-runtime}.test.ts` (availability states, error mapping, `local_required` behavior). Not yet wired into `packages/inderun-web-demo` (tracked as a follow-up) — the web demo currently covers cloud + ONNX only.
- **Route selection/rejection + normalized errors** — `rust/inderun-route-core/src/tests.rs` is the canonical suite for rejection reasons (`rejected_providers[].reasons[].code`), including the streaming-mode rejections, and deterministic fallback ordering; `packages/inderun-web/src/core/router.stream.test.ts` covers the same rules end to end through the WASM core; `ios/IndeRun/Tests/IndeRunTests/IndeRunTests.swift` and `android/inderun-core/src/test/kotlin/app/independo/inderun/core/` cover the same rules end to end through the linked and JNI-loaded cores respectively; `packages/inderun-web/src/core/engine.test.ts` covers the same at the TS engine layer (`CapabilityMismatch`/`Offline`/`Unavailable`, telemetry). The iOS and Android demo app READMEs each document an "Expected Failure Modes" section with concrete triggering scenarios per `errorClass`.

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
- Shared route planning: one Rust core (`rust/inderun-route-core`), reached differently per
  platform. The Swift SDK links it from `ios/IndeRun/Frameworks/InderunRouteCoreFFI.xcframework`,
  a `binaryTarget` in `Package.swift` built by `scripts/build-route-core-apple.mjs` and
  committed to git — SwiftPM has no publish step, so a git tag has to contain the binary it
  needs. Because the symbols are linked rather than loaded, there is no "planner missing" state
  at runtime on iOS: `SharedCoreRoutePlanner` calls the two C entry points directly, and the
  build fails if they are absent. The Kotlin SDK packages it as `jniLibs` in `inderun-core`'s
  AAR, cross-compiled for the four Android ABIs by `scripts/build-route-core-android.mjs`.
  Those binaries are *not* committed: Android consumers resolve the module from Maven Central,
  where CI builds the AAR, so there is no equivalent of SwiftPM's "the git tag is the artifact".
  `SharedCoreRoutePlanner` reaches it with `System.loadLibrary`, so unlike iOS a missing library
  is a runtime failure — raised as `library_unavailable`, never swallowed. The JNI entry point
  sits behind the crate's `jni-bindings` feature rather than a `cfg(target_os = "android")`
  gate, which is what lets the JVM unit tests load a host build of the same library and reach
  the real planner. On Web the wrapper is the WASM package
  (`@independo/inderun-route-core-wasm`). The Web SDK's `WasmRoutePlanner`
  (`packages/inderun-web/src/core/route-planner.ts`) loads it via a static, literal dynamic
  `import()` so bundlers (Vite et al.) can statically resolve and chunk it — see #109 for why
  a variable specifier silently never loads in a bundled browser build. It is the only planner
  on Web: if the module fails to import, initialize, or plan, routing fails with an `Internal`
  error naming the reason (`plannerUnavailableReason`) instead of falling back to a second
  implementation of the same rules (see `docs/architecture/architecture.md` and issue #164).
  An environment that cannot instantiate WebAssembly — a Content-Security-Policy without
  `wasm-unsafe-eval`, or an offline app that did not precache the asset — therefore cannot
  route at all; the package's `./generated/*` export subpath exists so such apps can self-host
  and precache the `.wasm` explicitly.

## Provider Authoring Workflow

To add a new provider:

1. Define the static descriptor (`describe`) — provider id, supported task kinds, supported interaction modes (`run` is implemented by all shipped providers; `stream` is implemented by the OpenAI-compatible family and available to any provider that opts into the streaming adapter type — `ProviderAdapter.stream()` on Web, `StreamingProviderAdapter` on Swift and Kotlin; `openSession`/Mode 3 remains a descriptor seam only), and declared cancellation behavior (`hard` / `soft` / `none`, now enforced by the Mode 2 orchestrator for streaming providers). `supports.streaming` is what makes a provider routable for a stream request at all, so declaring it without implementing `stream()` is a routing-visible mistake, not a harmless one.
2. Implement the dynamic capability check (`capabilities(host)`) against the current host — static/OS checks first, then any runtime probe (network reachability, browser feature-detection, etc.), matching the pattern used by the existing providers in the matrix above. Report `streamingAvailable` (with a `streamingUnavailableReason`) only when the host can take streaming away from a provider that statically declares it; leaving it unset inherits the descriptor.
3. Implement `run()` against the normalized `IndeRunApi` request/response shapes. Do not leak provider-specific request/response fields through the public API.
4. Map provider-specific failures onto the shared `errorClass` taxonomy (`IndeRunException` / `IndeRunError`, see [Error Model](#error-model)) in the adapter — do not invent a parallel error shape.
5. Resolve any credentials through `authContextRef`; never place raw secrets in request payloads.
6. Add tests/fixtures that distinguish "provider unavailable" (capability check fails, route rejected) from "provider available but `run()` failed" (normalized error surfaced).
7. If the provider streams, map its wire events onto the canonical provider event vocabulary against a shared fixture rather than a per-platform test suite. `contracts/fixtures/streaming/` holds those vectors: `sse-framing.json` for the server-sent events framer in each core, and `openai-responses-transcript.json` for the OpenAI event mapping. Each is loaded by the TypeScript, Swift, and Kotlin suites, which is what keeps three separate implementations of one protocol from drifting.
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
