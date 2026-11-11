---
slug: docs/getting-started/example
title: "Local-first starter app"
description: "Start from the plugin's local-first Capacitor starter: device capabilities, a local-only task that refuses cleanly, and speech with system voices."
sidebar:
  order: 2
---

## What it is

The plugin repository ships a small Capacitor 8 + Vite + TypeScript app to copy when you start your own: [`examples/local-first-starter/`](https://github.com/independo-gmbh/capacitor-inderun/tree/v1.3.0/examples/local-first-starter). It needs no credentials and no server, and nothing it does leaves the device.

It shows three things:

- **What runs on this device.** `checkCapabilities()` lists each provider with its type, whether it is available (and why not), and per-task readiness.
- **A local-only task.** `run()` with `constraints.privacy` set to `"local_required"` shows the answer and where it ran. On a device with no on-device model it shows the refusal instead. That is a correct outcome: the prompt was not sent anywhere else. See [Read the outcome](capacitor.md#read-the-outcome).
- **Speech with system voices.** `speak()` with `systemSpeech: true`, a **Stop** button that calls `cancel()`, and the finish reason once playback has settled. See [Read text aloud](../guides/speech.md).

All of the app's logic is one file, `src/main.ts`. Neural voices are not part of it.

## Prerequisites

- Node 24 and pnpm, and the host requirements from the [Capacitor quickstart](capacitor.md#before-you-start).
- Xcode 26 for iOS, Android Studio for Android. A physical device is the way to see a real result; a browser run (`pnpm dev`) only shows the refusal and the browser's own speech.

## Get it and run it

The starter is not part of the plugin's workspace: it installs the plugin from the repository root. Clone the plugin repository at the tag this site documents, then follow the starter's own README for the install, the one-time native project changes, and the run commands:

<!-- version:capacitor-clone -->
```sh
git clone --branch v1.3.0 https://github.com/independo-gmbh/capacitor-inderun.git
```
<!-- /version -->

The [starter's README](https://github.com/independo-gmbh/capacitor-inderun/blob/v1.3.0/examples/local-first-starter/README.md) is the source for those steps, so they stay matched to the tag. They are the same settings the quickstart lists: iOS deployment target 16.0, compileSdk 37, and the Android build tooling versions.

## Expected result

**On an eligible device**, the capability list shows the on-device provider as available. After you ask, the output shows the answer, the provider id and `locality: on_device`.

**On an unsupported device**, the capability list shows the provider as unavailable with the platform's reason, and asking shows the refusal with each rejected provider and its reason codes. The device cannot run the task under `local_required`, and nothing ran.

**Speak** plays through the device's own voice. On iOS the app owns the audio session: to hear speech with the silent switch on, set the `AVAudioSession` category in your app before calling `speak()`.

## Record your run

If you want a record of what you saw on your device (model, OS version, available or refused, reason codes), see the [device record template](../verification/website-launch-template.md). Please record only what you observed. No device record for this starter is published yet.

## Diagnostic app

For advanced bridge testing, the plugin repository ships a larger [diagnostic example app](https://github.com/independo-gmbh/capacitor-inderun/tree/v1.3.0/example-app) (pinned to v1.3.0).
