# IndeRun Contracts

This directory contains the canonical JSON Schema sources for serializable IndeRun contracts.

`contracts/schemas/*.schema.json` is the source of truth for schema-backed payloads across TypeScript, Swift, Kotlin,
and bridge layers. Run `pnpm generate` to regenerate language-specific artifacts.

This includes both the public Mode-1 request/result/error contracts and the shared route-planner boundary contracts
used by the Rust route-planning core (`route-planner-input.schema.json` and `route-plan.schema.json`). The request and
result are task-generic ([ADR 016](../docs/architecture/decisions/016-modality-extensible-task-contracts.md)):
`task-request.schema.json` admits `text_to_text` and `text_to_speech`, and the result's `output` is a
`task-output.schema.json` (`TaskOutput`) whose `type` is `text`, `playback` or `artifact`. An artifact output
references a `media-artifact.schema.json` (`MediaArtifact`): an engine-issued id plus metadata, never bytes
([ADR 017](../docs/architecture/decisions/017-media-artifacts.md)).

It also includes provider-family bootstrap contracts such as `model-package.schema.json` (the
provider-neutral `ModelPackage` used by local-model provider families; see
`docs/architecture/onnx-runtime-provider-family.md`).

It also includes the canonical Mode 2 streaming contracts — `stream-run.schema.json`
(`StreamRunHandle`), `stream-event.schema.json` (`StreamEvent`), and
`stream-terminal-outcome.schema.json` (`StreamTerminalOutcome`). The TypeScript Engine core
implements the Mode 2 orchestrator against these, and `route-planner-input.schema.json` carries
the requested `interactionMode` plus the static/dynamic streaming capability fields the planner
needs to route it. The TypeScript, Swift, and Kotlin engines all implement Mode 2, and the
OpenAI-compatible provider streams on all three (see
`docs/architecture/architecture.md#streaming-contracts-and-orchestration-mode-2`). What these shapes
add up to for a consumer — event semantics, ordering, cancellation, fallback — is
[`docs/streaming.md`](../docs/streaming.md).

`fixtures/streaming/` holds cross-SDK conformance vectors for behavior that is implemented
separately per platform and so has no generator keeping it in sync: `sse-framing.json` for the
server-sent events framer in each core, and `openai-responses-transcript.json` for the OpenAI
event mapping in each adapter. Each is loaded directly by all three test suites.

`engine-conformance.json` sits in the same directory but is a different kind of artifact. The two
above are fully data-driven — bytes in, events out — while this one is a **scenario catalog** for
Mode 2 orchestration: the setup and the expected observable outcome are shared data, but the trigger
(when a cancel lands relative to a provider emit) stays in each platform's own concurrency
primitives. Each SDK registers one handler per case id and a guard test fails when the handler ids
and the catalog ids are not equal, so a scenario covered on one platform and not another is a red
test rather than a review finding. See [`docs/streaming-conformance.md`](../docs/streaming-conformance.md).

`fixtures/facade/text-generation.json` is a fully data-driven vector like `sse-framing.json`, for the primary text API: facade
options in, the exact canonical `TaskRequest` out. All three SDKs run every case through their own
`generateText`/`streamText` translation, which is what holds the facades to one mapping without
declaring them on the generated `IndeRunApi`.

`fixtures/task-contracts/` holds the three examples ADR 016 is checked against: text generation, text-to-speech
(managed playback and a retrievable artifact), and a contract-only image-to-text case. Each file's `status` says
what the committed schemas must do with it — `current` cases must validate, `proposed` and `contract_only` cases
must be rejected at `/task/kind` until the schema change that admits them lands —
and `packages/contracts/src/task-contract-fixtures.test.ts` enforces that. Text and text-to-speech are `current`;
image-to-text stays a contract-only vector. `fixtures/artifacts/media-artifacts.json` holds valid and invalid
`MediaArtifact` references, an image among them to keep the reference media-neutral.

`fixtures/routing/planner-conformance.json` holds the shared route-planner vectors: complete `RoutePlannerInput`s and
the exact `RoutePlan` each must produce, messages included. The planner is one Rust crate, so these check the
boundaries around it — that every platform hands it the same shape and reads the same plan back. The Rust crate runs
them natively, `@independo/inderun-route-core-wasm` through WASM, the Swift suite through the C interface, and the
Kotlin suite through JNI; `packages/contracts` validates every input and plan against the schemas. When planner
behaviour changes on purpose, regenerate `expected` from the planner and review the diff case by case.

The repo-level generator lives at `contracts/scripts/generate-contracts.mjs`. It emits TypeScript artifacts for
`@independo/inderun-contracts`, Swift models for `IndeRunContracts`, Kotlin models under the
`app.independo.inderun.contracts` package, and Rust types for the shared route-planner core
(`rust/inderun-route-core/src/generated/contracts.rs`, generated from the route-planner-only subset of the schemas).

