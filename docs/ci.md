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
