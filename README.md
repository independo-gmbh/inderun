# IndeRun

<p align="center">
  <a href="https://github.com/independo-gmbh/inderun/actions/workflows/javascript.yml"><img alt="JavaScript" src="https://github.com/independo-gmbh/inderun/actions/workflows/javascript.yml/badge.svg"></a>
  <a href="https://github.com/independo-gmbh/inderun/actions/workflows/rust.yml"><img alt="Rust" src="https://github.com/independo-gmbh/inderun/actions/workflows/rust.yml/badge.svg"></a>
  <a href="https://github.com/independo-gmbh/inderun/actions/workflows/swift.yml"><img alt="Swift" src="https://github.com/independo-gmbh/inderun/actions/workflows/swift.yml/badge.svg"></a>
  <a href="https://github.com/independo-gmbh/inderun/actions/workflows/android.yml"><img alt="Android" src="https://github.com/independo-gmbh/inderun/actions/workflows/android.yml/badge.svg"></a>
</p>

IndeRun is an open-source AI execution framework that gives applications one unified API for running tasks across
on-device, edge, and cloud providers.

The project is organized around a few stable ideas:

- `run()` is the current public execution path.
- Routing is deterministic and based on request constraints plus host capability snapshots.
- Provider behavior is normalized so apps do not need provider-specific branching in their own code.
- Secrets stay out of request payloads and are referenced through `authContextRef`.

## Start Here

IndeRun is currently focused on Mode 1 `run()` execution. Streaming and realtime sessions are part of the architecture,
but the shipped surface is centered on request/response execution.

If you are using IndeRun in an app, start with the package README that matches your platform:

- `@independo/inderun-web`
- `ios/IndeRun`
- `android/inderun-kotlin`

Supporting packages and demos:

- `@independo/inderun-contracts`
- `@independo/inderun-demo-proxy`
- `@independo/inderun-web-demo`
- `@independo/inderun-route-core-wasm`

## Core Docs

- Project brief: `docs/architecture/technical-brief.md`
- Architecture overview: `docs/architecture/architecture.md`
- Provider model: `docs/architecture/providers.md`
- CI behavior: `docs/ci.md`
- Contributor workflow and build commands: `CONTRIBUTING.md`
- Agent instructions: `AGENTS.md`

## License

MIT. See `LICENSE`.

## Sponsorship & Development

This project is sponsored by [netidee](https://www.netidee.at/inderun) and developed
by [Independo GmbH](https://www.independo.app).
