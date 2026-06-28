# IndeRun iOS SDK

Swift implementation of IndeRun for iOS and macOS.

The package is split into public API, core engine, contracts, and provider targets:

- `IndeRunContracts` - generated schema-backed models
- `IndeRunCore` - host services, router, registry, and error mapping
- `IndeRunSwift` - public SDK entrypoint
- `IndeRunAppleProviders` - Apple Foundation Models provider
- `IndeRunOpenAIProviders` - OpenAI-compatible cloud provider

## Usage

```swift
import IndeRunSwift
import IndeRunCore
import IndeRunAppleProviders
import IndeRunOpenAIProviders

let hostServices = DefaultHostServices.make()
let registry = try AppleProviderRegistryFactory.makeDefaultRegistry()
try registry.register(
    OpenAIProvider(
        options: OpenAIProviderOptions(
            model: "gpt-5.2",
            endpointURL: "https://api.openai.com/v1/responses",
            authContextRef: "openai_primary"
        )
    )
)

let inderun = IndeRun(registry: registry, hostServices: hostServices)
let result = try await inderun.run(request: TaskRequest(
    prompt: "Translate 'Hello' to Spanish",
    constraints: TaskRequestConstraints(privacy: .localRequired)
))
```

## Notes

- Keep credentials behind `authContextRef`.
- Use the Apple provider for on-device Mode 1 execution when the system runtime is available.
- Use the OpenAI provider for OpenAI-compatible cloud execution through a host-provided HTTP client.

## Commands

```sh
cd ios/IndeRun && swift build
cd ios/IndeRun && swift test
```
