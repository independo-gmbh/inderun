# CI

IndeRun uses split GitHub Actions workflows so each ecosystem reports an independent status check.
Workflows run for pull requests targeting `main` or `dev`, and for direct pushes to `main`:

- `JavaScript`: Node 24 + pnpm 11.9.0 install, contract generation, Rust WASM generation, JS build, JS tests
- `Rust`: shared route-planning core tests
- `Swift`: `ios/IndeRun` Swift Package tests
- `Android`: Gradle unit tests across the checked-in Android modules

## Caching

- `JavaScript` uses the GitHub-managed pnpm store cache keyed from `pnpm-lock.yaml`.
- `JavaScript` and `Rust` both restore Cargo registry/build state through a Rust-specific cache action.
- `JavaScript` separately caches the installed `wasm-bindgen-cli` binary and Cargo install metadata so repeated runs do
  not reinstall it from scratch.
- `Android` uses Gradle dependency caching through `actions/setup-java`.
- `Swift` has no dedicated dependency cache yet because `ios/IndeRun/Package.swift` currently has no external package
  dependencies.

## Workflow Commands

### JavaScript

The JavaScript workflow runs these repository-authoritative commands:

```sh
pnpm install --frozen-lockfile
pnpm generate
RUSTC="$(rustup which rustc --toolchain stable)" \
  rustup run stable cargo build -p inderun_route_core --target wasm32-unknown-unknown
wasm-bindgen target/wasm32-unknown-unknown/debug/inderun_route_core.wasm \
  --target web \
  --out-dir packages/inderun-route-core-wasm/generated \
  --out-name inderun_route_core
pnpm build
pnpm test
```

`packages/inderun-route-core-wasm/generated/` is intentionally gitignored. CI generates those bindings before running
the workspace build and test commands.

### Rust

```sh
cargo test -p inderun_route_core
```

### Swift

```sh
cd ios/IndeRun && swift test
```

### Android

```sh
cd android && ./gradlew test
```

## Branch Protection

Protect `main` with these required checks:

- `JavaScript`
- `Rust`
- `Swift`
- `Android`

Keep the job names aligned with those exact labels so branch-protection configuration stays stable.

## Dependabot

Dependabot is configured for:

- GitHub Actions at `/`
- npm at `/`
- Cargo at `/`
- Gradle at `/android`
- Swift Package Manager at `/ios/IndeRun`

Publishing and release-artifact verification are intentionally out of scope here and tracked separately in issue `#22`.
