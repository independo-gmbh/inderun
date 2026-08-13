# Cross-Platform API Surface Generation — Research Pass (Issue #123)

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

## Options considered

### Option A — purpose-built spec format + 3 emitters

Hand-author a small YAML/JSON spec per interface (method name, params, return type,
async-ness, throws behavior), referencing the already-generated data types for
parameter/return shapes. Add three template emitters (TS `interface`, Swift
`protocol`, Kotlin `interface`), wired into `pnpm generate:code` alongside quicktype.

Cost: a new parser, three emitters, an async-idiom mapping table
(`Promise` / `async throws` / `suspend fun`), an error-idiom mapping table (thrown
error shapes differ per platform today), and an ongoing maintenance surface — for a
5-method surface across 2 interfaces.

### Option B — reuse JSON Schema via a non-standard `x-methods` extension

Piggyback on the existing schema files and mental model by adding a vendor extension
key. This does not reduce the actual engineering cost versus Option A: JSON Schema
has no method/async/throws vocabulary, so quicktype cannot consume the extension and
a fully custom generator is still required. The only thing this option saves is
"inventing a new file format" — it does not save any emitter or idiom-mapping work,
and it risks confusing the extension with the real (data) schema files it lives
alongside, contradicting the issue's own constraint that this must not be conflated
with the data-contract pipeline.

### Option C — lightweight parity checklist, no codegen

Maintain the comparison table above by hand (or in a small dedicated doc) and add a
lint/CI script that diffs method names and arity across the three source files
(regex or light AST parsing — no spec format, no emitters, no idiom-mapping tables)
whenever `Provider.ts`/`Provider.swift`/`Provider.kt` or
`engine.ts`/`IndeRun.swift`/`IndeRun.kt` change. This catches accidental drift
(a renamed or dropped method on one platform) without generating any code.

## Recommendation

**Adopt Option C now.** At 5 methods across 2 interfaces, the engineering cost of a
full codegen pipeline (spec format + 3 emitters + async/error idiom mapping tables +
ongoing maintenance) is disproportionate to the drift risk it prevents, and a diff
check gets most of the safety at a fraction of the cost. Building Option A now would
also mean locking in a spec format and idiom-mapping conventions before the provider
surface — and its async/error idioms — has stabilized past Milestone 2, creating
migration risk for a benefit that isn't yet needed.

**Revisit Option A** if the surface grows materially — e.g. several new
orchestrator-level methods, or a third interface beyond `ProviderAdapter`/`IndeRun`
— at which point hand-maintained parity stops scaling and the emitter investment pays
for itself. Until then, this doc plus a parity-diff check is the right size of
solution.

## Answers to the issue's open questions

- **Spec format** (JSON Schema `x-methods` extension vs. purpose-built format):
  neither is justified yet — see Option C. If Option A is revisited later, prefer a
  purpose-built format (Option B saves nothing and blurs the data/behavior boundary
  the issue itself calls out as a hard constraint).
- **Representing async/concurrency idiom differences**: not needed now. If revisited,
  a small enum (`sync` / `async` / `asyncThrows`) mapped per target language is
  sufficient — no transpiler needed since only three fixed idioms exist today.
- **Representing error/throwing behavior per platform**: not needed now. If revisited,
  piggyback on the already-normalized `IndeRunError` data contract
  (`contracts/schemas/inderun-error.schema.json`) as the thrown/rejected shape on all
  platforms, rather than inventing a separate error-idiom spec.
- **Emitting stub/skeleton implementations**: out of scope, confirmed — this pass
  found no reason to revisit that non-goal.
- **Worth the tooling investment at all**: no, not at current surface size — see
  Recommendation above. This is the primary output of this research pass.
- **Where generated files would live / merge friction with hand-written files**:
  moot for now under Option C. If Option A is revisited, follow the same convention
  as the data contracts: generated interface files marked with the
  "generated, do not edit" header, in a `generated/` subpath next to the hand-written
  concrete provider/engine classes they're implemented by, so IDEs and reviewers can
  tell the two apart at a glance.

## Trigger for revisiting

Re-open this question when either happens: (a) a third platform-parity interface is
added beyond `ProviderAdapter` and `IndeRun`, or (b) the combined method count across
existing interfaces roughly doubles (≈10+ methods). Until then, keep parity enforced
via the lightweight diff check described in Option C.
