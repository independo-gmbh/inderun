# IndeRun

<p align="center">
  <a href="https://github.com/independo-gmbh/inderun/actions/workflows/javascript.yml"><img alt="JavaScript" src="https://github.com/independo-gmbh/inderun/actions/workflows/javascript.yml/badge.svg"></a>
  <a href="https://github.com/independo-gmbh/inderun/actions/workflows/rust.yml"><img alt="Rust" src="https://github.com/independo-gmbh/inderun/actions/workflows/rust.yml/badge.svg"></a>
  <a href="https://github.com/independo-gmbh/inderun/actions/workflows/swift.yml"><img alt="Swift" src="https://github.com/independo-gmbh/inderun/actions/workflows/swift.yml/badge.svg"></a>
  <a href="https://github.com/independo-gmbh/inderun/actions/workflows/android.yml"><img alt="Android" src="https://github.com/independo-gmbh/inderun/actions/workflows/android.yml/badge.svg"></a>
  <a href="https://github.com/independo-gmbh/inderun/actions/workflows/capacitor.yml"><img alt="Capacitor Plugin" src="https://github.com/independo-gmbh/inderun/actions/workflows/capacitor.yml/badge.svg"></a>
</p>

IndeRun is an open-source AI execution framework that gives applications one unified API for running tasks across
on-device, edge, and cloud providers.

The project is organized around a few stable ideas:

- `run()` is the current public execution path.
- Routing is deterministic and based on request constraints plus host capability snapshots.
- Provider behavior is normalized so apps do not need provider-specific branching in their own code.
- Secrets stay out of request payloads and are referenced through `authContextRef`.

## Start Here

IndeRun is currently focused on Mode 1 `run()` execution for `text_to_text`. Streaming and realtime sessions are
planned (Milestone 2) but not yet implemented; the shipped surface is request/response execution.

## Quick Start (Web)

```ts
import { createIndeRunWeb } from "@independo/inderun-web";

const inderun = createIndeRunWeb({
  // Point at a same-origin proxy that holds the OpenAI key server-side.
  openAI: { model: "gpt-5.2", endpointUrl: "/api/inderun/openai-responses", auth: "none" }
});

const result = await inderun.run({
  schemaVersion: "1.0",
  task: { kind: "text_to_text" },
  prompt: "Write a one-sentence summary of IndeRun."
});
```

If you are using IndeRun in an app, start with the package README that matches your platform:

- `@independo/inderun-web`
- `@independo/capacitor-inderun`
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
