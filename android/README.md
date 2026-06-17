# IndeRun Android SDK

This repository contains the official Android implementation of the IndeRun execution framework. It provides a high-performance, platform-native bridge for AI task execution on Android devices.

## Architecture Overview

The Android SDK is designed as a layered system to decouple the internal platform services from the public API. This ensures that core logic remains isolated and easily testable.

### Module Hierarchy
* **`inderun-kotlin`** (Public Surface): The primary entry point for application developers.
* **`inderun-core`** (Host Services): Internal implementation of platform capabilities.

```mermaid
graph TD
    App[Android Application] --> SDK[inderun-kotlin (Public Surface)]
    SDK --> Core[inderun-core (Host Services)]
    Core --> Context[Android Context]
```

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
    implementation("com.independo.inderun:inderun-kotlin:1.0.0") 
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
