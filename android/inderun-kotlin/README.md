# IndeRun Kotlin SDK

Public entrypoint for the IndeRun Android SDK.

The SDK can route Mode 1 `run()` requests through on-device providers or through `OpenAIProvider` from `inderun-openai-providers`.

## Usage

```kotlin
val indeRun = IndeRun.initialize(this)
```

To register an OpenAI-compatible cloud provider explicitly:

```kotlin
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.providers.openai.OpenAIProvider
import app.independo.inderun.providers.openai.OpenAIProviderOptions

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

For full control (e.g. custom host services or a telemetry sink), construct the
engine directly with `IndeRun(registry, hostServices, telemetry)` — the same
shape as the TypeScript and Swift SDKs.

## Notes

- `OpenAIProvider` resolves bearer credentials from secure-storage slots via `authContextRef`.
- Do not place API keys or bearer tokens directly in `TaskRequest`.
- For production apps, prefer a backend or gateway endpoint and keep OpenAI credentials server-side.
