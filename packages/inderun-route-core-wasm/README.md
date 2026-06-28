# @independo/inderun-route-core-wasm

Thin TypeScript wrapper around the Rust shared route planner compiled to WebAssembly.

## Generate WASM bindings

From the repo root:

```sh
RUSTC="$(rustup which rustc --toolchain stable)" \
  rustup run stable cargo build -p inderun_route_core --target wasm32-unknown-unknown

wasm-bindgen target/wasm32-unknown-unknown/debug/inderun_route_core.wasm \
  --target web \
  --out-dir packages/inderun-route-core-wasm/generated \
  --out-name inderun_route_core

pnpm --filter @independo/inderun-route-core-wasm build
```

The generated JS/WASM files are intentionally not checked in.
