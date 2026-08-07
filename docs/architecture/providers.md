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
- Custom/developer-supplied local models: ONNX Runtime provider family (Milestone 2, specified in
  [onnx-runtime-provider-family.md](onnx-runtime-provider-family.md))
  - Web on-device: `local.onnx.genai.web`, shipped in `@independo/inderun-web/onnx`
  - Android and Apple members are not implemented yet (#87/#86)
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
