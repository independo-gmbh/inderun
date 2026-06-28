# Android OpenAI Providers

Android `OpenAIProvider` implementation for IndeRun.

It provides Mode 1 support for canonical IndeRun `text_to_text` requests, OpenAI Responses-compatible request and response mapping, `authContextRef` credential resolution, configurable endpoint URL and timeout, and normalized error mapping.

## Registration Example

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
                authContextRef = "openai_primary"
            )
        )
    )
}
```
