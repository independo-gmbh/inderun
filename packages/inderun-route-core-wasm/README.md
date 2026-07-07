# @independo/inderun-route-core-wasm

[![npm](https://img.shields.io/npm/v/@independo/inderun-route-core-wasm?logo=npm)](https://www.npmjs.com/package/@independo/inderun-route-core-wasm)

> Part of **[IndeRun](https://github.com/independo-gmbh/inderun)** — an open-source AI execution
> framework that gives applications one unified API for running tasks across on-device, edge, and
> cloud providers. New here? Start with the [IndeRun README](https://github.com/independo-gmbh/inderun#readme).

WebAssembly wrapper around the shared Rust route-planning core.

The generated WASM and JS bindings are not checked in. Build them from the repository root when needed.

## Generate

```sh
RUSTC="$(rustup which rustc --toolchain stable)" \
  rustup run stable cargo build -p inderun_route_core --target wasm32-unknown-unknown

wasm-bindgen target/wasm32-unknown-unknown/debug/inderun_route_core.wasm \
  --target web \
  --out-dir packages/inderun-route-core-wasm/generated \
  --out-name inderun_route_core

pnpm --filter @independo/inderun-route-core-wasm build
```

## About IndeRun

This package is developed and published from the
[independo-gmbh/inderun](https://github.com/independo-gmbh/inderun) monorepo. For the
architecture overview, provider model, and getting-started guides, see the
[IndeRun documentation](https://github.com/independo-gmbh/inderun#readme). Built by
[Independo GmbH](https://www.independo.app) · Licensed MIT.
