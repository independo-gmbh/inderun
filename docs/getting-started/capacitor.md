---
slug: docs/getting-started/capacitor
title: "Capacitor quickstart: on-device AI"
description: "Install @independo/capacitor-inderun, check what the device can run and execute a local-only text task on Apple Foundation Models or Gemini Nano."
sidebar:
  order: 1
---

## What you will have

A Capacitor app that runs one text task on the device's own model, or shows why it can't. No API keys, no server.

<!-- version:capacitor-version -->
Version: `@independo/capacitor-inderun` **1.2.0**, which includes IndeRun 0.4.0. The examples on this page are type-checked against it (2026-11-10).
<!-- /version -->

## Before you start

> [!NOTE]
> You need Capacitor 8, Node 24 or newer, Xcode 26 for Apple Foundation Models, and Android Studio with `compileSdk` 37, Android Gradle plugin (AGP) 9.1 or newer and the Kotlin Gradle plugin 2.4.10. Test on a **physical** device: results from simulators and emulators don't tell you what a real device can run.
>
> The install floors (iOS 16, Android 8.0 / API 26) are not the model requirements. A device can run your app and still have no eligible on-device model. See [Compatibility and requirements](../platforms/compatibility.md).

## Install

<!-- version:capacitor-install -->
```sh
npm install @independo/capacitor-inderun@1.2.0 @capacitor/core@8
```
<!-- /version -->

With pnpm, use `pnpm add` with the same two packages. Don't sync yet: set the iOS and Android values below first.

**iOS.** Set the deployment target to 16.0 in your Xcode project _before_ you run `npx cap sync ios`. The Capacitor CLI reads that value to generate `CapApp-SPM/Package.swift`; syncing with the default leaves a manifest below the plugin's floor, and the build fails with:

> requires minimum platform version 16.0 for the iOS platform, but this target supports 15.0

**Android.** Three settings in your app, none of which `npx cap add android` sets for you:

| Setting | Value | Failure if unset |
| --- | --- | --- |
| `compileSdkVersion` in `android/variables.gradle` | `37` | _requires libraries and applications that depend on it to compile against version 37 or later_ |
| Android Gradle plugin | `9.1.0` or newer (Gradle 9.x) | _requires Android Gradle plugin 9.1.0 or higher_ |
| `org.jetbrains.kotlin:kotlin-gradle-plugin:2.4.10` on the app's `buildscript` classpath | n/a | _Module was compiled with an incompatible version of Kotlin … metadata is 2.4.0, expected version is 2.2.0_ |

The plugin README has the full list, including `minSdkVersion` 26 and the `buildscript` snippet for the Kotlin plugin: [Host Project Requirements](https://github.com/independo-gmbh/capacitor-inderun/blob/v1.2.0/README.md#host-project-requirements) (pinned to v1.2.0). Failures are also listed in [Troubleshooting](../guides/troubleshooting.md).

Then sync the native projects:

```sh
npx cap sync
```

## Check the device

Ask what the device can run before you run anything:

<!-- snippet:capacitor-check-capabilities -->
```ts
import { createIndeRunCapacitor } from "@independo/capacitor-inderun";

const ai = createIndeRunCapacitor();

for (const provider of await ai.checkCapabilities()) {
  const { available, reason } = provider.capabilities;
  console.log(
    provider.providerId,
    provider.descriptor.type, // "local" or "cloud"
    available ? "available" : `unavailable: ${reason}`
  );
}
```
<!-- /snippet -->

`checkCapabilities()` returns one entry per registered provider. On iOS the on-device provider is Apple Foundation Models (`apple_foundation_models`); on Android it is ML Kit GenAI (`android_mlkit_genai`). On an eligible device the log line for that provider reads like this:

```text
apple_foundation_models local available
```

On a device without an eligible model, `available` is `false` and `reason` carries the platform's explanation:

```text
apple_foundation_models local unavailable: <reason reported by the platform>
```

The exact reason text comes from the platform. Typical causes are a device that isn't eligible, Apple Intelligence turned off, a model that isn't ready yet (iOS), or Gemini Nano not supported or not yet downloaded (Android). This output has not been verified on a device for this page.

## Run local-only

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

No cloud provider is configured, so `local_required` can only succeed on the device. If no on-device model is eligible, the request is refused before anything runs.

## Read the outcome

<!-- snippet:capacitor-read-outcome -->
```ts
import { createIndeRunCapacitor, type IndeRunError } from "@independo/capacitor-inderun";

const ai = createIndeRunCapacitor();

try {
  const result = await ai.run({
    schemaVersion: "1.0",
    task: { kind: "text_to_text" },
    prompt: "Rewrite in plain language: Your appointment has been rescheduled.",
    constraints: { privacy: "local_required" }
  });
  console.log(result.output.text);
  console.log(result.provenance?.providerId, result.provenance?.locality); // locality: "on_device"
} catch (error) {
  const refusal = error as IndeRunError;
  if (refusal.errorClass === "CapabilityMismatch") {
    // Refused before anything ran. `details.rejectedProviders` lists each
    // registered provider and the reason codes it was skipped for.
    console.warn(refusal.message, refusal.details?.rejectedProviders);
  } else {
    throw error;
  }
}
```
<!-- /snippet -->

**Success.** `output.text` is the result. `provenance.providerId` names the provider that ran the task and `provenance.locality` is `"on_device"`.

**Refusal.** `run()` rejects with an `IndeRunError` whose `errorClass` is `"CapabilityMismatch"` and whose message reads like `No eligible local provider found for task 'text_to_text'.` The error's `details.rejectedProviders` lists each registered provider with the reason codes it was skipped for, for example `capability_unavailable` or `privacy_constraint`. The plugin forwards `details` from the native side in its source; treat the exact shape on your device as something to confirm in your own run.

A refusal is correct behaviour, not a setup error: the device cannot run the task under your rule, and IndeRun refused before any provider ran. (`provenance.routeRejections` exists only on a successful result, where it lists providers skipped on the way.)

## Next

- Build the [local-only starter app](example.md) and run it on a device.
- Allow a cloud route that you configure yourself: [When on-device AI is unavailable](../concepts/routing-and-privacy.md).
- Build or model problems: [Troubleshooting](../guides/troubleshooting.md).
