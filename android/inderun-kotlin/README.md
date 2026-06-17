# IndeRun Kotlin SDK

The `inderun-kotlin` module is the public entry point for the IndeRun Android SDK. It provides a high-level, type-safe interface to access essential platform capabilities.

## Usage Guide

### 1. Initialization

The SDK must be initialized with an Android `Context` (such as your `Activity` or `Application` instance). This is a heavy operation that should ideally be done once during your app's startup sequence.

```kotlin
// Initialize the SDK
val indeRun = IndeRun.initialize(this)
```

### 2. Accessing Services

Once initialized, you can access all available host services directly from the `IndeRun` instance.

#### Connectivity Service
Check if the device is currently online before attempting network-dependent tasks:

```kotlin
if (indeRun.connectivity.isOnline()) {
    // Proceed with cloud-based execution
} else {
    // Fallback to on-device logic
}
```

#### Secure Storage Service
Store and retrieve credentials using their unique slot reference:

```kotlin
indeRun.secureStorage.put("openai_primary", "token")
val apiKey = indeRun.secureStorage.get("my_api_key_slot")
```

#### Clock Service
Use the provided monotonic clock for precise event timing and logging:

```kotlin
val timestamp = indeRun.clock.elapsedRealtimeMillis()
```

## Best Practices
*   **Lifecycle Management**: While the SDK is lightweight, it is recommended to hold a single instance of `IndeRun` within your `Application` class to ensure consistency across different components of your app.
*   **Thread Safety**: All service calls are designed to be thread-safe, but long-running operations involving connectivity checks should still be handled appropriately within your application's threading model.
