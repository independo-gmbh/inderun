# Contributing

IndeRun is a code-first repository. External markdown should explain concepts and usage, but implementation detail
should live in code comments, schemas, and generated public types whenever possible.

## Before You Start

- Read `AGENTS.md`.
- Read the architecture brief, architecture overview, provider overview, and CI notes.
- Check the existing package or platform README before changing a public surface.

## Prerequisites

The repository spans four toolchains. Install only the ones you need: each language's commands, tests, and
CI workflow are independent, so you can contribute to the TypeScript packages without a Swift or Android
toolchain installed.

| Area                | Requirement                                                                     |
| ------------------- | ------------------------------------------------------------------------------- |
| TypeScript packages | Node `24.x` (see `.nvmrc`), pnpm `11.9.0` (`corepack enable`)                   |
| Rust core           | Rust stable via `rustup`                                                        |
| Web route planner   | `wasm32-unknown-unknown` target and `wasm-bindgen-cli` (version-matched, below) |
| Android library     | JDK 21, Android SDK with `compileSdk 37`, `ANDROID_HOME` exported               |
| Swift SDK           | Swift 5.9+ toolchain; SwiftLint for `pnpm format:swift` / lint                  |

### Rust and the WASM route planner

`pnpm build` builds `@independo/inderun-web-demo`, which bundles the route planner compiled to WebAssembly.
The bindings under `packages/inderun-route-core-wasm/generated/` are build artifacts and are not checked in,
so a fresh clone must generate them once before the first `pnpm build`, otherwise the bundler fails with
`Could not resolve '../generated/inderun_route_core.js'`.

Install the toolchain. The `wasm-bindgen-cli` version must match the `wasm-bindgen` version in `Cargo.lock`,
or the generated bindings will be rejected at runtime:

```sh
rustup target add wasm32-unknown-unknown
cargo install wasm-bindgen-cli --version 0.2.127 --locked
```

Then generate the bindings:

```sh
RUSTC="$(rustup which rustc --toolchain stable)" rustup run stable \
  cargo build -p inderun_route_core --target wasm32-unknown-unknown
wasm-bindgen target/wasm32-unknown-unknown/debug/inderun_route_core.wasm \
  --target web --out-dir packages/inderun-route-core-wasm/generated \
  --out-name inderun_route_core
```

Re-run both commands whenever the Rust core changes.

`wasm-bindgen` also overwrites `generated/inderun_route_core.d.ts`, which is checked in as a hand-written
stub so `tsc` resolves without the Rust toolchain. The regenerated file drops that stub's explanatory
header, so revert it before committing unless the route-core API actually changed:

```sh
git checkout -- packages/inderun-route-core-wasm/generated/inderun_route_core.d.ts
```

### Android

Gradle needs the Android SDK location. Either export `ANDROID_HOME` (for example
`export ANDROID_HOME="$HOME/Android/Sdk"`) or create `android/local.properties` with `sdk.dir=/path/to/Sdk`.
Unit tests run on a pinned Java 21 toolchain regardless of your default JDK, so Gradle must be able to
resolve a JDK 21 installation.

## Setup

- Use the checked-in commands below rather than inventing new workflow steps.
- Keep any new tooling documented in this file and `AGENTS.md`.
- Opt into the commit-message template, which encodes the Conventional Commits footer
  order this repository's release automation depends on (`BREAKING CHANGE:` last):

  ```sh
  git config commit.template .gitmessage
  ```

  Git stores `commit.template` per clone, so this is a one-time step and cannot be
  checked in for you. See [docs/release.md](docs/release.md) for why the order matters.

## Commands

Repository-root commands:

```sh
pnpm install
pnpm build
pnpm test
pnpm generate
swift build
swift test
cd android && ./gradlew build
cd android && ./gradlew test
cargo build -p inderun_route_core
cargo test -p inderun_route_core
```

Lint and format (run before pushing; CI gates on these):

```sh
pnpm lint                                                    # ESLint (TypeScript)
pnpm format                                                  # Prettier write (format:check to verify)
cd ios/IndeRun && swiftlint lint --strict                    # Swift
cd android && ./gradlew spotlessApply                        # Kotlin (spotlessCheck to verify)
cargo fmt -p inderun_route_core                              # Rust (add -- --check to verify)
cargo clippy -p inderun_route_core --all-targets -- -D warnings
```

Package commands:

```sh
pnpm --filter @independo/inderun-contracts build
pnpm --filter @independo/inderun-contracts test
pnpm --filter @independo/inderun-demo-proxy dev
pnpm --filter @independo/inderun-demo-proxy start
pnpm --filter @independo/inderun-demo-proxy build
pnpm --filter @independo/inderun-demo-proxy test
pnpm --filter @independo/inderun-web-demo dev
pnpm --filter @independo/inderun-web-demo build
pnpm --filter @independo/inderun-web-demo preview
pnpm --filter @independo/inderun-web-demo test
pnpm --filter @independo/inderun-web build
pnpm --filter @independo/inderun-web test
```

## Docs Policy

- Put field-level contract meaning in `contracts/schemas/*.schema.json`.
- Put public API behavior in source doc comments when the code owns the behavior.
- Keep markdown focused on concepts, onboarding, and operational guidance.
- Remove or rewrite markdown that duplicates generated types, schema descriptions, or source comments.
- Update external docs only when the public behavior or contributor workflow changes.

## Change Expectations

- Keep edits small and reviewable.
- Do not add new commands to docs unless they are checked into the repository.
- When behavior changes, update the relevant README or architecture page in the same change.

## Review Checklist

- The docs match the current code.
- The examples compile against the public API.
- No markdown page claims support for a surface that is not implemented.
- No page repeats contract detail that already lives in schemas or generated types.
