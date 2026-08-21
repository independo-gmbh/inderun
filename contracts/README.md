# IndeRun Contracts

This directory contains the canonical JSON Schema sources for serializable IndeRun contracts.

`contracts/schemas/*.schema.json` is the source of truth for schema-backed payloads across TypeScript, Swift, Kotlin,
and bridge layers. Run `pnpm generate` to regenerate language-specific artifacts.

This includes both the public Mode-1 request/result/error contracts and the shared route-planner boundary contracts
used by the Rust route-planning core (`route-planner-input.schema.json` and `route-plan.schema.json`).

It also includes provider-family bootstrap contracts such as `model-package.schema.json` (the
provider-neutral `ModelPackage` used by local-model provider families; see
`docs/architecture/onnx-runtime-provider-family.md`).

It also includes the canonical Mode 2 streaming contracts — `stream-run.schema.json`
(`StreamRunHandle`), `stream-event.schema.json` (`StreamEvent`), and
`stream-terminal-outcome.schema.json` (`StreamTerminalOutcome`). These are a schema-only design
seam today: no engine or provider implements streaming yet (see
`docs/architecture/architecture.md#streaming-contracts-mode-2-design-seam`).

The repo-level generator lives at `contracts/scripts/generate-contracts.mjs`. It emits TypeScript artifacts for
`@independo/inderun-contracts`, Swift models for `IndeRunContracts`, Kotlin models under the
`app.independo.inderun.contracts` package, and Rust types for the shared route-planner core
(`rust/inderun-route-core/src/generated/contracts.rs`, generated from the route-planner-only subset of the schemas).

## Schema evolution and forward compatibility

- **Additive, backward-compatible changes** (new optional properties, a new `StreamEvent.type`
  variant) do not bump `schemaVersion` or the `$id` version segment. Every schema keeps
  `additionalProperties: true` for this reason, and `StreamEvent` specifically closes its type
  union with an open catch-all branch so a consumer built against an older revision of the schema
  does not hard-fail when a newer, additive revision introduces a new known event type.
- **Breaking changes** (removing/renaming a required field, changing what a `const`/`enum` value
  means) require a new `$id` version segment (e.g. `.../2.0/...`) and a new `schemaVersion` const,
  coexisting with `1.0` during a migration window. The existing "rejects unsupported schema
  versions" tests in `packages/contracts/src/validators.test.ts` already assert an out-of-range
  `schemaVersion` is rejected by the current validator — that mechanism is what a version bump
  relies on.
- **Consumer-side behavioral policy** (JSON Schema alone can't express this — it's a contract on
  SDK behavior, not payload shape): SDKs MUST treat an unrecognized `StreamEvent.type` as
  ignore-or-pass-through-for-diagnostics, never as a hard error/exception. See the `description`
  field of `stream-event.schema.json` for the schema-level statement of this policy.

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
