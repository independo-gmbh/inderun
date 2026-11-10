---
slug: docs/guides/troubleshooting
title: "Troubleshooting builds and models"
description: "Fix Capacitor build failures (Android Gradle plugin, Kotlin metadata, iOS 16 target) and tell an unavailable model from a refused route or a bridge fault."
sidebar:
  order: 2
---

Each section below names the failure as you see it, then the fix. For why a model can be unavailable, see [When on-device AI is unavailable](../concepts/routing-and-privacy.md); for requirements, see [Compatibility and requirements](../platforms/compatibility.md).

## Capacitor build failures

Your app needs settings that a freshly generated Capacitor app does not set. The plugin README lists them in [Host Project Requirements](https://github.com/independo-gmbh/capacitor-inderun/blob/v1.3.0-dev.1/README.md#host-project-requirements) (pinned to v1.3.0-dev.1).

<!-- version:capacitor-version -->
Version: `@independo/capacitor-inderun` **1.3.0-dev.1**, which includes IndeRun 0.5.0. The examples on this page are type-checked against it (2026-11-11).
<!-- /version -->

### Android: compile against version 37

> requires libraries and applications that depend on it to compile against version 37 or later

Set `compileSdkVersion` to `37` in `android/variables.gradle`. Also set `minSdkVersion` to `26`; if it is lower, the failure is a manifest merger conflict.

### Android: Android Gradle plugin 9.1

> requires Android Gradle plugin 9.1.0 or higher

Use Android Gradle plugin `9.1.0` or newer, with Gradle 9.x.

### Android: Kotlin metadata 2.4.0 versus 2.2.0

> Module was compiled with an incompatible version of Kotlin … metadata is 2.4.0, expected version is 2.2.0

The IndeRun artifacts carry Kotlin 2.4.x metadata, which the Kotlin plugin that AGP brings by default cannot read. Add `org.jetbrains.kotlin:kotlin-gradle-plugin:2.4.10` to your app's `buildscript` classpath in `android/build.gradle`. The README has the snippet.

### Android: proguard-android.txt

AGP 9 rejects `getDefaultProguardFile('proguard-android.txt')`. Switch to `proguard-android-optimize.txt`. This is in the same README section.

### iOS: minimum platform version 16.0

> requires minimum platform version 16.0 for the iOS platform, but this target supports 15.0

Set `IPHONEOS_DEPLOYMENT_TARGET` to `16.0` in your Xcode project **before** you run `npx cap sync ios`. The Capacitor CLI reads that value to generate `CapApp-SPM/Package.swift`. If the manifest was already generated with the default, set the target and sync again.

## The system model is unavailable

A build that succeeds can still have no model to run. `checkCapabilities()` reports `available: false` with a `reason` from the platform; see [Check the device](../getting-started/capacitor.md#check-the-device).

| Platform | Typical causes | What to do |
| --- | --- | --- |
| iOS | Device not eligible, Apple Intelligence turned off, model not ready yet | Check [Apple's availability reasons](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.enum), turn Apple Intelligence on, wait for the model to be ready. Test on a physical device. |
| Android | AICore does not support the device, Gemini Nano not downloaded, app not in the foreground, per-app quota | See the [ML Kit GenAI overview](https://developers.google.com/ml-kit/genai). Test on a physical device. |
| Web | Not desktop Chrome, hardware or storage requirements unmet, model download pending | See [Chrome's Prompt API](https://developer.chrome.com/docs/ai/prompt-api). |

This is not a bug in your integration. If the app should still work, allow a cloud route that you configure yourself, as described in [When on-device AI is unavailable](../concepts/routing-and-privacy.md).

## Refused: no eligible provider

With `local_required` and no eligible on-device model, the SDK's `run()` rejects with an `IndeRunError` whose `errorClass` is `"CapabilityMismatch"`. In the Capacitor plugin, the bridge forwards `details` from the native side in its source; this has not been verified on a device. The message reads like:

```text
No eligible local provider found for task 'text_to_text'.
```

`details.rejectedProviders` lists each registered provider with the reason codes it was skipped for, as `[{ providerId, reasons: [{ code, … }] }]`. Common codes are `capability_unavailable` (the model isn't available on this device), `privacy_constraint` and `cloud_constraint` (your rule excluded it), `task_not_supported`, `not_ready` and `offline`. The full list is in [Placement constraints](../architecture/architecture.md#placement-constraints). There is no `no_eligible_provider` code.

A refusal means no provider ran. It is the intended result of your rule on this device. `provenance.routeRejections` appears only on a successful result, where it lists providers skipped on the way. The Capacitor source forwards `details` from the native side; confirm the exact shape in your own run, as it hasn't been verified on a device for this page. See [Read the outcome](../getting-started/capacitor.md#read-the-outcome).

## Refused, execution error or bridge fault

The plugin's README names three failure surfaces for a streaming run in its [Error Handling](https://github.com/independo-gmbh/capacitor-inderun/blob/v1.3.0-dev.1/README.md#error-handling) section (v1.3.0-dev.1):

| Surface | When | How it reaches you |
| --- | --- | --- |
| Rejection | Request validation, or no streaming-capable provider | `stream()` rejects with an `IndeRunError` |
| Terminal `error` event | A provider failed, or the whole planned chain did | Not a rejection: `for await` completes normally and the last event is `terminal` with `payload.outcome === "error"` |
| Bridge fault | The transport lost or could not encode events | `events` throws an `Internal` `IndeRunError` |

So a run that fails after it started ends your loop normally. Branch on `event.payload.outcome` to tell completion from failure from cancellation. For `run()`, errors conform to `IndeRunError`; branch on `error.errorClass`. A routing refusal is a `CapabilityMismatch` rejection (see above); it is not an execution error, because nothing executed.

## Speech problems

See [Read text aloud](speech.md) for the model behind these.

### voice_locality_unknown on Android

A `local_required` request was refused with `details.code: "voice_locality_unknown"`. The installed speech engine lists no voices, so there is no network flag to check and IndeRun can't confirm the speech stays on the device. Install or switch to a speech engine that lists its voices (Google TTS is the one that has been run), or make the request without `local_required`. This is an error detail, not a rejection code.

### Missing locale or voice

A required voice that isn't installed is refused with `voice_not_available`, and a locale no voice serves with `locale_not_supported`. IndeRun doesn't substitute another voice. Call `listVoices({ locale })` to see what the device offers, install the voice in the system settings, or prefer the voice instead of requiring it. On Android a required gender also ends in `voice_not_available`, because the platform exposes no gender.

### local_required speech refused in a browser

Always expected. A browser can't confirm that a voice stays on the device, so `local_required` speech is refused on the web. Use the default rule if network voices are acceptable, or run the request in the iOS or Android app.
