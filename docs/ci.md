# CI

IndeRun uses split GitHub Actions workflows so each ecosystem reports its own status check.

## Workflows

Each workflow lives in `.github/workflows/` — treat those files as the source of
truth for exact steps. This table describes only what each one covers.

- `JavaScript` (`javascript.yml`): builds and tests the pnpm packages, regenerating the shared contract and Rust→WASM artifacts first.
- `Rust` (`rust.yml`): builds and tests the `inderun_route_core` crate.
- `Swift` (`swift.yml`): builds and tests the iOS/SwiftPM package.
- `Android` (`android.yml`): builds and tests the Gradle modules.
- The Capacitor bridge (`@independo/capacitor-inderun`) now lives in its own repository, [independo-gmbh/inderun-capacitor](https://github.com/independo-gmbh/inderun-capacitor), which runs its own web/iOS/Android CI there.
- `Release` (`release.yml`): on pushes to `main`/`dev`, runs `pnpm generate` first so the schema-derived Kotlin contract stays Spotless-formatted, then builds the workspace (incl. the Rust→WASM artifacts) and runs semantic-release to version, changelog, tag, and publish the npm packages. See `docs/release.md`.
- `Maven Publish` (`maven-publish.yml`): on a published (non-prerelease) GitHub release, publishes the Android library modules to Maven Central.
- `CodeQL` (`codeql.yml`): runs GitHub code scanning (advanced setup) across `swift`, `java-kotlin`, `rust`, `javascript-typescript`, and `actions`. The compiled languages use explicit `build-mode: manual` steps — `swift build` from the repository root (the SwiftPM manifest is `Package.swift` at the root; sources under `ios/IndeRun`) and `./gradlew assembleDebug` in `android` (with JDK 21 + Android SDK provisioned) — so the autobuilder can't misdetect one of the demo/sample apps. `rust`, `javascript-typescript`, and `actions` use `build-mode: none`. `pull_request` trigger is `main`-only; `dev` is covered by the weekly schedule instead (see Code Scanning below).

## Code Scanning

Code scanning uses **advanced setup** — the committed `codeql.yml` workflow is the source
of truth, not GitHub's default (UI-managed) setup. The two conflict, so **default setup
must be set to "Not configured"** under Settings → Code security → Code scanning; otherwise
the CodeQL runs fail. The compiled languages use explicit manual builds so the autobuilder
can't lock onto a demo/sample app: Swift builds the SwiftPM package (`swift build` from the
repository root) rather than the `ios/SampleApps/IndeRunDemo` Xcode project, and Android runs
`./gradlew assembleDebug` across all modules rather than guessing a variant/target. Both
scan the product code, not the sample apps.

CodeQL's `pull_request` trigger only targets `main` — every PR into `main` gets full
analysis. `dev` is not PR-gated by CodeQL; it relies on the weekly `schedule` run
(`cron: "27 3 * * 1"`), which scans the repository's default branch (`dev`). This
trades slightly staler dev coverage (up to a week) for not running five CodeQL matrix
jobs on every dev-targeted PR. Because of this, `dev` branch protection must **not**
require the `Analyze (*)` contexts — see Branch Protection below.

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
- `android.yml`: `android/**`
- `rust.yml`: `rust/**`, `Cargo.toml`, `Cargo.lock`
- `swift.yml`: `ios/**`, `Package.swift`

Each filter also includes the workflow's own file, so editing a workflow always
re-runs it. This is deliberately done as an in-workflow `changes` job rather than a
top-level `on.pull_request.paths:` filter — GitHub can leave a required check stuck
`Pending` forever if the whole workflow is skipped by trigger-level path filtering.
`codeql.yml` is not path-gated within `main` PRs; it always runs there (see Code
Scanning above for why it's excluded from `dev` PRs instead of path-gated).

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
  ktlint-clean.
- `pnpm build:wasm` (`scripts/build-route-core-wasm.mjs`) is the single definition of the
  Rust→WASM build: it runs `cargo build --target wasm32-unknown-unknown` plus
  `wasm-bindgen --target web`. Freshness is left to cargo, which fingerprints every effective
  input (sources, workspace manifest, lockfile, rustc version); only the wasm-bindgen step is
  skipped, and only when the existing bindings are newer than the `.wasm` cargo just produced.
  A hand-rolled mtime check over crate sources alone would serve stale bindings after a
  dependency bump. Both `pnpm build` and `pnpm test:js` call it, and `javascript.yml`/`release.yml`
  run it as an explicit step so a missing toolchain fails visibly. Since the Web SDK has no
  fallback planner (issue #164), the JS suite genuinely needs those bindings — hence building
  them is part of `pnpm test:js` rather than a prerequisite contributors are expected to
  remember. Running the JS tests locally therefore requires `rustup` with the
  `wasm32-unknown-unknown` target and `wasm-bindgen-cli` (the script prints the install
  commands when either is missing).
- `packages/inderun-route-core-wasm/generated/` is intentionally not checked in, with one
  exception: `inderun_route_core.d.ts` is a hand-written stub tracked in git so `tsc` can
  resolve the package's literal `import("../generated/inderun_route_core.js")` without
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
- Dependabot is configured for GitHub Actions, npm, Cargo, Gradle, and Swift Package Manager in the repository.
