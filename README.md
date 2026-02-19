# IndeRun

IndeRun is an open, reusable AI execution framework that lets applications run the same AI tasks through **one unified
interface**, independent of where execution happens (**on-device**, **embedded runtime**, **edge**, **cloud**).

## Project status

This repository is currently in an **architecture-first phase**. Core design, contracts, and provider strategy are
defined in `docs/architecture/*`; implementation is incremental.

It will support:

- **Mode 1: Run** — request/response (`run()`)
- **Mode 2: Stream** — unified event stream (`stream()` + `events()` + `cancel()`)
- **Mode 3: Session** — bidirectional realtime (`openSession()` + `send()` + `events()` + `interrupt()` + `close()`)

**Implementation not planned for now:**

- **Mode 4: Submit/Jobs** — we keep the architecture seams ready, but do not build job/queue infrastructure now.

---

## Why IndeRun

Teams building AI features often need to choose between privacy, latency, cost, and reliability. IndeRun separates
task execution from provider specifics so applications can:

- call one API surface from app code
- route execution by policy and runtime capabilities
- fallback predictably when preferred providers are unavailable

---

## Packages & SDKs

### JavaScript/TypeScript (npm, under `@independo/…`)

- `@independo/inderun-contracts` — canonical schema (JSON Schema) + generated TS types + validators
- `@independo/inderun-web` — Web SDK (public API + web HostServices + web providers)
- `@independo/capacitor-inderun` — Capacitor facade/bridge (thin wrapper delegating to web + native SDKs)

> Naming note: `@types/*` packages are typically for community-maintained declarations (DefinitelyTyped) for
> packages that do not ship their own types. IndeRun publishes first-party typed packages under `@independo/*`.

### Native SDKs

- **iOS**: IndeRun Swift Package (Swift-first API + HostServices + core engine)
- **Android**: IndeRun Android SDK (Kotlin-first API + HostServices + core engine)

> Capacitor is **not** a peer runtime — it is a thin wrapper that exposes a JS API and delegates to
`@independo/inderun-web` (web) or the native SDKs (iOS/Android).

---

## Documentation

- Technical brief: `docs/architecture/technical-brief.md`
- Architecture: `docs/architecture/architecture.md`
- Providers: `docs/architecture/providers.md`
- Agent entrypoint: `AGENTS.md`

---

## Repository layout (target high-level structure)

```
inderun/
  packages/                 # JS/TS workspace (@independo/*)
  core/                     # shared engine core (routing/policy/orchestrator/events)
  ios/                      # iOS SDK (Swift Package)
  android/                  # Android SDK (Gradle/Maven)
  docs/
    architecture/
  tools/                    # codegen + release automation
```

---

## Development (placeholder)

This repository is designed to support multiple platforms and packaging formats. Typical workflows include:

- schema/type generation (JSON Schema → TS/Swift/Kotlin)
- unit tests for deterministic routing + cancellation semantics
- adapter contract tests (error mapping + event normalization)
- platform integration tests (AsyncStream / Flow / Capacitor event channels)

> Add concrete commands once build tooling is finalized (pnpm/npm, Gradle, SwiftPM, etc.).
> Do not assume or document commands as available until they are checked into this repository.

---

## Design principles (quick)

- **Deterministic routing** given `(request + policy + capabilities snapshot + provider descriptors)`
- **Unified event model** separating user-visible output from mechanics (tools/reasoning)
- **Standard cancellation guarantee** (no events after cancel; terminal `cancelled`)
- **Provider capability metadata** drives routing (streaming/realtime/tools/limits/transport)
- **Secrets never in requests** — credentials via secure storage slots (`authContextRef`)

---

## License

MIT. See `LICENSE`.

---

## Sponsorship & Development

This project is sponsored by [netidee](https://www.netidee.at/inderun) and developed
by [Independo GmbH](https://www.independo.app).
