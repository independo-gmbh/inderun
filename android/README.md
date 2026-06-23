# IndeRun Android SDK

This repository contains the official Android implementation of the IndeRun execution framework. It provides a high-performance, platform-native bridge for AI task execution on Android devices.

## Architecture Overview

The Android SDK is designed as a layered system to decouple the internal platform services from the public API. This ensures that core logic remains isolated and easily testable.

### Module Hierarchy
* **`inderun-kotlin`** (Public Surface): The primary entry point for application developers.
* **`inderun-core`** (Host Services): Internal implementation of platform capabilities.
* **`inderun-demo-app`** (Demo Application): A small Compose app for validating the Android Mode-1 demo flow.

```mermaid
graph TD
    Demo[inderun-demo-app] --> SDK[inderun-kotlin (Public Surface)]
    App[Android Application] --> SDK[inderun-kotlin (Public Surface)]
    SDK --> Core[inderun-core (Host Services)]
    Core --> Context[Android Context]
```

## Demo App

A checked-in Android demo app lives at `android/inderun-demo-app`.
It exercises:

- on-device execution through the ML Kit GenAI provider when available
- cloud execution through the OpenAI-compatible provider with proxy-first auth disabled in the app

Use the demo app README for emulator vs device endpoint rules, proxy guidance, and ML Kit readiness caveats.

## Getting Started

### Build Requirements

- JDK 17 for Gradle and Android builds
- Android SDK installed locally
- Use the checked-in wrapper from `android/`
- Configure the SDK via `ANDROID_HOME` or `android/local.properties`

### Checked-in Commands

```sh
cd android && ./gradlew build
cd android && ./gradlew test
```

### Installation

Add the following dependency to your app's `build.gradle` file:

```kotlin
dependencies {
    implementation("app.independo.inderun:inderun-kotlin:1.0.0") 
}
```

### Quick Start Example

The SDK is initialized via an Android `Context`:

```kotlin
// Initialize the SDK
val indeRun = IndeRun.initialize(this)

if (indeRun.connectivity.isOnline()) {
    println("Elapsed realtime: ${indeRun.clock.elapsedRealtimeMillis()}")
}
```
