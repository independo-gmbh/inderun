# IndeRun

<p align="center">
  <a href="https://github.com/independo-gmbh/inderun/actions/workflows/javascript.yml"><img alt="JavaScript" src="https://github.com/independo-gmbh/inderun/actions/workflows/javascript.yml/badge.svg?branch=dev"></a>
  <a href="https://github.com/independo-gmbh/inderun/actions/workflows/rust.yml"><img alt="Rust" src="https://github.com/independo-gmbh/inderun/actions/workflows/rust.yml/badge.svg?branch=dev"></a>
  <a href="https://github.com/independo-gmbh/inderun/actions/workflows/swift.yml"><img alt="Swift" src="https://github.com/independo-gmbh/inderun/actions/workflows/swift.yml/badge.svg?branch=dev"></a>
  <a href="https://github.com/independo-gmbh/inderun/actions/workflows/android.yml"><img alt="Android" src="https://github.com/independo-gmbh/inderun/actions/workflows/android.yml/badge.svg?branch=dev"></a>
  <a href="https://github.com/independo-gmbh/inderun/actions/workflows/capacitor.yml"><img alt="Capacitor Plugin" src="https://github.com/independo-gmbh/inderun/actions/workflows/capacitor.yml/badge.svg?branch=dev"></a>
</p>

<p align="center">
  <a href="https://www.npmjs.com/package/@independo/inderun-web"><img alt="npm: @independo/inderun-web" src="https://img.shields.io/npm/v/@independo/inderun-web?logo=npm&label=inderun-web"></a>
  <a href="https://central.sonatype.com/artifact/app.independo.inderun/inderun-kotlin"><img alt="Maven Central: app.independo.inderun:inderun-kotlin" src="https://img.shields.io/maven-central/v/app.independo.inderun/inderun-kotlin?logo=apachemaven&label=inderun-kotlin"></a>
  <a href="https://github.com/independo-gmbh/inderun/releases"><img alt="Swift Package Manager" src="https://img.shields.io/github/v/release/independo-gmbh/inderun?logo=swift&label=SwiftPM"></a>
</p>

<p align="center">
  <a href="./LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue"></a>
</p>

IndeRun is an open-source AI execution framework that gives applications one unified API for running tasks across
on-device, edge, and cloud providers. It ships native SDKs for **web, iOS, and Android** with a shared contract and
consistent, deterministic behavior.

The project is organized around a few stable ideas:

- `run()` is the current public execution path.
- Routing is deterministic and based on request constraints plus host capability snapshots.
- Provider behavior is normalized so apps do not need provider-specific branching in their own code.
- Secrets stay out of request payloads and are referenced through `authContextRef`.

## Status

IndeRun is currently focused on Mode 1 `run()` execution for `text_to_text`. Streaming and realtime sessions are
planned (Milestone 2) but not yet implemented; the shipped surface is request/response execution. Every platform can
always use the OpenAI-compatible **cloud** provider; **on-device** execution is used automatically by routing when the
device supports it (or forced with a `localRequired` privacy constraint).

## Platforms

### Web (TypeScript)

**Requirements:** Node 24+ (for tooling/SSR) or a modern browser (ES2022 + WebAssembly).

Install — this pulls in `@independo/inderun-contracts` and `@independo/inderun-route-core-wasm` automatically:

```sh
pnpm add @independo/inderun-web
```

Quick start:

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

> Browser apps must route OpenAI calls through a same-origin proxy that keeps the key server-side — never ship
> provider credentials to the browser.

### iOS / macOS (Swift)

**Requirements:**

- SDK: iOS 15+ / macOS 12+, Swift 5.9+ (Swift Package Manager).
- On-device provider (Apple Foundation Models): an Apple Intelligence–capable device running a FoundationModels-supported
  OS (iOS 26+ / macOS 26+). Availability is checked at runtime; IndeRun falls back to the cloud provider when it is
  unavailable. **No special Info.plist entitlement is required** for on-device execution.

Install via Swift Package Manager (consumed by URL + git tag). `from:` is a **lower bound** —
SwiftPM resolves to the latest compatible release, so this does not need updating per release:

```swift
.package(url: "https://github.com/independo-gmbh/inderun.git", from: "0.1.0")
// products: IndeRun, IndeRunCore, IndeRunContracts, IndeRunAppleProviders, IndeRunOpenAIProviders
```

Quick start — on-device by default:

