# CI

IndeRun uses split GitHub Actions workflows so each ecosystem reports its own status check.

## Workflows

Each workflow lives in `.github/workflows/` — treat those files as the source of
truth for exact steps. This table describes only what each one covers.

- `JavaScript` (`javascript.yml`): builds and tests the pnpm packages, regenerating the shared contract and Rust→WASM artifacts first.
- `Rust` (`rust.yml`): builds and tests the `inderun_route_core` crate.
- `Swift` (`swift.yml`): builds and tests the iOS/SwiftPM package.
- `Android` (`android.yml`): builds and tests the Gradle modules, including the route core's four Android ABIs. A second job, `Android emulator speech`, runs the real-speech corpus on an emulator; see "Real speech on an emulator" below.
- The Capacitor bridge (`@independo/capacitor-inderun`) now lives in its own repository, [independo-gmbh/capacitor-inderun](https://github.com/independo-gmbh/capacitor-inderun), which runs its own web/iOS/Android CI there.
- `Release` (`release.yml`): on pushes to `main`/`dev`, runs `pnpm generate` first so the schema-derived Kotlin contract stays Spotless-formatted, then builds the workspace (incl. the Rust→WASM artifacts) and runs semantic-release to version, changelog, tag, and publish the npm packages. See `docs/release.md`.
- `Route core (Apple) refresh` (`route-core-apple-refresh.yml`): on a failed `Swift` run for a `dependabot/cargo/**` branch, rebuilds the committed XCFrameworks and pushes it onto the PR. See "Rebuilding the XCFramework for Dependabot" below.
- `Maven Publish` (`maven-publish.yml`): on a published GitHub release — prereleases included — publishes the Android library modules to Maven Central. The version comes from the tag (passed as `-PinderunVersion`), not from `android/gradle.properties`, because semantic-release only commits the version bump on stable releases. Prereleases are published because the Capacitor bridge consumes these artifacts from Maven Central and would otherwise have no `-dev.N` line to develop against, unlike npm and SwiftPM. `workflow_dispatch` takes optional `ref` and `version` inputs for a manual re-run.
- `CodeQL` (`codeql.yml`): runs GitHub code scanning (advanced setup) across `swift`, `java-kotlin`, `rust`, `javascript-typescript`, and `actions`. The compiled languages use explicit `build-mode: manual` steps — `swift build` from the repository root (the SwiftPM manifest is `Package.swift` at the root; sources under `ios/IndeRun`) and `./gradlew assembleDebug` in `android` (with JDK 21, Node, the Rust toolchain, and the Android SDK/NDK provisioned) — so the autobuilder can't misdetect one of the demo/sample apps. `rust`, `javascript-typescript`, and `actions` use `build-mode: none`. `pull_request` trigger is `main`-only; `dev` is covered by the weekly schedule instead (see Code Scanning below). `workflow_dispatch` starts a run on demand.

## Code Scanning

Code scanning uses **advanced setup** — the committed `codeql.yml` workflow is the source
of truth, not GitHub's default (UI-managed) setup. The two conflict, so **default setup
must be set to "Not configured"** under Settings → Code security → Code scanning; otherwise
the CodeQL runs fail.

The compiled languages use explicit manual builds so the autobuilder can't lock onto a
demo/sample app: Swift builds the SwiftPM package (`swift build` from the repository root)
rather than the `ios/SampleApps/IndeRunDemo` Xcode project, and Android runs
`./gradlew assembleDebug` across all modules rather than guessing a variant/target. Both scan
the product code, not the sample apps.

**`java-kotlin` must stay `build-mode: manual`.** Buildless extraction (`build-mode: none`)
covers Java only, and this repository's Android source is Kotlin — a buildless run finds nothing
and fails at database finalize with "CodeQL could not process any code written in Java/Kotlin".
Kotlin extraction happens through the compiler, so the scan needs a real build.

That build is why this job carries Node and the Rust toolchain alongside JDK 21 and the Android
SDK/NDK: `assembleDebug` reaches `:inderun-core:buildRouteCoreAndroid`, which shells out to
`scripts/build-route-core-android.mjs`. Omitting them broke the scan for three weeks once the
route core moved into the Gradle build (#204) — the cross-compile failed with `can't find crate
for core`, because the Android rustup targets were never installed, and took the whole analysis
down with it.

`dtolnay/rust-toolchain` alone is not enough, here or in `android.yml`: it installs rustup with
`--default-toolchain none`, so nothing from `rust-toolchain.toml` exists yet — including its ten
`targets`. Both workflows follow it with an explicit `rustup toolchain install --no-self-update`,
argument-free so the version still comes only from the toolchain file. Dropping that step
reproduces the same `can't find crate for core` failure with rustup apparently present.

CodeQL's `pull_request` trigger only targets `main` — every PR into `main` gets full
analysis. `dev` is not PR-gated by CodeQL; it relies on the weekly `schedule` run
(`cron: "27 3 * * 1"`), which scans the repository's default branch (`dev`). This
trades slightly staler dev coverage (up to a week) for not running five CodeQL matrix
jobs on every dev-targeted PR. Because of this, `dev` branch protection must **not**
require the `Analyze (*)` contexts — see Branch Protection below. A change to
`codeql.yml` itself is therefore not exercised by a PR into `dev`; after merging one, start
a run with `gh workflow run codeql.yml --ref dev` rather than waiting for the schedule.

**SwiftPM dependencies are filtered out of the Swift results.** `paths-ignore` does not
apply to Swift: the extractor follows the compiler, so every file `swift build` compiles is
analyzed, including the checkouts under `.build/`. The Swift job therefore analyzes without
uploading, drops results located under `.build/` from the SARIF with `jq`, and uploads the
rest under the same category. Findings in dependencies are not reported anywhere as a
result, and Dependabot does not update them either: its `swift` run fails because its proxy
blocks the `download.onnxruntime.ai` binary targets (`egress not allowlisted`). Until that
changes, `Package.resolved` only moves when someone runs `swift package update` by hand.

## Branch Protection

`main` requires these status checks before merging:

- `JavaScript`
- `Rust`
- `Swift`
- `Android`
- `Analyze (actions)`, `Analyze (javascript-typescript)`, `Analyze (rust)`, `Analyze (java-kotlin)`, `Analyze (swift)` (from `CodeQL`)

`dev` requires only `JavaScript`, `Rust`, `Swift`, `Android` — not the `Analyze (*)`
contexts, since `codeql.yml`'s `pull_request` trigger is `main`-only (see Code
Scanning above). Requiring them on `dev` would leave every dev-targeted PR stuck
`Pending` forever, since the check would never be produced.

`JavaScript`, `Rust`, `Swift`, and `Android` each start with a cheap `changes` job
(`dorny/paths-filter`) that gates the real job with `if:`. A PR that doesn't touch a
given ecosystem still gets a `skipped` (not `pending`) conclusion for that check, so
required-status-check evaluation always resolves — see path filters below.

## Path-based job gating

To avoid running, e.g., the Android build for a docs-only or web-only PR, each of
`javascript.yml`/`android.yml`/`rust.yml`/`swift.yml` runs a `changes` job first and
skips the real job via `needs`/`if` when nothing relevant changed:

- `javascript.yml`: `packages/**`, `contracts/**`, `rust/inderun-route-core/**`, `Cargo.toml`, `Cargo.lock`, `scripts/build-route-core-wasm.mjs` (all of these feed the WASM bindings, and the Web SDK has no fallback planner — a dependency-only change can alter the compiled route core and therefore Web routing), `pnpm-lock.yaml`, `pnpm-workspace.yaml`, `package.json`
- `android.yml`: `android/**`, `rust/**`, `Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml`, `scripts/build-route-core-android.mjs`, `scripts/rust-toolchain.mjs` (the Kotlin SDK loads the compiled route core and has no fallback planner, so anything that can change the core changes Android routing), and `contracts/fixtures/speech/**` (the emulator job's corpus)
- `rust.yml`: `rust/**`, `Cargo.toml`, `Cargo.lock`
- `swift.yml`: `ios/**`, `Package.swift`, `rust/**`, `Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml`, and the four route-core scripts under `scripts/` (the Swift SDK links the compiled route core and has no fallback planner, so anything that can change the core changes iOS routing — and anything that can change the core's _provenance checks_ has to re-run them), and `contracts/fixtures/speech/**` (the real-speech corpus tests read it)

Each filter also includes the workflow's own file, so editing a workflow always
re-runs it. This is deliberately done as an in-workflow `changes` job rather than a
top-level `on.pull_request.paths:` filter — GitHub can leave a required check stuck
`Pending` forever if the whole workflow is skipped by trigger-level path filtering.
`codeql.yml` is not path-gated within `main` PRs; it always runs there (see Code
Scanning above for why it's excluded from `dev` PRs instead of path-gated).

## Real speech on an emulator

The `Android emulator speech` job in `android.yml` runs
`./gradlew :inderun-kotlin:connectedDebugAndroidTest` inside
`ReactiveCircus/android-emulator-runner` (API 36, `google_apis`, x86_64, with KVM). The
instrumented tests in `android/inderun-kotlin/src/androidTest` drive the real `TextToSpeech`
through the shipping provider and the real engine, over the shared corpus in
`contracts/fixtures/speech/utterance-corpus.json` (packaged as a test asset). They are the
Android counterpart of `AppleSystemSpeechCorpusTests`, which `swift test` and the simulator step
in `swift.yml` already run against the real `AVSpeechSynthesizer`.

The same test APK runs the audio output catalog (`contracts/fixtures/host/audio-output-lifecycle.json`)
against the real `AudioTrack` default (`AudioTrackAudioOutputConformanceTest`). The stop and
refusal cases do not depend on the playback head and run everywhere. The cases that wait for audio
to play run only where a probe sees the head advance and skip otherwise, as they may under the
job's `-noaudio` emulator; on a real device they run. Every wait in it is bounded, so a silent
audio HAL skips or fails a case rather than hanging the job.

- A locale with no installed on-device voice is skipped by utterance id, never counted as a pass.
  A fresh `google_apis` image usually has English voices only, so German entries may skip there.
- The job uploads the `IndeRunCorpus` logcat lines (`INDERUN-TRACE …`: ids and measurements,
  never utterance text), the `IndeRunAudioOutput` lines (the probe outcome and any catalog
  failures) and the test report as the `android-speech-corpus` artifact.
- It is **not** a required check: emulator boots and the image's TTS engine are less predictable
  than the JVM suites. Add it to branch protection once it has been stable for a while.
- The test APK packages the route core's native libraries, so the job installs the NDK like the
  `Android` job does.
- The latency benchmark in the same test APK (`SpeechBenchmarkTest`) is opt-in and does not run
  here; only its guard test does. See
  [docs/verification/system-speech.md](./verification/system-speech.md#latency-scenarios).

Locally: start an emulator or connect a device, then run
`cd android && ./gradlew :inderun-kotlin:connectedAndroidTest`, which runs both the speech corpus
and the audio output catalog, and read their logs with
`adb logcat -d -s IndeRunCorpus:I IndeRunAudioOutput:I`.

The neural speech runtime has its own real-model test, `OnnxNeuralSpeechRealModelTest`, in the same
test APK. It runs the Articulino graphs through ONNX Runtime and **skips unless** the
`neuralSpeechModelDir` instrumentation argument is passed, so the CI job above never runs it. To run
it locally, push a package written by `tools/neural-speech/prepare_articulino_package.py` to the
device and pass its path:

```bash
adb push <package-dir> /data/local/tmp/articulino
cd android && ./gradlew :inderun-kotlin:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=app.independo.inderun.sdk.OnnxNeuralSpeechRealModelTest \
  -Pandroid.testInstrumentationRunnerArguments.neuralSpeechModelDir=/data/local/tmp/articulino
adb logcat -d -s IndeRunNeuralSpeech
```

The log line carries the ABI, the audio length and the wall time.

## Core AI module

`IndeRunCoreAIProviders` compiles to a stub on any Xcode whose SDK has no `CoreAI` framework (it first ships in the
macOS 27 SDK), so the ordinary `swift test` pass and the simulator step never type-check the real path. The step
`Build the Core AI module with the newest Xcode` in `swift.yml` selects the newest `/Applications/Xcode*.app` with a
step-scoped `DEVELOPER_DIR` (not `xcode-select -s`, which would switch every later step) and runs
`swift build --target IndeRunCoreAIProviders --scratch-path .build-coreai`, so the build does not share `.build` with
the other toolchain. It then runs `swift build --target IndeRunTests` in the same scratch path, which also type-checks
the Core AI test files against the real framework (SwiftPM refuses `--build-tests` together with `--target`).

The step is `continue-on-error: true`. Until `macos-latest` ships Xcode 27 it only builds the stub, and a newer
toolchain may fail for reasons unrelated to this module. Make it blocking (drop `continue-on-error`) once `macos-latest`
has Xcode 27 and the step's `xcodebuild -version` output shows it building the real path.

The gated tests that run a real model are not in CI. Locally, on macOS 27 with Xcode 27:

```bash
INDERUN_COREAI_MODEL_DIR=<dir written by tools/neural-speech/prepare_coreai_package.py> swift test --filter CoreAI
```

Without the variable (or below macOS 27) they skip. See [ADR 022](./architecture/decisions/022-core-ai-runtime.md).

## Pinned actions

Third-party actions (everything except `dtolnay/rust-toolchain`) are pinned to a full
commit SHA with the human-readable version in a trailing comment, e.g.:

```yaml
uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
```

Dependabot's `github-actions` ecosystem entry in `dependabot.yml` keeps these current —
it updates both the SHA and the version comment together. `dtolnay/rust-toolchain@stable`
is the one intentional exception: it tracks whatever Rust's current stable release is,
which is the point of using it, so pinning it to a SHA would defeat the purpose.

## Rebuilding the XCFramework for Dependabot

Every Cargo bump makes the committed `InderunRouteCoreFFI.xcframework` and `InderunSpeechTextFFI.xcframework` stale,
because each provenance manifest hashes `Cargo.lock` and the binary in git was linked against the previous dependency
set. That is a real failure, not a false alarm — but Dependabot cannot produce a macOS artifact, so without help every
cargo PR lands red and waits for someone to run `pnpm build:route-core-apple` locally.

`route-core-apple-refresh.yml` makes that commit instead. Three things about it are load-bearing:

- **It triggers on `workflow_run`, not `pull_request`.** Runs triggered by Dependabot get a
  read-only `GITHUB_TOKEN` and no Actions secrets, so they cannot push. A `workflow_run` run
  executes in the base repository with the normal token and secrets. That privilege is also why
  the job is gated on the head being a `dependabot/cargo/**` branch _in this repository_ —
  never a fork.
- **The provenance check decides whether it acts.** A `Swift` failure can have nothing to do
  with the artifact, and rewriting a committed executable needs a reason. It is also what keeps
  the workflow from looping: Rust builds are not byte-reproducible, so an unconditional rebuild
  would push a new commit on every run indefinitely.
- **The token is scoped to the push step.** Checkout runs with `persist-credentials: false`, so
  the bumped crates' build scripts compile with no credential in `.git/config` or in the
  environment. `GH_TOKEN` (the same PAT/App token `release.yml` uses) is what makes the pushed
  commit re-run the Swift check; the `GITHUB_TOKEN` fallback still fixes the branch, but pushes
  made with it do not start workflow runs, so the check has to be re-run by hand.

Two consequences worth knowing: `workflow_run` workflows are read from the default branch, so
changes to this file only take effect once merged to `main`; and because the workflow pushes to
Dependabot's branch, Dependabot stops rebasing that PR afterwards.

## Dependabot major-version bumps

Dependabot groups minor/patch updates per ecosystem, but major-version bumps land as
individual, ungrouped PRs and are **not auto-mergeable** — they need manual triage:

- Tightly coupled peer packages (e.g. `vite` + `vitest`) can each break CI on their own
  when bumped independently, because Dependabot doesn't know about the peer coupling.
  These typically need to be bumped together in one manual commit on the PR branch (or
  closed in favor of a combined bump), not merged as-is.
- A major version can drop/rename CLI flags or change generated output (e.g. `quicktype`
  dropping the Kotlin `just-types` framework in v26), which is a real migration, not a
  CI fix — treat these as their own follow-up task rather than force-merging.
- Android dependency majors (e.g. `androidx.core`) can raise the minimum `compileSdk`
  they build against — bump `compileSdk` in the relevant `android/*/build.gradle.kts`
  modules and, if Robolectric doesn't support the new API level yet, pin
  `sdk=<supported-level>` in that module's `src/test/resources/robolectric.properties`
  (this decouples the Robolectric test SDK from `compileSdk`).

## Public-API packaging checks

Three checks, one per SDK, guard the same defect: a type in a public signature coming from a
dependency the consumer does not actually get. See
[#189](https://github.com/independo-gmbh/inderun/issues/189) for how it went unnoticed — it is
invisible inside this repository and only breaks for someone consuming the published artifacts.

- **Android**, in `android.yml`: `node scripts/verify-android-api-dependencies.mjs` generates the
  Maven POMs and compares every dependency's scope against `android/published-api-dependencies.txt`.
  A dependency slipping from `api(...)` back to `implementation(...)` shows up as `compile` →
  `runtime` and fails the job. Regenerate the baseline with `--update` after an intentional change.
  Additionally, the `inderun-consumer-smoke` module compiles the README quick start against a single
  `implementation(project(":inderun-kotlin"))`, so `./gradlew test` alone catches a missing edge.
  The baseline is what makes an intentional scope change explicit: demoting a dependency that
  nothing publicly exposes is a legitimate edit, and it has to be re-recorded and reviewed rather
  than slipping through.
- **Swift**, in `swift.yml`: two things, guarding two different failures.

  The re-export boundary is guarded by the `IndeRunUmbrellaConsumerTests` and
  `IndeRunProviderConsumerTests` targets in `Package.swift`, which are the direct counterpart of
  `inderun-consumer-smoke`. Each depends on exactly one product — `IndeRunSwift` and
  `IndeRunOpenAIProviders` respectively — and names contract and core types through it, so
  weakening an `@_exported import` fails `swift test`. `IndeRunTests` cannot catch this: it
  depends on all six modules directly, which is what hid the problem in the first place.

  Separately, `swift package diagnose-api-breaking-changes` runs against the PR's base branch,
  scoped to `IndeRunContracts`. That is an ABI check on the generated contract surface, not a
  packaging check — it would stay green through a re-export regression, since removing
  `@_exported` changes no declaration in `IndeRunContracts`. The scope is a tool limitation:
  swift-api-digester cannot build a baseline for any target depending on the `InderunRouteCoreFFI`
  binary target, which is every other module. Runs on pull requests only, and needs the job's
  `fetch-depth: 0` checkout to resolve the baseline.

  It is **advisory on a release PR and blocking everywhere else**. The baseline is the PR's base:
  against `dev` that is the branch's own increment, which is where an unintended break should fail
  review. Against `main` it is everything since the last stable release, which for a pre-1.0
  project that takes breaking changes as minor bumps (`release.config.js`) is intentional by
  definition — v0.3.0 reported 44. A blocking gate there would stop exactly the releases it exists
  to describe (#206), so the step keeps running and keeps printing: its output is the
  authoritative breaking-change list for the release notes, and it catches breaks whose commits
  forgot the `BREAKING CHANGE:` footer. For the same reason it is advisory on a `dev` PR whose
  commits announce the break themselves (a `type!:` subject or a `BREAKING CHANGE:` footer, the
  markers semantic-release reads): the break is intended and already headed for the release notes.
  A PR that changes the surface without announcing it still fails. One announced break makes the
  whole PR's report advisory, so read the report when reviewing such a PR.
- **Contract enums**, in `javascript.yml`: `pnpm verify:enum-wire-parity`
  (`contracts/scripts/verify-enum-wire-parity.mjs`) reads the committed Kotlin and Swift
  contracts and asserts that every generated Kotlin enum exposes its schema wire value as
  `rawValue`, and that both languages spell the same wire values for the same schema enum.
  The generator asserts the same thing on the sources it writes; this step covers what the
  generator cannot see, a hand-edit of the committed Kotlin file — which the diff guard below
  deliberately excludes. Its two files are in the workflow's path filter for that reason.
- **Web**, in `javascript.yml`: `pnpm verify:packaging` runs `publint` and
  `attw --pack . --profile esm-only` over the three published npm packages, resolving every
  `exports` subpath the way a consumer's TypeScript would. The `esm-only` profile drops the node10
  and CommonJS-consumer resolutions, which these ESM-only packages would always report.

A full ABI dump on Android (binary-compatibility-validator, metalava) is **not** possible today:
both hook the `KotlinAndroidTarget` registered by the standalone `org.jetbrains.kotlin.android`
plugin, and AGP 9 refuses that plugin now that Kotlin support is built in. BCV applies without
error and then registers no tasks at all. Revisit when either tool supports AGP's built-in Kotlin.

## Notes

- The JavaScript workflow also regenerates the shared contract and WASM artifacts before package builds.
- `pnpm generate` emits the contract types for every language from `contracts/schemas/`: TypeScript, Kotlin, and Swift for the full surface, plus the Rust route-core model (`rust/inderun-route-core/src/generated/contracts.rs`) from the two route schemas. The generated Rust file is committed and normalized with `rustfmt` so `cargo fmt --check` stays green.
- Both `javascript.yml` and `release.yml` follow their "Generate contracts" step with a
  "Verify generated contracts and API surface are up to date" step that runs
  `git diff --exit-code` over the generated-output directories, failing the build if
  regenerating produced an uncommitted diff (i.e. someone edited a generated file by hand,
  or forgot to run the generator after a schema/spec change). The two workflows check a
  slightly different set of paths: `javascript.yml` runs `pnpm generate:code` (no Gradle
  toolchain) and deliberately excludes `android/inderun-contracts/src/main/kotlin` from its
  diff, because that step skips the `generate:kotlin` Spotless pass and would otherwise
  always report spurious formatting drift; `release.yml` runs the full `pnpm generate`
  (Spotless included) and includes that path, since its output is guaranteed
  ktlint-clean. `pnpm verify:enum-wire-parity` covers the content of the file
  `javascript.yml` leaves out of that diff (see the verification steps above).
- `pnpm build:wasm` (`scripts/build-route-core-wasm.mjs`) is the single definition of the
  Rust→WASM build: it runs `cargo build --target wasm32-unknown-unknown` plus
  `wasm-bindgen --target web`. Freshness is left to cargo, which fingerprints every effective
  input (sources, workspace manifest, lockfile, rustc version); only the wasm-bindgen step is
  skipped, and only when the existing bindings are newer than the `.wasm` cargo just produced.
  It builds two artifacts per run: the planner (`--no-default-features`, `inderun_route_core.*`) and
  the German speech text module (`--features speech-text`, `inderun_speech_text.*`, its own cargo
  target directory), so routing-only apps do not download the speech module's regex engine.
  A hand-rolled mtime check over crate sources alone would serve stale bindings after a
  dependency bump. Both `pnpm build` and `pnpm test:js` call it, and `javascript.yml`/`release.yml`
  run it as an explicit step so a missing toolchain fails visibly. Since the Web SDK has no
  fallback planner, the JS suite genuinely needs those bindings — hence building
  them is part of `pnpm test:js` rather than a prerequisite contributors are expected to
  remember. Running the JS tests locally therefore requires `rustup` with the
  `wasm32-unknown-unknown` target and `wasm-bindgen-cli` (the script prints the install
  commands when either is missing). The CLI's version is not a free choice: it shares a schema
  version with the `wasm-bindgen` crate and rejects a `.wasm` built by one it does not match.
  `scripts/wasm-bindgen-version.mjs` reads that version out of `Cargo.lock` and is what the
  install hint, both workflows' `cargo install` step, and their cache key use, so a Dependabot
  cargo bump cannot leave the CLI pin behind (#192).
- `pnpm build:route-core-apple` (`scripts/build-route-core-apple.mjs`) is the equivalent for the
  Apple platforms: it cross-compiles the route core for iOS device, iOS simulator, and macOS,
  and packages the results into two XCFrameworks under `ios/IndeRun/Frameworks/`: `InderunRouteCoreFFI.xcframework` (the planner, `--no-default-features`) and `InderunSpeechTextFFI.xcframework` (the German speech text normalizer, `--no-default-features --features speech-text`, built in its own cargo target directory). They are separate so an app that never uses neural speech does not carry the normalizer.
  Freshness is delegated to cargo for the same reason as the WASM build; only the packaging
  step is skipped, and `--force` disables even that. Unlike the WASM bindings that XCFramework
  **is committed** — SwiftPM has no publish step, so consumers get whatever the git tag
  contains, and an artifact injected at release time would leave every prerelease tag
  unbuildable. The libraries are dynamic (`cdylib` in framework bundles), not static: a
  `staticlib` archive eliminates nothing until the consumer links, so it weighs ~17 MB per
  slice against ~400 KB for the same code as a dynamic library — the difference between 87 MB
  and 2 MB of binary rewritten in git on every planner change. The `apple` cargo profile in the
  workspace `Cargo.toml` is what buys that, together with a `strip -x` the packaging step runs
  with the Xcode tools: the profile itself does not strip, because rustc's own strip step yields
  dylibs that the Xcode 27 linker rejects (`mis-aligned LINKEDIT string pool`).
- `pnpm build:route-core-android` (`scripts/build-route-core-android.mjs`) builds the same core
  for Android, in two modes. Without arguments it cross-compiles the four ABIs
  (`arm64-v8a`, `armeabi-v7a`, `x86_64`, `x86`) using the NDK's per-API-level clang wrappers as
  linkers; `--host` builds one library for the machine running the build. Gradle drives both:
  `:inderun-core` registers the ABI build as a _generated_ `jniLibs` source directory via AGP's
  `addGeneratedSourceDirectory`, so only the variants that package native code pull it in and
  `./gradlew test` needs neither the NDK nor the Android Rust targets; the root
  `build.gradle.kts` puts the host build on `java.library.path` for `:inderun-core` and
  `:inderun-kotlin`'s unit tests. Those tests reach the planner through the same
  `System.loadLibrary` call the Android runtime makes, so the JNI boundary itself is under test
  rather than only the two halves of the wire format.
  - `--speech-text` builds a second library from the same crate, `libinderun_speech_text` (`--no-default-features
    --features speech-text,jni-bindings`, its own cargo target directory, soname/install name set to its own file name),
    packaged by `:inderun-neural-speech` the same way; `libinderun_route_core` is built planner-only so apps that do not
    use neural speech do not carry the normalizer. The script checks that the planner library lacks the speech JNI
    symbol and that the speech library has it. The host build of the speech library goes on `java.library.path` for
    `:inderun-neural-speech` and `:inderun-onnx-providers`.
  - These binaries are **not** committed, unlike the Apple XCFramework. Android consumers
    resolve `app.independo.inderun:inderun-core` from Maven Central, where `maven-publish.yml`
    builds the AAR — there is no equivalent of SwiftPM's "the git tag is the artifact", so
    tracking ~2 MB of `.so` files per planner change would buy nothing. That workflow therefore
    provisions Node and the Rust toolchain alongside the NDK it already had.
  - The JNI entry point is behind the crate's `jni-bindings` feature rather than a
    `cfg(target_os = "android")` gate. With a target gate the symbol exists only in the Android
    build and no JVM test can reach the real planner; `src/lib.rs` makes an Android build
    _without_ the feature a `compile_error!`, so the seam cannot be missed in the direction
    that matters.
  - `android.yml` runs `assembleRelease` after `test`, because `test` never reaches the ABI
    cross-compiles — without it the four Android slices would first be built at publish time.
- **Verifying the committed XCFramework.** It is an executable in git: it is what SwiftPM
  consumers run, and reviewing the Rust source says nothing about whether that binary came from
  it. Rust builds are not byte-reproducible, so rebuild-and-diff cannot answer the question.
  Two mechanisms answer it together:
  - `ios/IndeRun/Frameworks/InderunRouteCoreFFI.provenance.json` and `InderunSpeechTextFFI.provenance.json`, written by the build script,
    records the pinned compiler plus SHA-256 hashes of every source the artifact was built from
    (crate sources and manifest, workspace manifest, lockfile, toolchain pin, the packaged C
    header, and the build scripts themselves) and of every file inside the XCFramework.
    `pnpm verify:route-core-apple` (`scripts/verify-route-core-apple.mjs`) recomputes all of it
    and additionally checks each slice with `lipo`/`otool`/`nm`/`plutil`: architectures, Mach-O
    platform, deployment target, each framework's exported FFI symbols (planner: `_inderun_plan_route_json`, `_inderun_free_string`; speech text: `_inderun_normalize_speech_text`, `_inderun_speech_text_free`, with the planner framework asserted _not_ to export the normalizer), the `@rpath` install name, and
    that nothing beyond `libSystem` is linked. It runs in `swift.yml` **before** anything is
    rebuilt, so the committed artifact is what is under test, and `release.yml` gates the
    release job on it — the tag is the Swift distribution channel, and nothing downstream
    re-checks it.
  - `swift.yml` then rebuilds from source with `--force` and runs the Swift suite a second time
    against the result, which is the behavioural half: the committed binary and a fresh build of
    the reviewed source must both satisfy the same tests. `swift test` only exercises the macOS
    slice, so the job also runs the suite on an iOS simulator and builds `ios/SampleApps/IndeRunDemo`
    for a generic iOS device, which links and embeds the device slice.
  - Because hashes cover `Cargo.lock`, a Cargo dependency bump fails verification until the
    XCFramework is rebuilt: a lockfile change can alter the compiled core, so such a PR needs a
    `pnpm build:route-core-apple` commit on top. On Dependabot's cargo PRs that commit is made
    by `route-core-apple-refresh.yml` (see below); anywhere else it is the author's to make.
    `Cargo.lock` is committed for this reason —
    the stock "libraries don't commit lockfiles" advice assumes consumers resolve their own
    versions, but this workspace ships a compiled binary and publishes compiled WASM, so the
    versions that went into those artifacts have to be recorded. The manifest generator refuses
    to hash an input git does not track, since such an entry would describe a file only the
    build machine has.
- The Rust toolchain is pinned in `rust-toolchain.toml` rather than tracking `stable`, because
  the XCFramework is a committed executable and "whatever stable was that day" is not something
  a reviewer can check an artifact against. The workflows use the toolchain action only to
  provide rustup and must not restate the version — a second copy could disagree with the
  compiler that actually built the artifact. Every job that needs the pin then runs
  `rustup toolchain install --no-self-update`, with no toolchain argument so the version still
  comes from the file alone. That step is required, not belt-and-braces: rustup installs the
  toolchain a `rust-toolchain.toml` selects, but _not_ one named explicitly on the command
  line, and `scripts/rust-toolchain.mjs` names it explicitly (`rustup run <pin>`,
  `rustup which --toolchain <pin>`) precisely so a Homebrew rustc on PATH cannot shadow it.
  Jobs that happen to run cargo from the repo root first — anything with a `Cache Cargo state`
  step — got the install as a side effect of the toolchain file, which is why the missing step
  surfaced only in `release.yml`'s macOS verify job, the one job that calls a pinned-toolchain
  script before any cargo invocation. Note that `rust-toolchain.toml`'s own header still says
  rustup installs the pin on demand; it is left alone deliberately, because the file is hashed
  into the XCFramework's provenance manifest and editing even a comment would invalidate the
  committed artifact and require a rebuild. This section is the accurate one.
- `packages/inderun-route-core-wasm/generated/` is intentionally not checked in, with one
  exception: `inderun_route_core.d.ts` and `inderun_speech_text.d.ts` are stubs tracked in git so
  `tsc` can resolve the package's literal `import("../generated/inderun_route_core.js")` (and the
  speech module's) without
  requiring the Rust/wasm-bindgen toolchain locally. The `wasm-bindgen --target web` step
  overwrites it with the real generated bindings during the build; the stub is not meant to be
  committed back and should only be hand-updated if the Rust route-core API changes.
  `release.yml` reverts this overwrite (`git checkout -- packages/inderun-route-core-wasm/generated`)
  right after the workspace build/test steps and before `semantic-release` runs, since
  semantic-release's dev back-merge does a `git rebase` that fails on any unstaged change.
- `packages/inderun-web-demo`'s `build` script runs `scripts/verify-wasm-route-planner-bundled.mjs`
  after `vite build`, failing the build if the shared route-core WASM asset and JS chunk are not
  found in `dist/assets/`. This is the regression gate for issue #109: the WASM route planner's
  dynamic import previously used a variable specifier plus `/* @vite-ignore */`, which Vite
  cannot statically resolve into a bundled chunk — and critically, `@vite-ignore` also suppresses
  Rollup's "cannot be statically analyzed" warning, so a build-time `onwarn` hook cannot catch
  this class of regression; checking the actual emitted output is the only reliable gate.
- Dependabot is configured for GitHub Actions, npm, Cargo, Gradle, and Swift Package Manager in the repository. The Swift entry's `directory` is `/`, where `Package.swift` lives, not `ios/IndeRun`, where the sources live.
