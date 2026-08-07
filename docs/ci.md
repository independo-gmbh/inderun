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
- `CodeQL` (`codeql.yml`): runs GitHub code scanning (advanced setup) across `swift`, `java-kotlin`, `rust`, `javascript-typescript`, and `actions`. The compiled languages use explicit `build-mode: manual` steps — `swift build` from the repository root (the SwiftPM manifest is `Package.swift` at the root; sources under `ios/IndeRun`) and `./gradlew assembleDebug` in `android` (with JDK 21 + Android SDK provisioned) — so the autobuilder can't misdetect one of the demo/sample apps. `rust`, `javascript-typescript`, and `actions` use `build-mode: none`. Also runs weekly on a schedule.

## Code Scanning

Code scanning uses **advanced setup** — the committed `codeql.yml` workflow is the source
of truth, not GitHub's default (UI-managed) setup. The two conflict, so **default setup
must be set to "Not configured"** under Settings → Code security → Code scanning; otherwise
the CodeQL runs fail. The compiled languages use explicit manual builds so the autobuilder
can't lock onto a demo/sample app: Swift builds the SwiftPM package (`swift build` from the
repository root) rather than the `ios/SampleApps/IndeRunDemo` Xcode project, and Android runs
`./gradlew assembleDebug` across all modules rather than guessing a variant/target. Both
scan the product code, not the sample apps.

## Branch Protection

Protect `main` with these required checks:

- `JavaScript`
- `Rust`
- `Swift`
- `Android`
- `Capacitor Plugin`

## Notes

- The JavaScript workflow also regenerates the shared contract and WASM artifacts before package builds.
- `pnpm generate` emits the contract types for every language from `contracts/schemas/`: TypeScript, Kotlin, and Swift for the full surface, plus the Rust route-core model (`rust/inderun-route-core/src/generated/contracts.rs`) from the two route schemas. The generated Rust file is committed and normalized with `rustfmt` so `cargo fmt --check` stays green.
- `packages/inderun-route-core-wasm/generated/` is intentionally not checked in, with one
  exception: `inderun_route_core.d.ts` is a hand-written stub tracked in git so `tsc` can
  resolve the package's literal `import("../generated/inderun_route_core.js")` without
  requiring the Rust/wasm-bindgen toolchain locally. CI's `wasm-bindgen --target web` step
  overwrites it with the real generated bindings during the build; the stub is not meant to be
  committed back and should only be hand-updated if the Rust route-core API changes.
- `packages/inderun-web-demo`'s `build` script runs `scripts/verify-wasm-route-planner-bundled.mjs`
  after `vite build`, failing the build if the shared route-core WASM asset and JS chunk are not
  found in `dist/assets/`. This is the regression gate for issue #109: the WASM route planner's
  dynamic import previously used a variable specifier plus `/* @vite-ignore */`, which Vite
  cannot statically resolve into a bundled chunk — and critically, `@vite-ignore` also suppresses
  Rollup's "cannot be statically analyzed" warning, so a build-time `onwarn` hook cannot catch
  this class of regression; checking the actual emitted output is the only reliable gate.
- Dependabot is configured for GitHub Actions, npm, Cargo, Gradle, and Swift Package Manager in the repository.