```swift
import IndeRunSwift
import IndeRunCore
import IndeRunAppleProviders

let hostServices = DefaultHostServices.make()
// makeDefaultRegistry() registers the on-device Apple Foundation Models provider.
let registry = try AppleProviderRegistryFactory.makeDefaultRegistry()
let inderun = IndeRun(registry: registry, hostServices: hostServices)

let result = try await inderun.run(request: TaskRequest(
    prompt: "Translate 'Hello' to Spanish",
    constraints: TaskRequestConstraints(privacy: .localRequired)
))
```

> Need cloud execution too? Register the OpenAI-compatible provider from
> `IndeRunOpenAIProviders` — see the [iOS SDK README](ios/IndeRun/README.md) and the
> [provider model](docs/architecture/providers.md).

### Android (Kotlin)

**Requirements:**

- SDK: Android 8.0+ (minSdk 26), JDK 17.
- On-device provider (ML Kit GenAI): a device with on-device generative-AI support (AICore / Gemini Nano). Availability
  (available / downloadable / unavailable) is checked at runtime; IndeRun falls back to the cloud provider when it is
  unavailable.

Add the required permissions to your `AndroidManifest.xml` — needed for cloud execution and for downloading/checking the
on-device model:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
```

Install via Gradle (Maven Central) — `latest.release` resolves to the newest published version:

```kotlin
implementation("app.independo.inderun:inderun-kotlin:latest.release")
```

> For reproducible builds, pin an explicit version instead — the Maven Central badge above shows the current release.

Quick start — on-device by default:

```kotlin
// initialize() registers the ML Kit GenAI on-device provider.
val indeRun = IndeRun.initialize(this) // `this` is a Context

// run() is a suspend function — call it from a coroutine.
val result = indeRun.run(
    TaskRequest(
        schemaVersion = SchemaVersion.V1_0,
        prompt = "Translate 'Hello' to Spanish",
        task = TaskRequestTask(), // defaults to text_to_text
        constraints = TaskRequestConstraints(privacy = PrivacyEnum.LocalRequired),
    )
)
```

> Need cloud execution too? Register the OpenAI-compatible provider from
> `inderun-openai-providers` — see the [Kotlin SDK README](android/inderun-kotlin/README.md)
> and the [provider model](docs/architecture/providers.md).

### Capacitor (hybrid apps)

A thin Capacitor bridge (`@independo/capacitor-inderun`) delegates to the native iOS and Android SDKs. It is not yet
published to a registry — it will move to a dedicated, SwiftPM-only repository. Until then it lives in this monorepo
under `packages/capacitor-inderun`.

## Minimum system requirements

| Platform     | SDK minimum                                    | On-device local model                                  |
| ------------ | ---------------------------------------------- | ------------------------------------------------------ |
| Web          | Node 24+ / modern browser (ES2022 + WASM)      | — (cloud provider only)                                |
| iOS / macOS  | iOS 15+ / macOS 12+, Swift 5.9+                | Apple Intelligence device, iOS 26+ / macOS 26+         |
| Android      | Android 8.0+ (API 26), JDK 17                  | Device with AICore / Gemini Nano support               |

The OpenAI-compatible cloud provider is available on every platform. On-device execution additionally requires the
capabilities above and is selected automatically by routing.

## Credentials & security

Never place raw API keys in a `TaskRequest`. Providers resolve credentials from secure platform storage via
`authContextRef`. For web, keep the key server-side behind a proxy endpoint.

## Packages

| Package                                    | Registry                    |
| ------------------------------------------ | --------------------------- |
| `@independo/inderun-web`                   | npm                         |
| `@independo/inderun-contracts`             | npm (shared contracts)      |
| `@independo/inderun-route-core-wasm`       | npm (routing core, WASM)    |
| `app.independo.inderun:inderun-kotlin` (+ modules) | Maven Central       |
| `IndeRun` (Swift products)                 | Swift Package Manager (tag) |

## Core Docs

- [Project brief](docs/architecture/technical-brief.md)
- [Architecture overview](docs/architecture/architecture.md)
- [Provider model](docs/architecture/providers.md)
- [CI behavior](docs/ci.md)
- [Releases & publishing](docs/release.md)
- [Contributor workflow and build commands](CONTRIBUTING.md)
- [Agent instructions](AGENTS.md)

## License

MIT. See `LICENSE`.

## Sponsorship & Development

This project is sponsored by [netidee](https://www.netidee.at/inderun) and developed
by [Independo GmbH](https://www.independo.app).
