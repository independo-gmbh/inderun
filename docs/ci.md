# CI

IndeRun uses split GitHub Actions workflows so each ecosystem reports its own status check.

## Workflows

- `JavaScript`: `pnpm install --frozen-lockfile`, `pnpm generate`, Rust WASM generation, `pnpm build`, `pnpm test`
- `Rust`: `cargo test -p inderun_route_core`
- `Swift`: `cd ios/IndeRun && swift test`
- `Android`: `cd android && ./gradlew test`

## Branch Protection

Protect `main` with these required checks:

- `JavaScript`
- `Rust`
- `Swift`
- `Android`

## Notes

- The JavaScript workflow also regenerates the shared contract and WASM artifacts before package builds.
- `packages/inderun-route-core-wasm/generated/` is intentionally not checked in.
- Dependabot is configured for GitHub Actions, npm, Cargo, Gradle, and Swift Package Manager in the repository.