`task-output.schema.json` (`TaskOutput`) and the `media-artifact.schema.json` it references are shared the same way:
`TaskResult.output` and the `completed` and `cancelled` branches of both terminal-outcome copies point at one
`TaskOutput`, so each language has one output type rather than three.

`execution-provenance.schema.json` (`ExecutionProvenance`) was the first shape shared by `$ref` rather than
duplicated by value. It is carried on six payloads — `TaskResult`, `IndeRunError`, every `StreamTerminalOutcome`
branch, and the terminal `StreamEvent` payload — and by-value copies made quicktype emit six unrelated Swift and
Kotlin types for one concept. The referencing schemas point at it with a relative `$ref`, which quicktype resolves
from the file and Ajv resolves against the shared `$id` base; `validators.ts` compiles it first so Ajv knows it.
The generator leaves it out of the Swift/Kotlin root list (it arrives through the references) and restores its
title as the type name. What provenance means is in
[`docs/architecture/architecture.md`](../docs/architecture/architecture.md#execution-provenance).

The provider capability contracts follow the same pattern. `provider-descriptor.schema.json` (`ProviderDescriptor`)
and `provider-dynamic-capabilities.schema.json` (`ProviderDynamicCapabilities`) are referenced by
`provider-capability-snapshot.schema.json` (`ProviderCapabilitySnapshot`, what `checkCapabilities()` returns) and by
`route-planner-input.schema.json`, so the planner reads exactly the shape providers declare and the snapshot
reports. Each nested object and enum carries a `title`, which is what quicktype names the generated type after.
`fixtures/provider/capability-snapshots.json` holds valid and invalid snapshots; the TypeScript validators and a
Swift decode/re-encode test both run it, the latter to prove an absent tri-state flag stays absent.

## Generated enums carry their wire value

Every generated enum exposes the schema string it serializes to, in every language: Swift as
`public enum X: String`, TypeScript as a string-literal union, Kotlin as
`enum class X(val rawValue: String)` with a `fromRawValue` companion. A Kotlin consumer reads
`Phase.ProviderSelected.rawValue` (`"provider_selected"`), never `name`.

quicktype's plain Kotlin renderer drops the value, so `generate-contracts.mjs` renders the schemas a
second time with `--framework kotlinx` — the one Kotlin renderer that keeps it — into a temp file it
reads the values back out of. That output is never shipped: it annotates every class with
`@Serializable`, which would put kotlinx.serialization on the published `:inderun-contracts` POM.
Reading the values back from quicktype rather than deriving them from the schemas keeps quicktype the
only authority on which Kotlin entry name belongs to which schema value, including keyword avoidance
(`system` becomes `RoleSystem`, because `System` is a reserved name in its Kotlin renderer).

`contracts/scripts/kotlin-enum-wire-values.mjs` holds the single table of enums whose Kotlin type or
entry names deviate from quicktype's default (`Role` becomes `MessageRole`, `The10` becomes `V1_0`).
It renames only — whether an enum carries `rawValue` is not a per-enum decision. `pnpm generate` and
`pnpm verify:enum-wire-parity` both fail when Kotlin and Swift disagree on a wire value, or when any
Kotlin enum is emitted without one (issue #212).

## Schema evolution and forward compatibility

- **Additive, backward-compatible changes** (new optional properties, a new `StreamEvent.type`
  variant) do not bump `schemaVersion` or the `$id` version segment. Every schema keeps
  `additionalProperties: true` for this reason, and `StreamEvent` specifically closes its type
  union with an open catch-all branch so a consumer built against an older revision of the schema
  does not hard-fail when a newer, additive revision introduces a new known event type.
- **Widening a discriminator** from a `const` to an `enum`, with the new value's requirements expressed as an
  `if`/`then` branch, is additive too: every existing payload stays valid, and a consumer built against the narrower
  schema rejects the new value through validation instead of misreading it. This is how new task kinds enter the
  1.0 contracts ([ADR 016](../docs/architecture/decisions/016-modality-extensible-task-contracts.md)). quicktype does
  not read `if`/`then`, so the per-value requirements live only in the validators; the generated types carry every
  branch's fields as optional properties.
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

Scoped for now to `IndeRunApi` (`run`, `stream`, and `checkCapabilities`) only. The primary text API is written
against this interface rather than declared on it, and stays outside the spec. See
[`docs/architecture/api-surface-generation.md`](../docs/architecture/api-surface-generation.md) for the research
pass, options considered, and remaining scope (`ProviderAdapter`, session operations).
