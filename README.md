<h1 align="center">
  <a href="https://inderun.dev">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://inderun.dev/brand/inderun-logo-dark.svg">
      <img alt="IndeRun" src="https://inderun.dev/brand/inderun-logo-light.svg" width="360">
    </picture>
  </a>
</h1>

<p align="center">
  <a href="https://github.com/independo-gmbh/inderun/actions/workflows/javascript.yml"><img alt="JavaScript" src="https://github.com/independo-gmbh/inderun/actions/workflows/javascript.yml/badge.svg?branch=dev"></a>
  <a href="https://github.com/independo-gmbh/inderun/actions/workflows/rust.yml"><img alt="Rust" src="https://github.com/independo-gmbh/inderun/actions/workflows/rust.yml/badge.svg?branch=dev"></a>
  <a href="https://github.com/independo-gmbh/inderun/actions/workflows/swift.yml"><img alt="Swift" src="https://github.com/independo-gmbh/inderun/actions/workflows/swift.yml/badge.svg?branch=dev"></a>
  <a href="https://github.com/independo-gmbh/inderun/actions/workflows/android.yml"><img alt="Android" src="https://github.com/independo-gmbh/inderun/actions/workflows/android.yml/badge.svg?branch=dev"></a>
</p>

<p align="center">
  <a href="https://www.npmjs.com/package/@independo/inderun-web"><img alt="npm: @independo/inderun-web" src="https://img.shields.io/npm/v/@independo/inderun-web?logo=npm&label=inderun-web"></a>
  <a href="https://central.sonatype.com/artifact/app.independo.inderun/inderun-kotlin"><img alt="Maven Central: app.independo.inderun:inderun-kotlin" src="https://img.shields.io/maven-metadata/v?metadataUrl=https%3A%2F%2Frepo1.maven.org%2Fmaven2%2Fapp%2Findependo%2Finderun%2Finderun-kotlin%2Fmaven-metadata.xml&filter=%21*-*&logo=apachemaven&label=inderun-kotlin"></a>
  <a href="https://github.com/independo-gmbh/inderun/releases"><img alt="Swift Package Manager" src="https://img.shields.io/github/v/release/independo-gmbh/inderun?logo=swift&label=SwiftPM"></a>
</p>

<p align="center">
  <a href="./LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue"></a>
  <a href="https://inderun.dev/docs"><img alt="Docs: inderun.dev" src="https://img.shields.io/badge/docs-inderun.dev-A0B3FF"></a>
</p>

**On-device AI for the devices your users actually have.**

IndeRun runs text tasks on the model a device already has — Apple Foundation Models on iOS, Gemini Nano (ML Kit GenAI)
on Android, a browser-managed model or your own ONNX model on the web — through one API for Capacitor, TypeScript,
Swift and Kotlin. Each request says where it may run: `local_required` stays on the device or is refused before
anything executes; a cloud route is used only if your app configures one and the request permits it. Every result
reports what ran.

