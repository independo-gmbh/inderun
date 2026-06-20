# IndeRun Kotlin SDK

The `inderun-kotlin` module is the public entry point for the IndeRun Android SDK. It provides a high-level, type-safe interface to access essential platform capabilities.

The SDK can route Mode-1 `run()` requests through:

- on-device providers such as ML Kit GenAI
- cloud providers such as `OpenAIProvider` from `inderun-openai-providers`

## Usage Guide

### 1. Initialization

The SDK must be initialized with an Android `Context` (such as your `Activity` or `Application` instance). This is a heavy operation that should ideally be done once during your app's startup sequence.

```kotlin
// Initialize the SDK
val indeRun = IndeRun.initialize(this)
```

To register the OpenAI-compatible cloud provider explicitly:

```kotlin
import com.independo.inderun.core.ProviderRegistry
import com.independo.inderun.providers.openai.OpenAIProvider
import com.independo.inderun.providers.openai.OpenAIProviderOptions

val registry = ProviderRegistry().apply {
    register(
        OpenAIProvider(
            OpenAIProviderOptions(
                model = "gpt-5.2",
                endpointUrl = "https://api.openai.com/v1/responses",
                authContextRef = "openai_primary",
                timeoutMs = 30_000L
            )
        )
    )
}

val indeRun = IndeRun.initialize(this, registry)
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

`OpenAIProvider` resolves bearer credentials from these secure-storage slots via `authContextRef`.
Do not place API keys or bearer tokens directly in `TaskRequest`.

#### Clock Service
Use the provided monotonic clock for precise event timing and logging:

```kotlin
val timestamp = indeRun.clock.elapsedRealtimeMillis()
```

## Best Practices
*   **Lifecycle Management**: While the SDK is lightweight, it is recommended to hold a single instance of `IndeRun` within your `Application` class to ensure consistency across different components of your app.
*   **Thread Safety**: All service calls are designed to be thread-safe, but long-running operations involving connectivity checks should still be handled appropriately within your application's threading model.
*   **Proxy-first Cloud Access**: For production apps, prefer an app backend or gateway endpoint and configure `OpenAIProviderOptions(auth = OpenAIAuthMode.none)` so OpenAI credentials remain server-side.
