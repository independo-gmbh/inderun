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
                // A backend you control that holds the OpenAI key and relays the
                // Responses stream — not api.openai.com. See Notes below.
                endpointUrl = "https://api.example.com/inderun/openai-responses",
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

- `OpenAIProvider` resolves bearer credentials from secure-storage slots via `authContextRef`, so a
  secret never enters a `TaskRequest` and never sits in source.
- That is not the same as making a key safe to ship. Anything an installed app can read, someone
  with that app can read; a developer-owned API key does not become safe by being referenced
  indirectly. `authContextRef` is for credentials that legitimately live on the device — a per-user
  or per-install token your backend issued.
- For a key you own, put it behind a backend you control and point `endpointUrl` at that. The Web
  SDK enforces this; here it is a convention, because a native app can reach any endpoint it likes.
