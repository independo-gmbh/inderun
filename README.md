# IndeRun

IndeRun is an open, reusable AI execution library that lets applications run the same AI tasks through **one unified
interface**, independent of where the model runs (**on-device**, **embedded runtime**, **edge**, **cloud**).

It will support:

- **Mode 1: Run** — request/response (`run()`)
- **Mode 2: Stream** — unified event stream (`stream()` + `events()` + `cancel()`)
- **Mode 3: Session** — bidirectional realtime (`openSession()` + `send()` + `events()` + `interrupt()` + `close()`)

**Implementation not planned for now:**

- **Mode 4: Submit/Jobs** — we keep the architecture seams ready, but do not build job/queue infrastructure now.

---

## Packages & SDKs

### JavaScript/TypeScript (npm, under `@independo/…`)

- `@independo/inderun-types` — canonical schema (JSON Schema) + generated TS types + validators
- `@independo/inderun-web` — Web SDK (public API + web HostServices + web providers)
- `@independo/capacitor-inderun` — Capacitor facade/bridge (thin wrapper delegating to web + native SDKs)

### Native SDKs

- **iOS**: IndeRun Swift Package (Swift-first API + HostServices + core engine)
- **Android**: IndeRun Android SDK (Kotlin-first API + HostServices + core engine)

> Capacitor is **not** a peer runtime — it is a thin wrapper that exposes a JS API and delegates to
`@independo/inderun-web` (web) or the native SDKs (iOS/Android).

---

## Documentation

- Architecture: `docs/architecture/inderun-architecture.md`

---

## Repository layout (high-level)

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

> Add concrete commands once the build tooling is finalized (pnpm/npm, Gradle, SwiftPM, etc.).

---

## Design principles (quick)

- **Deterministic routing** given `(request + policy + capabilities snapshot + provider descriptors)`
- **Unified event model** separating user-visible output from mechanics (tools/reasoning)
- **Standard cancellation guarantee** (no events after cancel; terminal `cancelled`)
- **Provider capability metadata** drives routing (streaming/realtime/tools/limits/transport)
- **Secrets never in requests** — credentials via secure storage slots (`authContextRef`)

---

## License

TBD. (Choose an OSI-approved license for OSS components; keep provider-specific integrations appropriately licensed.)
