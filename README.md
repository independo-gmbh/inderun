# IndeRun

IndeRun is an open-source AI execution framework that gives applications one unified API for running tasks across on-device, edge, and cloud providers.

The project is organized around a few stable ideas:

- `run()` is the current public execution path.
- Routing is deterministic and based on request constraints plus host capability snapshots.
- Provider behavior is normalized so apps do not need provider-specific branching in their own code.
- Secrets stay out of request payloads and are referenced through `authContextRef`.

## Current Scope

IndeRun is currently focused on Mode 1 `run()` execution. Streaming and realtime sessions are part of the architecture, but they are not the primary shipped surface yet.

## Main Packages

- `@independo/inderun-contracts` - canonical JSON Schema-backed contracts and generated types
- `@independo/inderun-web` - TypeScript/Web SDK and engine entrypoint
- `@independo/inderun-demo-proxy` - standalone proxy backend for demo flows
- `@independo/inderun-web-demo` - browser demo for the cloud execution path
- `@independo/inderun-route-core-wasm` - WebAssembly wrapper for the shared Rust route planner

## Platform SDKs

- iOS: `ios/IndeRun`
- Android: `android/`
- Rust shared route planner: `rust/inderun-route-core`

## Documentation

- Project brief: `docs/architecture/technical-brief.md`
- Architecture overview: `docs/architecture/architecture.md`
- Provider model: `docs/architecture/providers.md`
- CI behavior: `docs/ci.md`
- Contributor workflow: `CONTRIBUTING.md`
- Agent instructions: `AGENTS.md`

## Commands

Repository-root commands:

```sh
pnpm install
pnpm build
pnpm test
pnpm generate
```

Platform-specific commands:

```sh
cd ios/IndeRun && swift build
cd ios/IndeRun && swift test
cd android && ./gradlew build
cd android && ./gradlew test
cargo build -p inderun_route_core
cargo test -p inderun_route_core
```

## License

MIT. See `LICENSE`.
