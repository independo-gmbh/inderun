# inderun-route-core

Shared Rust route-planning core for IndeRun.

This crate owns deterministic Mode 1 route planning only. It does not execute providers, resolve credentials, or make network calls.

It exposes the same planner across a native Rust API, a C FFI entry point, a JNI
binding for Android, and a WASM binding for the web. The exact exported symbols
and their signatures are defined in `src/lib.rs` — refer to the source rather
than duplicating the list here.

The crate also hosts speech text normalization (`normalize_speech_text`, German locales; see
[ADR 023](../../docs/architecture/decisions/023-german-text-frontend.md)) behind the Cargo feature `speech-text`, on by
default. The planner artifacts that every app loads (the WASM planner, `libinderun_route_core`, `InderunRouteCoreFFI`) are
built without it; neural speech loads separate artifacts that include it (`inderun_speech_text`,
`libinderun_speech_text`, `InderunSpeechTextFFI`).

## Commands

```sh
cargo test -p inderun_route_core
cargo build -p inderun_route_core
```
