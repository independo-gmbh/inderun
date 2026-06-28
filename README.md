# IndeRun

IndeRun is an open, reusable AI execution framework that lets applications run the same AI tasks through **one unified
interface**, independent of where execution happens (**on-device**, **embedded runtime**, **edge**, **cloud**).

## Project status

This repository is currently in an **architecture-first phase**. Core design, contracts, and provider strategy are
defined in `docs/architecture/*`; implementation is incremental.

[![JavaScript](https://github.com/independo-gmbh/inderun/actions/workflows/javascript.yml/badge.svg)](https://github.com/independo-gmbh/inderun/actions/workflows/javascript.yml)
[![Rust](https://github.com/independo-gmbh/inderun/actions/workflows/rust.yml/badge.svg)](https://github.com/independo-gmbh/inderun/actions/workflows/rust.yml)
[![Swift](https://github.com/independo-gmbh/inderun/actions/workflows/swift.yml/badge.svg)](https://github.com/independo-gmbh/inderun/actions/workflows/swift.yml)
[![Android](https://github.com/independo-gmbh/inderun/actions/workflows/android.yml/badge.svg)](https://github.com/independo-gmbh/inderun/actions/workflows/android.yml)

It will support:

- **Mode 1: Run** — request/response (`run()`)
- **Mode 2: Stream** — unified event stream (`stream()` + `events()` + `cancel()`)
- **Mode 3: Session** — bidirectional realtime (`openSession()` + `send()` + `events()` + `interrupt()` + `close()`)

**Implementation not planned for now:**

- **Mode 4: Submit/Jobs** — we keep the architecture seams ready, but do not build job/queue infrastructure now.

---

## Why IndeRun

Teams building AI features often need to choose between privacy, latency, cost, and reliability. IndeRun separates
task execution from provider specifics so applications can:

- call one API surface from app code
- route execution by policy and runtime capabilities
- fallback predictably when preferred providers are unavailable

---

## Packages & SDKs

### JavaScript/TypeScript (npm, under `@independo/…`)

- `@independo/inderun-contracts` — generated TS types, schema constants, and validators
- `@independo/inderun-web` — Web SDK (public API + web HostServices + web providers)
- `@independo/inderun-demo-proxy` — private standalone proxy backend for demo apps
- `@independo/inderun-web-demo` — private web demo client for reviewing the Mode-1 cloud flow
- `@independo/capacitor-inderun` — Capacitor facade/bridge (thin wrapper delegating to web + native SDKs)

> Naming note: `@types/*` packages are typically for community-maintained declarations (DefinitelyTyped) for
> packages that do not ship their own types. IndeRun publishes first-party typed packages under `@independo/*`.

### Native SDKs

- **iOS**: IndeRun Swift Package (Swift-first API + HostServices + core engine)
- **Android**: IndeRun Android SDK (Kotlin-first API + HostServices + core engine)
- **Android demo app**: checked-in Compose demo under `android/inderun-demo-app`
- **Rust shared core**: deterministic route-planning core under `rust/inderun-route-core`

> Capacitor is **not** a peer runtime — it is a thin wrapper that exposes a JS API and delegates to
`@independo/inderun-web` (web) or the native SDKs (iOS/Android).

---

## Documentation

- Technical brief: `docs/architecture/technical-brief.md`
- Architecture: `docs/architecture/architecture.md`
- Providers: `docs/architecture/providers.md`
- CI and branch protection: `docs/ci.md`
- Agent entrypoint: `AGENTS.md`

---

## Repository layout (target high-level structure)

```
inderun/
  contracts/
    schemas/                  # canonical JSON Schema sources shared by TS, Swift, Kotlin, and bridges
  packages/                 # JS/TS workspace (@independo/*)
  core/                     # shared engine core (routing/policy/orchestrator/events)
  ios/                      # iOS SDK (Swift Package)
  android/                  # Android SDK (Gradle/Maven)
  docs/
    architecture/
  tools/                    # codegen + release automation
```

---

## Development (placeholder)

JavaScript CI and local workflows are pinned to **Node 24.x** and **pnpm 11.9.0**. If your local environment does not
ship `pnpm`, use the checked-in `npm run deps:update` script for dependency update maintenance and install pnpm through
Corepack or your preferred toolchain manager for regular workspace commands.

This repository is designed to support multiple platforms and packaging formats. Typical workflows include:

- schema/type generation (JSON Schema → TS/Swift/Kotlin)
- unit tests for deterministic routing + cancellation semantics
- adapter contract tests (error mapping + event normalization)
- platform integration tests (AsyncStream / Flow / Capacitor event channels)

> Add additional concrete commands once more build tooling is finalized (Gradle, SwiftPM, etc.).
> Do not assume or document commands as available until they are checked into this repository.

### Checked-in commands

Install JavaScript dependencies:

```sh
pnpm install
```

Update JavaScript dependencies with the pinned pnpm line:

```sh
npm run deps:update
```

Run all currently checked-in package builds and tests:

```sh
pnpm build
pnpm test
```

Regenerate generated contract artifacts from `contracts/schemas`:

```sh
pnpm generate
```

Contracts package only:

```sh
pnpm --filter @independo/inderun-contracts build
pnpm --filter @independo/inderun-contracts test
```

Demo proxy package:

```sh
pnpm --filter @independo/inderun-demo-proxy dev
pnpm --filter @independo/inderun-demo-proxy start
pnpm --filter @independo/inderun-demo-proxy build
pnpm --filter @independo/inderun-demo-proxy test
```

Web demo package:

```sh
pnpm --filter @independo/inderun-web-demo dev
pnpm --filter @independo/inderun-web-demo build
pnpm --filter @independo/inderun-web-demo preview
pnpm --filter @independo/inderun-web-demo test
```

The web demo client calls the standalone demo proxy, so the browser does not carry raw provider secrets in request
payloads. The proxy can target the default OpenAI Responses endpoint with `OPENAI_API_KEY`, or a custom
OpenAI-compatible endpoint via `INDERUN_OPENAI_ENDPOINT_URL` with optional bearer auth.

### Swift (iOS SDK) Package commands

Build the iOS/Swift SDK:

```sh
cd ios/IndeRun && swift build
```

Run iOS/Swift SDK unit tests:

```sh
cd ios/IndeRun && swift test
```

### Android SDK commands

Build the Android SDK:

```sh
cd android && ./gradlew build
```

Run Android SDK unit tests:

```sh
cd android && ./gradlew test
```

The Android build expects a local Android SDK configured via `ANDROID_HOME` or `android/local.properties`.

### Rust shared-core commands

Build and test the shared route-planning core:

```sh
cargo build -p inderun_route_core
cargo test -p inderun_route_core
```

Build the wasm target with the rustup-managed toolchain:

```sh
RUSTC="$(rustup which rustc --toolchain stable)" \
  rustup run stable cargo build -p inderun_route_core --target wasm32-unknown-unknown

wasm-bindgen target/wasm32-unknown-unknown/debug/inderun_route_core.wasm \
  --target web \
  --out-dir packages/inderun-route-core-wasm/generated \
  --out-name inderun_route_core

pnpm --filter @independo/inderun-route-core-wasm test
```

### Rust setup

Minimal setup for the shared route planner:

```sh
brew install rust
brew install rustup-init
rustup-init
rustup default stable
rustup target add wasm32-unknown-unknown
rustup target add aarch64-apple-ios
rustup target add aarch64-apple-ios-sim
cargo install wasm-pack
cargo install wasm-bindgen-cli
```

If `wasm-pack` reports that `wasm32-unknown-unknown` is missing while `rustup target list --installed` shows it, your
shell is probably picking Homebrew `rustc` instead of the rustup-managed toolchain. In that case, use the explicit
`RUSTC=... rustup run stable cargo build --target wasm32-unknown-unknown` command above or move the rustup shims ahead of Homebrew in
your PATH.

## CI

GitHub Actions validates the repository with split JavaScript, Rust, Swift, and Android workflows. See `docs/ci.md`
for workflow details, required branch-protection checks, and the JS-side WASM generation steps performed in CI.

---

## Design principles (quick)

- **Deterministic routing** given `(request + policy + capabilities snapshot + provider descriptors)`
- **Unified event model** separating user-visible output from mechanics (tools/reasoning)
- **Standard cancellation guarantee** (no events after cancel; terminal `cancelled`)
- **Provider capability metadata** drives routing (streaming/realtime/tools/limits/transport)
- **Secrets never in requests** — credentials via secure storage slots (`authContextRef`)

---

## License

MIT. See `LICENSE`.

---

## Sponsorship & Development

This project is sponsored by [netidee](https://www.netidee.at/inderun) and developed
by [Independo GmbH](https://www.independo.app).
