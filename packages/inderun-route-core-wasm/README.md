# @independo/inderun-route-core-wasm

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
