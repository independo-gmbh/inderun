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

## Current Provider Families

- iOS on-device: Apple Foundation Models provider
- Android on-device: ML Kit GenAI provider
- Web and native cloud: OpenAI-compatible provider
  - `capabilities()` probes endpoint reachability with a cheap, unauthenticated `GET` against the
    configured endpoint after the static host-service checks pass — the OpenAI API (and
    OpenAI-compatible servers generally) has no dedicated health endpoint, so this is the
    lightest-weight signal available. A response with status `>= 500`, or a network-level probe
    failure (timeout, connection error), reports `available: false`; any other HTTP response
    (including 4xx, which just signals a method/auth mismatch on the probe request, not that the
    service is down) reports `available: true`. Because a provider that fails this probe is
    excluded as a routing candidate before `run()` is attempted, an unreachable endpoint now fails
    fast with an `Unavailable` error instead of being attempted and timing out mid-request. The
    result is cached briefly (`healthCheckCacheMs`, default 5000ms) since this same
    `capabilities()` call is shared by both the router (on every real `run()`) and
    `checkCapabilities()` (UI introspection) — see `docs/architecture/architecture.md`.
- Custom/developer-supplied local models: ONNX Runtime provider family (Milestone 2, specified in
  [onnx-runtime-provider-family.md](onnx-runtime-provider-family.md))
  - Web on-device: `local.onnx.genai.web`, shipped in `@independo/inderun-web/onnx`
  - Android and Apple members are not implemented yet (#87/#86)
- Browser-managed on-device models: Web system-model provider family (Milestone 2, specified in
  [web-system-model-provider-family.md](web-system-model-provider-family.md)) — the browser owns
  model availability/download/execution, unlike the developer-supplied ONNX family
  - Web on-device: `local.system-model.web` (Chrome Prompt API, `LanguageModel`), shipped in
    `@independo/inderun-web/system-model`
  - Desktop Chrome 138+ only; degrades honestly (`capability_unavailable`) elsewhere
- Shared route planning: Rust core used by the TypeScript/Web side and WASM wrapper
  (`@independo/inderun-route-core-wasm`). The Web SDK's default `WasmRoutePlanner`
  (`packages/inderun-web/src/route-planner.ts`) loads it via a static, literal dynamic
  `import()` so bundlers (Vite et al.) can statically resolve and chunk it — see #109 for why
  a variable specifier silently never loads in a bundled browser build. If the module fails to
  import, initialize, or plan (network failure, unsupported environment, etc.), the planner
  degrades to the in-process TypeScript fallback planner and reports the reason via the
  `route_decided` telemetry event's `plannerSource`/`plannerUnavailableReason` fields (see
  `docs/architecture/architecture.md`) rather than failing the request or staying silent.

## Current Guidance

- Provider-specific behavior should stay behind provider adapters.
- Cloud credentials should be resolved through `authContextRef`.
- Capability checks should determine whether a provider is usable before execution.
- If a provider only supports Mode 1 today, this document should not imply shipping support for streaming or realtime sessions.
- Bridge layers such as Capacitor may pass provider bootstrap inputs like model or endpoint into existing provider adapters, but they should not add provider-specific execution branches beyond that registration step.

## What Belongs Elsewhere

Detailed request mapping, error tables, and per-provider option shapes belong in code comments, schema descriptions, and package-level README files for the relevant SDK or provider package.
