# CI

IndeRun uses split GitHub Actions workflows so each ecosystem reports its own status check.

## Workflows

Each workflow lives in `.github/workflows/` — treat those files as the source of
truth for exact steps. This table describes only what each one covers.

- `JavaScript` (`javascript.yml`): builds and tests the pnpm packages, regenerating the shared contract and Rust→WASM artifacts first.
- `Rust` (`rust.yml`): builds and tests the `inderun_route_core` crate.
- `Swift` (`swift.yml`): builds and tests the iOS/SwiftPM package.
- `Android` (`android.yml`): builds and tests the Gradle modules.
- `Capacitor Plugin` (`capacitor.yml`): lints, unit-tests, and verifies the `@independo/capacitor-inderun` plugin across web, iOS, and Android.
- `Release` (`release.yml`): on pushes to `main`/`dev`, builds the workspace (incl. the Rust→WASM artifacts) and runs semantic-release to version, changelog, tag, and publish the npm packages. See `docs/release.md`.
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
- `packages/inderun-route-core-wasm/generated/` is intentionally not checked in.
- Dependabot is configured for GitHub Actions, npm, Cargo, Gradle, and Swift Package Manager in the repository.
