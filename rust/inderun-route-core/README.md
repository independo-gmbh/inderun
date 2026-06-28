# inderun-route-core

Shared Rust route-planning core for IndeRun.

This crate owns deterministic Mode 1 route planning only. It does not execute providers, resolve credentials, or make network calls.

## Exports

- `plan_route`
- `inderun_plan_route_json`
- `SharedCoreRoutePlanner.planRouteJsonNative`
- `plan_route_json`

## Commands

```sh
cargo test -p inderun_route_core
cargo build -p inderun_route_core
```
