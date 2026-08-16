# Cross-Platform API Surface Generation — Research Pass (Issue #123)

**Status: MVP implemented.** The Option A recommendation below (`IndeRunApi.run` +
`.checkCapabilities`) has been built — see the [Recommendation](#recommendation) and
[Next step](#next-step) sections for details and links. The Baseline/Options/Answers
sections below remain the original research record.

## Scope

[Issue #123](https://github.com/independo-gmbh/inderun/issues/123) asked whether the
**behavioral** API surface (interface/protocol method signatures on `ProviderAdapter`
and `IndeRun`) should be generated across TypeScript, Swift, and Kotlin the same way
`contracts/schemas/*.schema.json` + quicktype already keeps **data** shapes
(`TaskRequest`, `TaskResult`, `ProviderDescriptor`, …) in sync (`pnpm generate`). The
issue was explicitly scoped as research, not implementation: "Not ready to implement
as-is." This document is that research pass and its recommendation.

## Baseline: current signatures

| Method | TypeScript | Swift | Kotlin |
|---|---|---|---|
| `ProviderAdapter.describe` | `describe(): ProviderDescriptor`<br>`packages/inderun-web/src/core/provider.ts:123` | `func describe() -> ProviderDescriptor`<br>`ios/IndeRun/Sources/IndeRunCore/Provider.swift:165` | `fun describe(): ProviderDescriptor`<br>`android/inderun-core/src/main/kotlin/.../Provider.kt:82` |
| `ProviderAdapter.capabilities` | `capabilities(host: HostServices): Promise<ProviderDynamicCapabilities>` | `func capabilities(host: HostServices) async -> ProviderDynamicCapabilities` | `suspend fun capabilities(host: HostServices): ProviderDynamicCapabilities` |
| `ProviderAdapter.run` | `run(req: TaskRequest, ctx: RunContext): Promise<TaskResult>` | `func run(request: TaskRequest, context: RunContext) async throws -> TaskResult` | `suspend fun run(request: TaskRequest, context: RunContext): TaskResult` |
| `IndeRun.run` | `packages/inderun-web/src/core/engine.ts:83`<br>`async run(request: TaskRequest): Promise<TaskResult>` | `ios/IndeRun/Sources/IndeRunSwift/IndeRun.swift:57`<br>`public func run(request: TaskRequest) async throws -> TaskResult` | `android/inderun-kotlin/src/main/kotlin/.../IndeRun.kt:51`<br>`suspend fun run(request: TaskRequest): TaskResult` |
| `IndeRun.checkCapabilities` | `engine.ts:222`<br>`async checkCapabilities(): Promise<ProviderCapabilitySnapshot[]>` | `IndeRun.swift:204`<br>`public func checkCapabilities() async -> [ProviderCapabilitySnapshot]` | `IndeRun.kt:170`<br>`suspend fun checkCapabilities(): List<ProviderCapabilitySnapshot>` |

Total surface today: **5 methods across 2 interfaces, on 3 languages**. Rust
(`rust/inderun-route-core`) has no equivalent — it only implements the deterministic
route planner, not the adapter/orchestrator layer, so it is out of scope for this
comparison.

Async idiom already diverges per language at every method: TypeScript `Promise<T>`,
Swift `async throws -> T` (or `async -> T` where nothing throws), Kotlin
`suspend fun … : T`. This divergence is a fact the generator would have to *encode*,
not something it would resolve.

## Existing tooling

The only schema-to-code generator in the repo is `contracts/scripts/generate-contracts.mjs`,
which drives quicktype per language and post-processes its output with string
replacements. There is no template engine (Handlebars/Mustache/EJS or similar)
anywhere in the codebase, and JSON Schema (and therefore quicktype) has no vocabulary
for methods, async-ness, or throwing behavior — it is a data-shape tool only. Any
method-signature generator would be new tooling built from scratch, not an extension
of the existing pipeline.

## Off-the-shelf tooling survey

Before designing a custom format, the obvious off-the-shelf service-definition
generators were checked against this problem: generating in-process TS
interfaces / Kotlin interfaces / Swift protocols with no transport assumptions.

- **[Smithy](https://smithy.io/2.0/guides/building-codegen/overview-and-concepts.html)**
  models services/operations/inputs/outputs/errors and has a real codegen
  framework, but its standard generators are client/server and transport-oriented.
  [Smithy TypeScript](https://github.com/smithy-lang/smithy-typescript) is still
  developer-preview and [Smithy Swift](https://github.com/smithy-lang/smithy-swift)
  warns its interfaces remain subject to change. Would still need custom IndeRun
  emitters.
- **[OpenAPI Generator](https://openapi-generator.tech/docs/generators/)** supports
  Kotlin, Swift 6, and several TS clients, but models an HTTP API — `Flow`,
  `AsyncStream`, cancellation handles, and host services would come out looking
  like network operations. Plausibly useful later for an actual HTTP proxy/bridge
  surface, not for this.
- **[Protobuf/gRPC](https://grpc.io/docs/languages/)** has mature Kotlin/Swift/Node
  support and strong streaming semantics, but imposes a binary RPC contract and a
  generated message ecosystem that would compete with the existing JSON contracts
  — too heavy for three in-process implementations.
- **[TypeSpec](https://github.com/microsoft/typespec)** has a pleasant compiler and
  custom-emitter framework, but no mature standard emitter for this exact
  Kotlin/Swift/TypeScript in-process combination — it would just be an alternative
  frontend for a generator this project still has to own.

**Conclusion: none fit.** Every option converges on the same result — a custom
generator is required regardless of which spec format sits underneath it. That
means the real choice isn't "off-the-shelf vs. custom," it's "is a custom generator
worth owning at all," which is what the options below weigh.

## Options considered

### Option A — small versioned API spec + purpose-built generator

A small versioned spec (e.g. `api/inderun-api.yaml`, itself validated by its own
JSON Schema) describing operations per interface — method name, input/output types
(referencing the already-generated data contracts), async-ness, and thrown-error
type:

```yaml
interfaces:
  IndeRunApi:
    operations:
      run:
        input: TaskRequest
        output: TaskResult
        async: true
        throws: IndeRunError
      checkCapabilities:
        output: { list: ProviderCapabilitySnapshot }
        async: true
```

One generator (fits naturally as a TS script, matching the existing tooling
language) with three compact emitters — TS `interface`, Kotlin `interface`, Swift
`protocol` — wired into `pnpm generate:code` as a sibling step to the quicktype
data-contract generation, not a replacement for it. Idiom mapping is small and
already fully known from the current surface: `Promise<T>` / `suspend fun … : T` /
`async throws -> T`, plus `Array<T>` / `List<T>` / `[T]`.

Scope for the initial cut, matching the current baseline: `IndeRunApi` with `run`
and `checkCapabilities` only. `ProviderAdapter` (`describe`/`capabilities`/`run`)
as a second, separate spec/interface added right after — keeping the two API
surfaces (app-facing orchestrator vs. provider plug-in contract) as distinct specs
mirrors how they're already conceptually separate in the architecture docs.

Generate only stable, cross-platform-parity-bearing surface: method
names/params/results/errors/availability. Constructors, factories, Android
`Context`, Apple availability helpers, and provider registration stay handwritten
— the generator's job is signatures, not object lifecycle.

CI enforcement (this is what makes Option A actually stronger than a manual
checklist, not just a fancier one):

1. Generate all three declarations from the spec.
2. Compile each handwritten implementation against its generated declaration —
   parity becomes a compiler-enforced fact, not a reviewer's visual check.
3. Fail CI if regenerating the output produces an uncommitted diff (spec and
   generated code drifted apart).
4. Store an API snapshot and require explicit review for breaking changes to it.
5. Add shared behavioral contract tests alongside — signatures only guarantee
   shape, not routing/error/cancellation behavior, which needs its own coverage.

**Streaming/session scope guard:** the illustrative idiom mapping for future
operations (`AsyncIterable<Event>` / `Flow<Event>` / `AsyncThrowingStream<Event,
Error>`) documents the target shape for a future streaming/session milestone, but
per CLAUDE.md §3 ("design seams... can exist in the contracts... but do not build
or optimize implementation around them yet"), the spec must **not** gain
`stream`/`openSession` operations, and the generator must **not** emit streaming
declarations, until that work is actually scoped. The spec format should not need
reworking when that happens — `async: true` already generalizes to a `stream: true`
variant later — but nothing streaming-shaped gets generated today.

### Option B — reuse JSON Schema via a non-standard `x-methods` extension

Piggyback on the existing schema files and mental model by adding a vendor
extension key. This does not reduce the actual engineering cost versus Option A:
JSON Schema has no method/async/throws vocabulary, so quicktype cannot consume the
extension and a fully custom generator is still required regardless — confirmed by
the tooling survey above, where every real generator framework needs a
purpose-built emitter layer no matter the input format. The only thing this option
saves is "inventing a new file format" — it does not save any emitter or
idiom-mapping work, and it risks confusing the extension with the real (data)
schema files it lives alongside, contradicting the issue's own constraint that this
must not be conflated with the data-contract pipeline.

### Option C — lightweight parity checklist, no codegen

Maintain the comparison table above by hand and add a lint/CI script that diffs
method names and arity across the three source files (regex or light AST parsing —
no spec format, no emitters) whenever the provider/engine files change. Catches
drift without generating code, but only checks *names and arity survived* — it
can't verify that a Kotlin `List<T>` and a Swift `[T]` still agree on `T`, and
provides no compiler-enforced guarantee the way Option A's "compile handwritten
code against generated declarations" step does.

## Recommendation

**Adopt Option A**, scoped to the MVP described above (`IndeRunApi.run` +
`.checkCapabilities` first, `ProviderAdapter` next, no streaming operations yet).

This supersedes this doc's earlier draft recommendation (Option C). The tooling
survey changes the framing: since every realistic path — off-the-shelf or custom —
ends up requiring a hand-built generator, the real question isn't "avoid building a
generator," it's whether to get compiler-enforced parity (Option A) or a
best-effort textual diff (Option C) for roughly the same amount of new code. Given
that CI-enforced parity catches a real class of bug a manual/regex check can't
(type-level drift, not just name/arity drift), and the initial spec scope is small
(2 operations to start), Option A's cost is smaller and its guarantee stronger than
this doc originally estimated.

Option B remains not recommended — it saves nothing over Option A and blurs the
data/behavior boundary the issue explicitly calls out as a hard constraint.

**Implemented.** The MVP scoped above is built: the versioned spec lives at
[`contracts/api/inderun-api.json`](../../contracts/api/inderun-api.json) and the
generator at
[`contracts/scripts/generate-api-surface.mjs`](../../contracts/scripts/generate-api-surface.mjs),
wired into `pnpm generate:code` as a sibling step to the data-contract generator. It
emits the `IndeRunApi` surface as a TS `interface`, Swift `protocol`, and Kotlin
`interface` (`packages/inderun-web/src/core/generated/inderun-api.ts`,
`ios/IndeRun/Sources/IndeRunSwift/Generated/IndeRunApi.swift`,
`android/inderun-kotlin/src/main/kotlin/app/independo/inderun/sdk/generated/IndeRunApi.kt`),
and the hand-written `IndeRun` class now implements/conforms to it on all three
platforms, with CI failing on regeneration drift.

## Answers to the issue's open questions

- **Spec format**: a small versioned, self-schema-validated YAML/JSON spec
  (Option A), not a JSON Schema extension (Option B saves nothing per the tooling
  survey).
- **Representing async/concurrency idiom differences**: an `async: true` boolean
  (with room to grow a `stream: true` variant later, unbuilt for now) mapped to
  `Promise` / `suspend fun` / `async throws` per target language — no transpiler
  needed, only three fixed idioms exist today.
- **Representing error/throwing behavior per platform**: a `throws: <TypeName>`
  field referencing the already-normalized `IndeRunError` data contract
  (`contracts/schemas/inderun-error.schema.json`) as the thrown/rejected shape on
  all platforms, rather than inventing a separate error-idiom spec.
- **Emitting stub/skeleton implementations**: still out of scope, confirmed — only
  signatures are generated; constructors, factories, platform setup, and provider
  registration stay handwritten.
- **Worth the tooling investment at all**: yes, scoped to the MVP above — see
  Recommendation. The deciding factor is CI-enforceable parity (compile-check +
  regen-diff), not developer convenience.
- **Where generated files would live / merge friction with hand-written files**:
  follow the same convention as the data contracts — generated interface files
  carry the "generated, do not edit" header and live in a `generated/` subpath
  next to the hand-written concrete provider/engine classes that implement/conform
  to them, so IDEs and reviewers can tell the two apart at a glance.

## Known limitation: payload-shape parity is not enforced

This generator enforces cross-language parity for `IndeRunApi` *operation
signatures* — method name, params, return type, and async idiom — across
TypeScript, Kotlin, and Swift. It does **not** enforce that the payload types
those signatures reference stay in sync across languages. `TaskRequest` and
`TaskResult` already get that guarantee independently via the JSON-Schema/
quicktype contract pipeline (`pnpm generate` / `contracts/schemas/*.schema.json`).
`ProviderCapabilitySnapshot` (and its nested `ProviderDescriptor`/
`ProviderDynamicCapabilities` types) does not: it is handwritten separately in
TypeScript (`packages/inderun-web/src/core/provider.ts`), Kotlin
(`android/inderun-core/src/main/kotlin/app/independo/inderun/core/Provider.kt`),
and Swift (`ios/IndeRun/Sources/IndeRunCore/Provider.swift`), so one language's
`ProviderCapabilitySnapshot` could gain, lose, or rename a field and every
generated `IndeRunApi` interface would still compile — the generator only
checks that `checkCapabilities()`'s signature matches, not that the type it
returns has matching shape. Migrating `ProviderCapabilitySnapshot` under the
same JSON-Schema/quicktype discipline as `TaskRequest`/`TaskResult` is a
natural next step, alongside `ProviderAdapter` generation.

## Next step

The Option A MVP (spec schema + generator + 3 emitters + CI wiring), scoped to
`IndeRunApi.run` + `.checkCapabilities`, is implemented — see
[`contracts/api/inderun-api.json`](../../contracts/api/inderun-api.json) and
[`contracts/scripts/generate-api-surface.mjs`](../../contracts/scripts/generate-api-surface.mjs).

Remaining, explicitly deferred (not yet built, per CLAUDE.md §3 scope):

- `ProviderAdapter` (`describe`/`capabilities`/`run`) as a second, separate
  spec/interface, mirroring how it's already conceptually separate from
  `IndeRunApi` in the architecture docs.
- Streaming/session operations (`stream`/`openSession`) — the spec format is
  expected to extend to a `stream: true` variant without rework, but no
  streaming declarations are generated until that work is actually scoped.
