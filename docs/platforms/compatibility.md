---
slug: docs/platforms/compatibility
title: "Compatibility and requirements"
description: "Which IndeRun packages work together, the install floor for each platform, and the separate requirements for Apple Foundation Models and Gemini Nano."
sidebar:
  order: 1
---

IndeRun has two kinds of requirements. The **install floor** is what lets your app build and start. The **model requirement** is what lets a device run a task on its own model. A device can meet the first and not the second, which is why IndeRun checks at runtime and refuses when no eligible model is there.

<!-- version:tested-set -->
Tested set: IndeRun **0.5.0-rc.17** (`@independo/inderun-web`, SwiftPM, Maven) and `@independo/capacitor-inderun` **1.2.0**, which wraps IndeRun 0.4.0. Examples type-checked against these on 2026-11-10.
<!-- /version -->

## Supported platforms and limitations

<!-- version:platforms-table -->
| You build with | Package (tested set) | Installs on | On-device model, checked at runtime |
| --- | --- | --- | --- |
| Capacitor 8 | `@independo/capacitor-inderun` 1.2.0 (wraps IndeRun 0.4.0) | iOS 16+, Android 8.0 (API 26)+, modern browsers | iOS 26+ on an Apple Intelligence device with it turned on; Android devices with AICore/Gemini Nano; Chrome Prompt API on desktop Chrome when `systemModel` is configured |
| Web / TypeScript | `@independo/inderun-web` 0.5.0-rc.17 | ES2022 + WebAssembly (Node 24+ for tooling) | Chrome Prompt API; ONNX Runtime Web with a model you supply |
| Swift | `IndeRun` 0.5.0-rc.17 (SwiftPM) | iOS 16+, macOS 14+, Swift 5.9+ | Apple Foundation Models (iOS/macOS 26+) |
| Kotlin | `app.independo.inderun:inderun-kotlin` 0.5.0-rc.17 | Android 8.0 (API 26)+, JDK 17 | ML Kit GenAI / Gemini Nano |
<!-- /version -->

Versions to install:

<!-- version:install-table -->
| You build with | Install (tested set) |
| --- | --- |
| Capacitor 8 | `npm install @independo/capacitor-inderun@1.2.0` |
| Web / TypeScript | `pnpm add @independo/inderun-web@0.5.0-rc.17` |
| Swift (SwiftPM) | `.package(url: "https://github.com/independo-gmbh/inderun.git", exact: "0.5.0-rc.17")` |
| Kotlin (Maven Central) | `implementation("app.independo.inderun:inderun-kotlin:0.5.0-rc.17")` |
<!-- /version -->

Capacitor toolchain: Capacitor 8, Xcode 26, `compileSdk` 37, Android Gradle plugin 9.1+, Kotlin Gradle plugin 2.4.10, iOS deployment target 16.0. The exact settings and failure strings are in the [Capacitor quickstart](../getting-started/capacitor.md#install) and the plugin's [Host Project Requirements](https://github.com/independo-gmbh/capacitor-inderun/blob/v1.2.0/README.md#host-project-requirements).

Kotlin SDK host requirements (`compileSdk`, Android Gradle plugin, Gradle, Kotlin Gradle plugin, JDK), each with the build error it prevents and the releases it applies to: [Android host requirements](../../android/README.md#host-requirements).

The OpenAI-compatible cloud provider is available on every platform, but it is a route you configure and allow; it is never used for `local_required` requests.

Usage guides for each SDK: [Web](../../packages/inderun-web/README.md), [Swift](../../ios/IndeRun/README.md), [Kotlin](../../android/inderun-kotlin/README.md).

### Honest limitations

- Whether an on-device model is available depends on the device, its settings and the model's state. IndeRun reports it; it cannot create it.
- No claim is made that tasks work offline in general. A model that is not downloaded or not ready is unavailable.
- There is no edge provider today, and IndeRun does not fall back to a cloud provider automatically: a cloud route exists only if your app configured one and the request's rule permits it.
- Realtime sessions (`openSession()`) are not implemented. `run()` and `stream()` are; not every provider streams.
- The Capacitor plugin release listed above has no speech API. Speech is available through the Web, Swift and Kotlin SDKs.
- IndeRun is an execution layer. It is not a model, and not an accessibility certification.

## What each platform needs, checked in one call

| Platform | On-device model | Why it may be unavailable |
| --- | --- | --- |
| iOS | Apple Foundation Models | Device not eligible, Apple Intelligence turned off, model not ready yet. See [Apple's availability reasons](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.enum). |
| Android | Gemini Nano via ML Kit GenAI | Device unsupported by AICore (the API is also not supported with an unlocked bootloader), Gemini Nano not downloaded, app not in the foreground, per-app inference quota. See [ML Kit GenAI overview](https://developers.google.com/ml-kit/genai) and [Prompt API: get started](https://developers.google.com/ml-kit/genai/prompt/android/get-started). |
| Web | Browser-managed model (Chrome Prompt API) | Chrome documents the Prompt API for desktop Chrome, with OS, storage and hardware requirements; other browsers don't implement it yet. Model download pending or unavailable. See [Chrome's Prompt API](https://developer.chrome.com/docs/ai/prompt-api). |

IndeRun turns these into one capability check and one routing decision. See [When on-device AI is unavailable](../concepts/routing-and-privacy.md).

## Speech

Speech is a separate capability with its own rules; see [Read text aloud](../guides/speech.md).

| Platform | Playback (`speak()`) | Returned audio (`generateSpeech()`) | How locality is decided |
| --- | --- | --- | --- |
| iOS | Yes, `apple_system_speech` | WAV | Installed Apple voices are assumed local, because the API exposes no network flag (the airplane-mode check is pending) |
| Android | Yes, `android_system_speech` | WAV | Enforced per voice through its network flag (`Voice.isNetworkConnectionRequired`); an engine that lists no voices is reported as `voice_locality_unknown` |
| Web | Yes, `web_system_speech` | Refused: playback only | Browsers can't confirm locality, so `local_required` speech is always refused on the web |

A missing voice fails rather than being substituted. No offline-speech claim is made.

## Device records

Observed results on real devices are kept in the repository, not on this page: see [`docs/verification/`](../verification/). That folder is on GitHub only.
