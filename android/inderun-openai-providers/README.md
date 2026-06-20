# Android OpenAI Providers

This module contains the Android `OpenAIProvider` implementation for Issue #10.

It provides:

- Mode-1 `run()` support for canonical IndeRun `text_to_text` requests
- OpenAI Responses-compatible request and response mapping
- `authContextRef` credential resolution through `SecureStorageService`
- configurable endpoint URL and timeout
- normalized error mapping to the IndeRun taxonomy

Registration example:

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
                authContextRef = "openai_primary"
            )
        )
    )
}
```
