# IndeRun Contracts

This directory contains the canonical JSON Schema sources for serializable IndeRun contracts.

`contracts/schemas/*.schema.json` is the source of truth for schema-backed payloads across TypeScript, Swift, Kotlin,
and bridge layers. Run `pnpm generate` to regenerate language-specific artifacts.

This includes both the public Mode-1 request/result/error contracts and the shared route-planner boundary contracts
used by the Rust route-planning core (`route-planner-input.schema.json` and `route-plan.schema.json`).

It also includes provider-family bootstrap contracts such as `model-package.schema.json` (the
provider-neutral `ModelPackage` used by local-model provider families; see
`docs/architecture/onnx-runtime-provider-family.md`).

The repo-level generator lives at `contracts/scripts/generate-contracts.mjs`. It emits TypeScript artifacts for
`@independo/inderun-contracts`, Swift models for `IndeRunContracts`, Kotlin models under the
`app.independo.inderun.contracts` package, and Rust types for the shared route-planner core
(`rust/inderun-route-core/src/generated/contracts.rs`, generated from the route-planner-only subset of the schemas).

## API surface generation

Alongside the data-contract pipeline above, `contracts/api/inderun-api.json` is a small versioned spec
describing **behavioral** interface signatures — method names, params, return types, async-ness, and thrown-error
type — for IndeRun's app-facing API surface. It is a separate, sibling pipeline: data contracts describe shapes,
this spec describes methods.

The generator lives at `contracts/scripts/generate-api-surface.mjs` and runs as part of `pnpm generate:code`. It
emits the `IndeRunApi` interface/protocol for TypeScript, Swift, and Kotlin, and the hand-written `IndeRun` class on
each platform implements/conforms to the generated declaration. CI fails if regenerating produces an uncommitted
diff.

Scoped for now to `IndeRunApi` (`run` and `checkCapabilities`) only. See
[`docs/architecture/api-surface-generation.md`](../docs/architecture/api-surface-generation.md) for the research
pass, options considered, and remaining scope (`ProviderAdapter`, streaming/session operations).