Built and maintained by [Independo](https://www.independo.app) for its accessibility apps. Supported by
[netidee](https://www.netidee.at/inderun). MIT licensed.

**[Documentation](https://inderun.dev/docs)** ·
[Capacitor quickstart](https://inderun.dev/docs/getting-started/capacitor) ·
[Compatibility](https://inderun.dev/docs/platforms/compatibility) ·
[Releases](https://github.com/independo-gmbh/inderun/releases/latest)

## Example: on-device only, refused otherwise

<!-- snippet:capacitor-local-only -->
```ts
import { createIndeRunCapacitor } from "@independo/capacitor-inderun";

// iOS and Android register the platform's on-device model automatically.
// No cloud provider is configured, so no request can be routed to the cloud.
const ai = createIndeRunCapacitor();

try {
  const result = await ai.run({
    schemaVersion: "1.0",
    task: { kind: "text_to_text" },
    prompt: "Rewrite in plain language: Your appointment has been rescheduled.",
    constraints: { privacy: "local_required" }
  });
  console.log(result.output.text, result.provenance?.providerId);
} catch (error) {
  // No eligible on-device model (unsupported device, Apple Intelligence off,
  // Gemini Nano not downloaded, …): refused before execution, with reasons.
  console.warn(error);
}
```
<!-- /snippet -->

Want a cloud route when the device can't run the task? That is opt-in and server-side: see
[Routing, privacy and fallback](https://inderun.dev/docs/concepts/routing-and-privacy).

## Read text aloud

The Web, Swift, Kotlin and Capacitor SDKs share one call shape: `listVoices()` reads the voice catalog, `speak()` plays and returns
a handle with `cancel()`, and `generateSpeech()` returns retrievable audio. System voices are opt-in (register
`systemSpeech` on the Web and in the Capacitor plugin, `AppleSystemSpeechProvider` in Swift,
`AndroidSystemSpeechProvider` in Kotlin).

<!-- snippet:web-speak -->
```ts
import { createIndeRunWeb, listVoices, speak } from "@independo/inderun-web";

const inderun = createIndeRunWeb({ systemSpeech: {} });

const voices = await listVoices(inderun, { locale: "de-DE" });
console.log(voices.map((voice) => voice.name));

const playback = await speak(inderun, { text: "Ihr Termin wurde verschoben.", locale: "de-DE" });
document.querySelector("#stop")?.addEventListener("click", () => playback.cancel());

const { outcome, provenance } = await playback.result;
console.log(outcome, provenance?.locality); // locality: "unknown" in a browser
```
<!-- /snippet -->

- Android enforces `local_required` through each voice's network flag. Installed Apple voices are assumed local, because
  the API exposes no network flag. Browsers cannot confirm locality, so `local_required` speech is always refused on the
  web.
- `generateSpeech()` returns WAV on iOS and Android and is refused on the web, where speech only plays.
- A voice that is missing fails the request rather than being substituted.

The full walkthrough is in the [speech guide](https://inderun.dev/docs/guides/speech); per-platform snippets are in the
[Web](packages/inderun-web/README.md#speech), [Swift](ios/IndeRun/README.md#speech) and
[Kotlin](android/inderun-kotlin/README.md#speech) READMEs.

## Install

<!-- version:install-table -->
| You build with | Install (tested set) |
| --- | --- |
| Capacitor 8 | `npm install @independo/capacitor-inderun@1.3.0` |
| Web / TypeScript | `pnpm add @independo/inderun-web@0.5.0` |
| Swift (SwiftPM) | `.package(url: "https://github.com/independo-gmbh/inderun.git", exact: "0.5.0")` |
| Kotlin (Maven Central) | `implementation("app.independo.inderun:inderun-kotlin:0.5.0")` |
<!-- /version -->

Each row links to its guide: [Capacitor](https://inderun.dev/docs/getting-started/capacitor) (see the
[host project requirements](https://github.com/independo-gmbh/capacitor-inderun/blob/v1.3.0/README.md#host-project-requirements)),
[Web](packages/inderun-web/README.md), [Swift](ios/IndeRun/README.md) and [Kotlin](android/inderun-kotlin/README.md).

## Supported platforms and limitations

<!-- version:platforms-table -->
| You build with | Package (tested set) | Installs on | On-device model, checked at runtime |
| --- | --- | --- | --- |
| Capacitor 8 | `@independo/capacitor-inderun` 1.3.0 (wraps IndeRun 0.5.0) | iOS 16+, Android 8.0 (API 26)+, modern browsers | iOS 26+ on an Apple Intelligence device with it turned on; Android devices with AICore/Gemini Nano; Chrome Prompt API on desktop Chrome when `systemModel` is configured |
| Web / TypeScript | `@independo/inderun-web` 0.5.0 | ES2022 + WebAssembly (Node 24+ for tooling) | Chrome Prompt API; ONNX Runtime Web with a model you supply |
| Swift | `IndeRun` 0.5.0 (SwiftPM) | iOS 16+, macOS 14+, Swift 5.9+ | Apple Foundation Models (iOS/macOS 26+) |
| Kotlin | `app.independo.inderun:inderun-kotlin` 0.5.0 | Android 8.0 (API 26)+, JDK 17 | ML Kit GenAI / Gemini Nano |
<!-- /version -->

- Installing IndeRun does not make a device capable of on-device AI. Many devices that meet the install floor have no
  eligible model. Plan for a refusal or a permitted cloud route.
- Text: `run()` and `stream()`. Speech, in the Web, Swift, Kotlin and Capacitor SDKs: `speak()`, `generateSpeech()` and
  `listVoices()` with each platform's system voices (playback only on the web; playback or retrievable audio on iOS and
  Android). Realtime sessions are not implemented.
- In browsers, on-device providers answer whole requests only, so a `local_required` _stream_ is refused.
- Offline use works only where an on-device model is installed and ready. We don't claim it for every device.
- Capacitor apps need newer native toolchains than a fresh Capacitor project (Android compileSdk 37, Android Gradle
  Plugin 9.1+, Kotlin Gradle plugin 2.4.21; iOS deployment target 16). See the plugin README.

The Capacitor bridge is published as
[`@independo/capacitor-inderun`](https://www.npmjs.com/package/@independo/capacitor-inderun); its source lives in
[independo-gmbh/capacitor-inderun](https://github.com/independo-gmbh/capacitor-inderun). Both `run()` and `stream()`
cross the bridge. The bridge owns transport only: it does not plan routes, retry, or apply fallback, and where events
are lost in transit it reports a transport failure rather than inventing an ending.

## Status

IndeRun ships two execution modes for `text_to_text`: Mode 1 `run()` (request/response) and Mode 2 `stream()`
(incremental output with cancellation), both implemented in all three SDKs. Realtime sessions remain planned but
unimplemented. Every platform can register an OpenAI-compatible **cloud** provider, which you configure and your request must permit;
**on-device** execution is chosen by routing when the device supports it (or required with a `local_required` privacy
constraint). See
[GitHub Milestones](https://github.com/independo-gmbh/inderun/milestones) for current roadmap status.

Not every provider streams, so whether a stream request can be served depends on the registered providers and is
decided at routing time rather than discovered partway through. [Streaming (Mode 2)](docs/streaming.md) is the full
contract — event types, ordering, cancellation, and what each provider does and does not report.

`generateText()` and `streamText()` are the primary API: familiar prompt-and-options calls that each compile to one
canonical `TaskRequest`. `run()` and `stream()` stay public as the advanced, task-shaped execution API — reach for them
when you build requests programmatically or need the full event sequence. Both layers share one engine, so routing,
cancellation, and errors behave identically. When to use which, and how model profiles work, is in [API layering](docs/architecture/api-layering.md) and
[Routing, privacy and fallback](https://inderun.dev/docs/concepts/routing-and-privacy).

`speak()`, `generateSpeech()` and `listVoices()` are the same idea for text-to-speech: `speak()` plays through the device
and hands back a completion and a `cancel()`, `generateSpeech()` returns retrievable audio where a provider can produce
it, and `listVoices()` reads the live voice catalog.

## How it decides where a task runs

Placement is a property of the request, not of the call site. `constraints.privacy` says how strict you are:

| `constraints.privacy`       | Effect on routing                                                                                                                                          |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `local_required`            | Every provider whose data leaves the device is **rejected**, so no cloud route is possible. If none remains, the request is refused.                        |
| `local_preferred`           | Nothing is rejected. On-device providers are **ranked first**; a separately configured and permitted cloud target stays in the chain.                        |
| `cloud_allowed` _(default)_ | No preference from privacy; the default ranking still prefers on-device providers over cloud ones.                                                            |
| `cloud_required`            | Non-cloud providers are rejected.                                                                                                                            |

Capability is checked too: a provider that cannot serve the task on this host right now is rejected before anything is
attempted, and the refusal names every rejected provider with a normalized reason code. Ordering among the survivors is
deterministic for a fixed request and capability snapshot. The full model — `constraints.cloud` and rejection codes — is
in [Routing, privacy and fallback](https://inderun.dev/docs/concepts/routing-and-privacy) and the
[architecture overview](docs/architecture/architecture.md#placement-constraints). Model profiles are covered in
[API layering](docs/architecture/api-layering.md#model-profiles).

## Privacy

IndeRun sends no usage data to Independo. The SDK has a `telemetry` hook and a `telemetry` field on results so _your
app_ can observe executions locally. The default handler discards events. A cloud provider you configure receives the
requests you route to it, under its own terms.

## Credentials & security

Never place raw API keys in a `TaskRequest`. Providers resolve credentials from secure platform storage via
`authContextRef`, so a secret never enters a request payload and never sits in source.

`authContextRef` does not make a key safe to ship, and it is not meant to. Anything a browser or an installed app can
read, someone with that browser or app can read — a developer-owned API key does not become safe by being referenced
indirectly. Use `authContextRef` for credentials that legitimately live on the device: a per-user or per-install token
your backend issued. For a key **you** own, put it behind a backend you control and point the provider's endpoint at
that. The Web SDK enforces this by refusing the public OpenAI and OpenRouter endpoints unless you opt out explicitly for a controlled
environment; on iOS and Android it is a convention, because a native app can reach any endpoint it likes.

## Ecosystem

- **OpenRouter** — reach many model vendors through one cloud target with the OpenAI-compatible provider. See
  [OpenRouter](docs/openrouter.md).
- **Reference demo** — [`packages/inderun-web-demo`](packages/inderun-web-demo/README.md) simplifies text with
  `generateText()` or `streamText()`, runs on the device first when the browser can, uses a cloud route only
  when the chosen privacy allows it, and shows the run's provenance.

## Packages

| Package                                    | Registry                    |
| ------------------------------------------ | --------------------------- |
| `@independo/inderun-web`                   | npm                         |
| `@independo/inderun-contracts`             | npm (shared contracts)      |
| `@independo/inderun-route-core-wasm`       | npm (routing core, WASM)    |
| `app.independo.inderun:inderun-kotlin` (+ modules) | Maven Central       |
| `IndeRun` (Swift products)                 | Swift Package Manager (tag) |

## Documentation

- [inderun.dev/docs](https://inderun.dev/docs) — start here
- [Capacitor quickstart](https://inderun.dev/docs/getting-started/capacitor)
- [Routing, privacy and fallback](https://inderun.dev/docs/concepts/routing-and-privacy)
- [Architecture](https://inderun.dev/docs/concepts/architecture)
- [Troubleshooting](https://inderun.dev/docs/guides/troubleshooting)
- [Speech guide](https://inderun.dev/docs/guides/speech)
- [Compatibility](https://inderun.dev/docs/platforms/compatibility)
- [TypeScript API reference](https://inderun.dev/docs/api/typescript)

Reference in this repository: [Project brief](docs/architecture/technical-brief.md) ·
[Architecture overview](docs/architecture/architecture.md) · [Provider model](docs/architecture/providers.md) ·
[Public API layering](docs/architecture/api-layering.md) · [Streaming (Mode 2)](docs/streaming.md) ·
[Migration guide](docs/migration.md) · [ONNX Runtime provider family](docs/architecture/onnx-runtime-provider-family.md) ·
[Streaming conformance](docs/streaming-conformance.md) · [Speech conformance](docs/speech-conformance.md) ·
[System speech verification record](docs/verification/system-speech.md) ·
[Neural speech preparation tool](tools/neural-speech/README.md)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the contributor workflow and build commands. CI behavior is in
[docs/ci.md](docs/ci.md) and releases in [docs/release.md](docs/release.md).

## License

MIT. See `LICENSE`.

## Sponsorship & Development

This project is sponsored by [netidee](https://www.netidee.at/inderun) and developed
by [Independo GmbH](https://www.independo.app).

Explore more [open-source tools and research from Independo](https://www.independo.app/open-source).
