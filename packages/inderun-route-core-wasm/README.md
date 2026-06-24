# @independo/inderun-route-core-wasm

Thin TypeScript wrapper around the Rust shared route planner compiled to WebAssembly.

## Generate WASM bindings

From the repo root:

```sh
wasm-pack build rust/inderun-route-core \
  --target web \
  --out-dir ../../packages/inderun-route-core-wasm/generated
pnpm --filter @independo/inderun-route-core-wasm build
```

The generated JS/WASM files are intentionally not checked in.
