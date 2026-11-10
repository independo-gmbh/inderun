<p align="center">
  <a href="https://inderun.dev">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://inderun.dev/brand/inderun-logo-dark.svg">
      <img alt="IndeRun" src="https://inderun.dev/brand/inderun-logo-light.svg" width="360">
    </picture>
  </a>
</p>

<p align="center">
  <a href="https://www.npmjs.com/package/@independo/inderun-route-core-wasm"><img alt="npm: @independo/inderun-route-core-wasm" src="https://img.shields.io/npm/v/@independo/inderun-route-core-wasm?logo=npm"></a>
  <a href="https://github.com/independo-gmbh/inderun/actions/workflows/javascript.yml"><img alt="JavaScript" src="https://github.com/independo-gmbh/inderun/actions/workflows/javascript.yml/badge.svg?branch=dev"></a>
  <a href="https://github.com/independo-gmbh/inderun/actions/workflows/rust.yml"><img alt="Rust" src="https://github.com/independo-gmbh/inderun/actions/workflows/rust.yml/badge.svg?branch=dev"></a>
  <a href="https://github.com/independo-gmbh/inderun/blob/main/LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue"></a>
  <a href="https://inderun.dev/docs"><img alt="Docs: inderun.dev" src="https://img.shields.io/badge/docs-inderun.dev-A0B3FF"></a>
</p>

# @independo/inderun-route-core-wasm

> Part of **[IndeRun](https://github.com/independo-gmbh/inderun)** — runs AI on the device when a model
> is available, and in the cloud only when the app configures a cloud target and the request allows it.
> New here? Start with the [documentation](https://inderun.dev/docs).

WebAssembly wrapper around the shared Rust route-planning core.

The generated WASM and JS bindings are not checked in. Build them from the repository root when needed.

## Exports

- `initSharedCore(moduleOrPath?)` loads the module; the other exports call it on first use.
- `planRouteJson(inputJson)` plans a route (JSON in, JSON out).
- `normalizeSpeechText(text, locale)` rewrites speech text into its spoken form (numbers, dates,
  times, abbreviations in words). Only German locales are rewritten; any other locale returns the
  text unchanged. The neural speech provider calls it before sentence splitting.
- `initSpeechText(moduleOrPath?)` is `initSharedCore`'s counterpart for the speech text module.

The package ships two WASM modules. `planRouteJson` uses the small planner module
(`inderun_route_core_bg.wasm`); `normalizeSpeechText` uses a second one
(`inderun_speech_text_bg.wasm`, several times larger because of its regex engine) that is fetched
only on first use, so apps that never speak German text do not download it. A host that self-hosts
the assets (see below) must serve both.

## Generate

```sh
RUSTC="$(rustup which rustc --toolchain stable)" rustup run stable \
  cargo build -p inderun_route_core --target wasm32-unknown-unknown --no-default-features
wasm-bindgen target/wasm32-unknown-unknown/debug/inderun_route_core.wasm \
  --target web --out-dir packages/inderun-route-core-wasm/generated \
  --out-name inderun_route_core

RUSTC="$(rustup which rustc --toolchain stable)" rustup run stable \
  cargo build -p inderun_route_core --target wasm32-unknown-unknown \
  --no-default-features --features speech-text --target-dir target/wasm-speech-text
wasm-bindgen target/wasm-speech-text/wasm32-unknown-unknown/debug/inderun_route_core.wasm \
  --target web --out-dir packages/inderun-route-core-wasm/generated \
  --out-name inderun_speech_text

pnpm --filter @independo/inderun-route-core-wasm build
```

## Consuming from a bundler

`@independo/inderun-route-core-wasm`'s default export uses a static, literal `import()` of
its generated bindings, and those bindings' `--target web` init defaults to
`new URL('inderun_route_core_bg.wasm', import.meta.url)` followed by `fetch(...)` when no
explicit module/bytes are passed in. This is the standard wasm-bindgen + bundler idiom: Vite,
webpack 5, and Rollup all recognize `new URL(relative, import.meta.url)` natively and emit the
referenced file as a real asset — no bundler-specific WASM plugin or config is required (see
`packages/inderun-web-demo` for a working example).

If an app needs to self-host the `.wasm` file explicitly (for example, precaching it for
offline/PWA use), the `./generated/*` export subpath exposes the raw generated assets:

```ts
import wasmUrl from "@independo/inderun-route-core-wasm/generated/inderun_route_core_bg.wasm?url";
```

## Building and size budgets

`pnpm build:wasm` (repo root) builds both modules with the size-optimised `wasm` cargo profile.
`pnpm check:wasm-size` then compares each module's raw and gzip size with the budgets in
`scripts/check-wasm-size.mjs` and exits 1 when one is over; CI runs it after the build.

## About IndeRun

This package is developed and published from the
[independo-gmbh/inderun](https://github.com/independo-gmbh/inderun) monorepo. For the
architecture overview, provider model, and getting-started guides, see the
[IndeRun documentation](https://github.com/independo-gmbh/inderun#readme). Built by
[Independo GmbH](https://www.independo.app) · Licensed MIT.
