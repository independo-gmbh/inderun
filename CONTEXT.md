---
name: entrypoint
description: entrypoint for coding agents working in this repository
---

Context for contributors' coding agents. User documentation: https://inderun.dev/docs

## 1) Project Intent (Read First)

IndeRun is an open-source (MIT) AI execution framework. It provides one unified app-facing API while routing execution across local, edge, and cloud providers.

Core product truths:

- IndeRun is an execution abstraction layer, not a model-training project.
- Policy-driven provider routing is the main differentiator.
- Cross-platform consistency and deterministic fallback behavior are critical.
- Developer experience and predictable behavior are first-class goals.

## 2) Source-of-Truth Docs

Before changing code or docs, read these files:

1. `docs/architecture/technical-brief.md`
2. `docs/architecture/architecture.md`
3. `docs/architecture/providers.md`

Treat them as the architecture baseline.

## 3) Scope Boundaries (Current Phase)

Milestone planning, scope, and status live in GitHub Issues and Milestones
(https://github.com/independo-gmbh/inderun/milestones), not in this file. Check
there for what's currently in scope before starting work — do not infer scope
from this document or assume it is up to date.

As of this writing, Mode 1 `run()` is implemented and stable, and provider
breadth (ONNX Runtime, web system-model) has landed. Mode 2 `stream()` — the
orchestrator, Event Gate, and cancellation semantics — is implemented in all
three engines (TypeScript, Swift, Kotlin), hosts expose an optional streaming
HTTP capability and an optional audio output capability, and the
OpenAI-compatible provider streams on all three platforms. Apple Foundation
Models and Android ML Kit GenAI stream on-device; the remaining local/platform
provider families (ONNX Runtime, web system-model) do not stream yet.
Text-to-speech is implemented through `speak()` / `generateSpeech()` /
`listVoices()` and the system speech providers on all three platforms (ADR 018). A neural speech provider family
(`local.onnx.speech.*`, runtime seam, fixture runtime) exists on all three SDKs; its ONNX executor and the first model
pipeline (Articulino) ship, the Apple Core AI runtime ships for iOS/macOS 27 (ADR 022, with its conversion record), and the German text frontend (numbers, dates, abbreviations before sentence splitting) ships (ADR 023; see also ADR 020, ADR 021). The three demos carry an opt-in Voices lab (#260 PR 6) that downloads
neural models from a checksummed catalog.
Mode 3 `openSession()` / realtime sessions remain unimplemented.

Out of scope now:

- Mode 4 submit/jobs infrastructure
- Durable queues/job stores/schedulers
- Full MLOps concerns

Design seams for streaming, sessions, and Mode 4 can exist in the contracts
(e.g. descriptor capability flags), but do not build or optimize implementation
around them yet.

## 4) Architecture Rules You Must Preserve

1. Keep layering clear:
   - App/API surface
   - Engine core (routing/orchestration/events)
   - Host services (platform/OS access)
   - Provider adapters (backend-specific)
2. Do not leak provider-specific behavior through public APIs when a normalized IndeRun shape exists.
3. Preserve standardized cancellation guarantees:
   - no events delivered after cancel/interrupt
   - terminal cancellation outcome
4. Keep routing deterministic and inspectable.
5. Never put raw secrets in request payloads; use secure credential references (`authContextRef` pattern).
6. Keep privacy constraints enforceable both at route selection and pre-attempt checks.

## 5) Provider Contract Expectations

Any provider integration should explicitly define:

- static descriptor (`describe`)
- dynamic capability check (`capabilities(host)`)
- supported interaction modes (`run` and `stream` are implemented; `openSession` is a
  forward-looking descriptor seam — see §3). A provider that streams opts into the
  streaming adapter type; declaring `supports.streaming` without implementing it is a
  routing-visible mistake, not a harmless one.
- what needs preparing, if anything: `readiness` in `capabilities`, and `prepare` declared per task
  through `interaction.prepare`, like streaming. IndeRun stores nothing and starts a platform's own
  download only under `autoDownload` or `allowDownload` (ADR 019).
- cancellation behavior (`hard` / `soft` / `none`)
- mapped error taxonomy and normalized telemetry

Do not bypass these contract boundaries for short-term convenience.

## 6) Repository Reality (Do Not Invent Tooling)

This repo is currently architecture-first. Only commands checked into package manifests are authoritative.

Rules:

1. Do not fabricate commands or claim tests passed if no test harness exists.
2. Prefer small, reviewable edits.
3. If you add new tooling, document exact commands in `README.md` and update this `AGENTS.md`.

Checked-in JavaScript commands:

- `pnpm install`
- `pnpm build`
- `pnpm build:wasm` — build the Rust route core to WASM (`scripts/build-route-core-wasm.mjs`);
  called automatically by `pnpm build` and `pnpm test:js`. Requires `rustup` with the
  `wasm32-unknown-unknown` target and `wasm-bindgen-cli`. The Web SDK has no fallback route
  planner, so the JS tests need these bindings to run at all.
- `pnpm check:wasm-size` — size gate for the two WASM modules (`scripts/check-wasm-size.mjs`); run after
  `pnpm build:wasm`. Prints raw and gzip bytes against the budgets in the script and exits 1 when over. Run by
  `javascript.yml` and `release.yml`. Raise a budget only in the change that grows the module.
- `pnpm build:route-core-apple` — build the Rust route core for the Apple platforms and
  package it into two XCFrameworks under `ios/IndeRun/Frameworks/`
  (`scripts/build-route-core-apple.mjs`): `InderunRouteCoreFFI.xcframework` (the planner, built
  with `--no-default-features`, linked by `IndeRunCore`) and `InderunSpeechTextFFI.xcframework`
  (the German speech text normalizer, the `speech-text` feature, linked only by
  `IndeRunNeuralSpeech`, so an app that never speaks does not carry it). Requires `rustup` with
  the five Apple targets and the Xcode command line tools. Unlike the WASM bindings, the
  XCFrameworks **are committed**: SwiftPM resolves this package from a git tag, so the tag has
  to contain the binaries. Run it and commit the result — including both regenerated
  `*.provenance.json` manifests —
  in the same change whenever the route core changes; CI fails otherwise. Pass `--force` to
  repackage unconditionally. A Cargo dependency bump counts as "the route core changes" —
  the provenance manifest hashes `Cargo.lock`. On Dependabot's cargo PRs
  `route-core-apple-refresh.yml` runs this and pushes the result; everywhere else it is a
  manual commit on the branch. See `docs/ci.md`.
- `pnpm verify:route-core-apple` — check both committed XCFrameworks against their provenance
  manifests (pinned compiler, source hashes, per-file hashes) and validate every slice's
  architectures, deployment target, exported FFI symbols (the planner framework must not export
  the normalizer), install name, and linked libraries
  (`scripts/verify-route-core-apple.mjs`). Run by `swift.yml` before anything is rebuilt and by
  `release.yml` before tagging. `--slices-only` skips the hash comparison, for validating a
  freshly rebuilt artifact whose bytes legitimately differ.
- `pnpm build:route-core-android` — cross-compile the Rust route core for the four Android
  ABIs (`scripts/build-route-core-android.mjs`). Requires `rustup` with the four Android
  targets and the Android NDK. Normally invoked by Gradle rather than by hand: `:inderun-core`
  registers the output as a generated `jniLibs` source directory, and the same script with
  `--host` builds the library the JVM unit tests load. The same script with `--speech-text` builds
  a second library, `libinderun_speech_text` (German speech text normalizer, crate feature
  `speech-text`), that `:inderun-neural-speech` packages; `libinderun_route_core` is planner-only
  (`--no-default-features --features jni-bindings`) and the script fails if either library carries
  the other's JNI symbol. Unlike the Apple XCFramework these
  binaries are **not** committed — the AAR is built by CI and published to Maven Central.
- `pnpm test` — run tests across **all** languages (JS/TS packages via `pnpm -r test`,
  Rust via `cargo test`, Kotlin via Gradle, Swift via `swift test`); requires the
  respective toolchains installed. Per-language scripts exist for scoped runs:
  `pnpm test:js` / `test:rust` / `test:kotlin` / `test:swift`. CI runs the
  language-scoped variants in each language's workflow.
- `pnpm generate` — regenerate all contract types from `contracts/schemas/` (`generate:code`)
  and then Spotless-format the generated Kotlin (`generate:kotlin`), so the committed
  `Contracts.kt` stays ktlint-clean. Requires the Android/Gradle toolchain. CI jobs that
  only need the TS/Rust output run `pnpm generate:code` (no Gradle).
- `pnpm verify:android-api-deps` — generate the Android Maven POMs and check every dependency's
  scope against `android/published-api-dependencies.txt`
  (`scripts/verify-android-api-dependencies.mjs`). Guards the defect from #189: a dependency whose
  types appear in a module's public API declared `implementation` instead of `api`, which publishes
  it in POM `runtime` scope and takes it off consumers' compile classpath. Requires the Gradle
  toolchain. Pass `--update` to re-record the baseline after an intentional change, `--no-generate`
  to reuse existing POMs. Run by `android.yml`.
- `pnpm verify:enum-wire-parity` — check the committed Kotlin and Swift contracts against each
  other: every generated Kotlin enum must expose its schema wire value as `rawValue`, and both
  languages must spell the same wire values for the same schema enum
  (`contracts/scripts/verify-enum-wire-parity.mjs`). Guards the defect from #212, where
  only the enums the generator happened to hand-patch carried their wire value. Needs no toolchain
  beyond Node. Run by `javascript.yml`, which is also where the committed Kotlin contract is
  otherwise unguarded — that workflow's regenerate-and-diff step excludes it.
- `pnpm verify:packaging` — run `publint` and `attw --pack . --profile esm-only` over the three
  published npm packages, checking that every `exports` subpath resolves the way a consumer's
  TypeScript would. Needs `pnpm build` first. Run by `javascript.yml`.
- `pnpm --filter website build|build:preview|dev|preview|check|sync:markers|check:markers|check:snippets|check:snippets:release|check:versions|update:api|check:api|check:docs|verify:seo`
  — the inderun.dev site (`website/`, Astro + Starlight); it reads the published docs from `docs/` and installs the
  published npm packages, so it needs no Rust toolchain. `build` validates internal links; `check:docs` runs after it. See
  ADR 024 and `CONTRIBUTING.md` ("Where documentation lives"). `pnpm build` and `pnpm test:js` skip it.
  `check:snippets:release` fails while any `TODO(verify)` snippet is pending; it is the precondition for a production
  deploy and is not run by CI.
- `pnpm --filter website render:og` — re-render the social preview image `website/public/og/default.jpg` from the hero
  copy, the logo and the engine list in `website/scripts/render-og-image.mjs`; commit the JPEG. Needs Chromium once:
  `pnpm --filter website exec playwright install chromium-headless-shell`. Not run by the build or CI.
- `pnpm lint`
- `pnpm format` / `pnpm format:check` — run formatting/verification across **all**
  languages (JS/TS via Prettier, Rust via `cargo fmt`, Kotlin via Spotless, Swift
  via SwiftLint); requires the respective toolchains installed. Per-language
  scripts exist for scoped runs: `pnpm format:js` / `format:rust` / `format:kotlin`
  / `format:swift` (and matching `format:check:*`). CI runs the language-scoped
  variants in each language's workflow.
- `pnpm run upgrade`
- `pnpm --filter @independo/inderun-contracts build`
- `pnpm --filter @independo/inderun-contracts test`
- `pnpm --filter @independo/inderun-demo-proxy dev`
- `pnpm --filter @independo/inderun-demo-proxy start`
- `pnpm --filter @independo/inderun-demo-proxy build`
- `pnpm --filter @independo/inderun-demo-proxy test`
- `pnpm --filter @independo/inderun-web-demo dev`
- `pnpm --filter @independo/inderun-web-demo build`
- `pnpm --filter @independo/inderun-web-demo preview`
- `pnpm --filter @independo/inderun-web-demo test`

Checked-in Swift commands:

`Package.swift` carries two consumer-compilation smoke targets, `IndeRunUmbrellaConsumerTests`
and `IndeRunProviderConsumerTests`, the Swift counterpart of `:inderun-consumer-smoke`. Each
depends on exactly one product and reaches contract/core types through that product's
`@_exported import` chain (see each target's `Exports.swift`). Do not add dependencies or imports
to either target — the single-entry dependency list is the assertion. `IndeRunTests` depends on
all six modules and therefore cannot catch a missing re-export.

- `swift build` — the SwiftPM manifest lives at the repository root (`Package.swift`)
  so the IndeRun Swift SDK is consumable by URL + git tag; sources remain under
  `ios/IndeRun/Sources`. It links the committed route-core XCFramework as a binary target,
  so this works on a plain checkout with no Rust toolchain installed.
- `swift test`
- `cd ios/IndeRun && swiftlint lint --strict` (SwiftLint config lives at `ios/IndeRun/.swiftlint.yml`)

Checked-in Android commands:

The Kotlin SDK has no fallback route planner, so the Gradle build produces the Rust route
core itself: `test` builds a host library for the unit tests (needs `rustup` and Node), and
anything that assembles an AAR cross-compiles the four Android ABIs (needs the NDK too). The
build script prints the install commands when a toolchain is missing.

- `cd android && ./gradlew build`
- `cd android && ./gradlew test`
- `cd android && ./gradlew spotlessCheck` (`spotlessApply` to auto-format)
- `cd android && ./gradlew :inderun-kotlin:connectedAndroidTest` — the real-speech corpus
  instrumented tests (`src/androidTest`), against a running emulator or connected device. Needs
  the NDK (the test APK packages the route core). CI runs it in the non-required
  `Android emulator speech` job; see `docs/ci.md`. Add
  `-Pandroid.testInstrumentationRunnerArguments.speechBenchmark=true` for the opt-in speech latency
  benchmark (`SpeechBenchmarkTest`). Further optional arguments, each prefixed
  `-Pandroid.testInstrumentationRunnerArguments.`: `speechBenchmarkModelDir` (a model package directory
  on the device; adds the neural ONNX target), `speechBenchmarkOut` (a directory on the device; one JSON
  report per target), `speechBenchmarkModelId` (the catalog entry id to record) and `speechBenchmarkSdkVersion`
  (default `dev`). `speechBenchmarkOut` is a directory name under the app's external files directory
  (`getExternalFilesDir(null)`, the only place the test app can write); it is created first and the log prints
  each report's absolute path, to fetch with `adb pull` before the test app is uninstalled. The Swift
  counterpart runs with `INDERUN_SPEECH_BENCHMARK=1 swift test --filter SpeechBenchmarkTests`, with the matching
  variables `INDERUN_SPEECH_BENCHMARK_MODEL_DIR`, `INDERUN_SPEECH_BENCHMARK_MODEL_ID`,
  `INDERUN_SPEECH_BENCHMARK_OUT` and `INDERUN_SPEECH_BENCHMARK_SDK_VERSION`. The latency scenarios are
  described in `docs/verification/system-speech.md`; the report format and how to reproduce the neural
  runs are in `docs/verification/neural-speech.md`.
- `cd android && ./gradlew publishToMavenLocal` — build the library modules' Maven
  artifacts locally (no credentials needed); Maven Central publishing is automated in CI.

Every published module declares a dependency whose types appear in its public signatures with
`api(...)`, never `implementation(...)`; `android/README.md` explains why and
`android/published-api-dependencies.txt` pins the resulting POM scopes. The unpublished
`:inderun-consumer-smoke` module compiles the README quick start against a single
`implementation(project(":inderun-kotlin"))`, so `./gradlew test` fails when an edge goes missing.
Do not add dependencies to that module — reaching them transitively is what it is testing.

Full ABI validation (binary-compatibility-validator, metalava) does not work here: both require
the standalone `org.jetbrains.kotlin.android` plugin, which AGP 9 refuses now that Kotlin support
is built in. Do not re-add BCV expecting it to work — it applies cleanly and registers no tasks.

Checked-in release commands:

- Releases are automated by semantic-release on pushes to `main` (stable) and `dev`
  (prerelease). Config: `.releaserc`; workflow: `.github/workflows/release.yml`. See
  `docs/release.md`. Do not bump versions by hand — semantic-release derives them from
  Conventional Commits and fans the version out via `scripts/set-version.mjs`.
- `feat:` is reserved for changes to the SDK itself (packages, contracts, engines, providers,
  bridges). Website work (`website/`, inderun.dev, its docs pipeline and deploy) is
  `chore(website):` — never `feat` — and so is a pull request title for it, because a squash merge
  uses the title as the commit message. Commits scoped `website` cut no release (last rule in
  `release.config.js`). See `docs/release.md`.
- When a commit carries a `BREAKING CHANGE:` footer, that footer goes **last** and the
  trailers (`Co-Authored-By`, `Claude-Session`) move above it — everything after
  `BREAKING CHANGE:` is parsed as part of the note and published verbatim in the release
  notes. Commits without one keep trailers last as usual. `.gitmessage` is the template;
  see `docs/release.md`.

The Rust toolchain is pinned in `rust-toolchain.toml`; rustup honors it automatically. Do not
restate the version in scripts or workflows — the Apple XCFramework is a committed executable
whose provenance manifest records the exact compiler, and a second copy of the version could
disagree with it.

Checked-in Rust commands:

- `cargo build -p inderun_route_core`
- `cargo test -p inderun_route_core`
- `cargo fmt -p inderun_route_core -- --check`
- `cargo clippy -p inderun_route_core --all-targets -- -D warnings`
- Manual debug builds for local iteration (they exceed the size gate; `pnpm build:wasm` is the shipped release build):
  - `RUSTC="$(rustup which rustc --toolchain stable)" rustup run stable cargo build -p inderun_route_core --target wasm32-unknown-unknown --no-default-features`
  - `wasm-bindgen target/wasm32-unknown-unknown/debug/inderun_route_core.wasm --target web --out-dir packages/inderun-route-core-wasm/generated --out-name inderun_route_core`
  - `RUSTC="$(rustup which rustc --toolchain stable)" rustup run stable cargo build -p inderun_route_core --target wasm32-unknown-unknown --no-default-features --features speech-text --target-dir target/wasm-speech-text`
  - `wasm-bindgen target/wasm-speech-text/wasm32-unknown-unknown/debug/inderun_route_core.wasm --target web --out-dir packages/inderun-route-core-wasm/generated --out-name inderun_speech_text`
- `pnpm --filter @independo/inderun-route-core-wasm test`

Checked-in Python tooling (`tools/neural-speech/`, Python 3.12 or 3.13; nothing here runs in CI, see
`tools/neural-speech/README.md`):

- `python3.13 -m venv tools/neural-speech/.venv && tools/neural-speech/.venv/bin/pip install -r tools/neural-speech/requirements.txt`
  — create the tool's environment (`onnxruntime` has no wheel for newer Pythons).
- `tools/neural-speech/.venv/bin/python -m unittest discover -s tools/neural-speech -p 'test_*.py'` — the host-math tests.
- `tools/neural-speech/.venv/bin/python tools/neural-speech/prepare_articulino_package.py --models <onnx-release-dir> --precision int8 --voice <wav>[:<id>] --out <dir>`
  — build an Articulino model package (graphs, int64-`text_mask` `text.onnx`, voices, `model-package.json`).
- `tools/neural-speech/.venv/bin/python tools/neural-speech/prepare_articulino_voice.py --models <onnx-release-dir> --precision int8 --wav <file> --out <file>.safetensors`
  — build one voice bundle.
- `tools/neural-speech/.venv/bin/python tools/neural-speech/prepare_coreai_package.py --asset <articulino.aimodel> --config <config.json> --models <onnx-release-dir> --precision int8 --voice <wav>[:<id>] --out <dir>`
  — build an Articulino Core AI model package (the exported `.aimodel`, `config.json`, voices, `model-package.json`).
- `tools/neural-speech/.venv/bin/python tools/neural-speech/build_demo_assets.py --models <onnx-release-dir> --seeds tools/neural-speech/voice-seeds --out <dir>`
  — build the Voices lab demo assets (int64-mask `text.onnx`, the seven voice bundles, `SHA256SUMS`), write their
  url/sha256/bytes into `contracts/fixtures/speech/neural-model-catalog.json` and print the `gh release create`
  command for the owner (nothing is uploaded).
- `tools/neural-speech/ios_device_bench.sh --device <udid|name> --package <package-dir> [--rounds 3] [--model-id <id>] [--sdk-version <v>] [--out <file>]` — opt-in:
  time an ONNX or Core AI Articulino package on a connected iPhone through the demo app, with a temporary hook the script reverts (a Core AI package also links `IndeRunCoreAIProviders` through a temporary `project.pbxproj` edit),
  and write the `inderun-speech-benchmark/1` JSON report (`first_call_after_prepare`, `render_speed`) to `--out`
  (needs Xcode and a paired phone; see the README).
- `tools/neural-speech/.venv/bin/python tools/neural-speech/generate_pipeline_fixture.py` — regenerate
  `contracts/fixtures/speech/articulino-pipeline.json`; the output is deterministic.

Every generated Kotlin contract enum carries `enum class X(val rawValue: String)` plus a
`fromRawValue` companion, so the schema spelling is never re-derived by hand — `name` is not the
wire value (`Phase.ProviderSelected.rawValue == "provider_selected"`). The values come from a
second, throwaway quicktype run (`--framework kotlinx`) inside the generator, because the plain
Kotlin renderer drops them; `contracts/scripts/kotlin-enum-wire-values.mjs` holds the only table of
enum/constant renames. Do not add a per-enum regex back to the generator.

The route-core data model (`rust/inderun-route-core/src/generated/contracts.rs`)
is generated by `pnpm generate` (quicktype) from
`contracts/schemas/route-planner-input.schema.json` and `route-plan.schema.json`,
the same schemas that drive the TypeScript, Kotlin, and Swift contracts. Do not
hand-edit that file; change the schema and regenerate. The rest of the crate
(`planner.rs`, `ffi.rs`, `model.rs`, `tests.rs`) is hand-written against the
generated types.

JavaScript baseline:

- Node `24.x`
- pnpm `11.9.0`

Useful discovery commands:

- `rg --files`
- `find . -maxdepth 3 -type f | sort`

## 7) How Agents Should Work Here

1. Read the three architecture docs first.
2. Restate constraints relevant to the requested task.
3. Propose/implement the smallest change that satisfies the request.
4. Document assumptions and unresolved decisions.
5. Keep changes aligned with cross-platform parity goals (TS/Web, iOS/Swift, Android/Kotlin, Capacitor bridge behavior).

## 8) Documentation Requirements

When behavior or contracts change, update docs in the same task:

- architecture semantics: `docs/architecture/architecture.md`
- public API layers, model profiles, facade mapping: `docs/architecture/api-layering.md`
- provider semantics/capabilities: `docs/architecture/providers.md`
- project framing/scope: `docs/architecture/technical-brief.md`
- CI/process behavior: `docs/ci.md`
- published user docs live in the published docs folders (`docs/index.md` and `docs/{getting-started,concepts,guides,platforms,api}/`); see ADR 024

Any change that adds a provider, changes a provider's capability check, task
support, interaction modes, cancellation behavior, or error mapping MUST update
the [Provider Matrix](docs/architecture/providers.md#provider-matrix) row for
that provider (and the family-specific doc, if one exists) in the same task.

**Where technical detail belongs.** `docs/architecture/*.md` files are for durable,
high-level information: concepts, boundaries, contracts, public type/function
names, and rationale that doesn't change with routine implementation work. They
are not the place for algorithm walkthroughs, exact control-flow/gate ordering,
buffer/threading strategy, or other detail that lives next to the code it
describes — that content drifts out of sync with the implementation almost
immediately, and belongs in code comments (doc comments on the relevant
type/function) or a package-level README instead. When writing or reviewing an
architecture doc, if a sentence would need to change every time someone edits the
function it's describing, move it into a comment at that function instead of
stating it in prose here — the doc should then just name the function and link to
its directory. See `docs/architecture/onnx-runtime-provider-family.md`'s
"Implementation detail... lives in code comments in [directory]" sections for the
pattern.

If the change is material and docs are not updated, the task is incomplete.

## 9) Definition of Done for Agent Tasks

A task is done only when:

1. The change respects architecture boundaries above.
2. Any new behavior is documented in the correct source-of-truth file.
3. Claims about validation are truthful (run commands only if they exist).
4. Risks, tradeoffs, and follow-ups are clearly listed.

## 10) If You Are Unsure

Prefer explicitness over assumptions:

- state ambiguity
- offer 1-2 concrete options with tradeoffs
- proceed with the safest architecture-consistent default

Avoid hidden assumptions that create future migration work.
