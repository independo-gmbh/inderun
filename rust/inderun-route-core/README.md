# inderun-route-core

Shared Rust route-planning core for IndeRun.

This crate owns deterministic Mode 1 route planning only. It does not execute providers, resolve credentials, or make network calls.

It exposes the same planner across a native Rust API, a C FFI entry point, a JNI
binding for Android, and a WASM binding for the web. The exact exported symbols
and their signatures are defined in `src/lib.rs` — refer to the source rather
than duplicating the list here.

## Commands

```sh
cargo test -p inderun_route_core
cargo build -p inderun_route_core
```
