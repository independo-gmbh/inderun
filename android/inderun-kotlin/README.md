# IndeRun Kotlin SDK

Public entrypoint for the IndeRun Android SDK.

The SDK can route Mode 1 `run()` and Mode 2 `stream()` requests through on-device providers — `AndroidMlKitGenAiProvider` streams from Gemini Nano — or through `OpenAIProvider` from `inderun-openai-providers`.

## Usage

```kotlin
val indeRun = IndeRun.initialize(this)
```

`inderun-kotlin` exposes `inderun-contracts`, `inderun-core` and `kotlinx-coroutines-core` as
`api` dependencies, so its own dependency line is all an app needs to name `TaskRequest`,
`TaskResult` and the `Flow<StreamEvent>` from `stream()`.

To register an OpenAI-compatible cloud provider explicitly, add its module — it is not a
dependency of this one:

```kotlin
implementation("app.independo.inderun:inderun-openai-providers:latest.release")
```

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
