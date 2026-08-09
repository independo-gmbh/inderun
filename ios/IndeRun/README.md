# IndeRun iOS SDK

Swift implementation of IndeRun for iOS and macOS.

The package is split into public API, core engine, contracts, and provider targets:

- `IndeRunContracts` - generated schema-backed models
- `IndeRunCore` - host services, router, registry, and error mapping
- `IndeRunSwift` - public SDK entrypoint
- `IndeRunAppleProviders` - Apple Foundation Models provider
- `IndeRunOpenAIProviders` - OpenAI-compatible cloud provider
- `IndeRunOnnxProviders` - ONNX Runtime provider family member for developer-supplied/custom
  local models (see `docs/architecture/onnx-runtime-provider-family.md`)

Requires iOS 16+ / macOS 14+ (raised from iOS 15 / macOS 12 by `IndeRunOnnxProviders`'s
dependencies: the official ONNX Runtime SPM bindings and `swift-transformers`).

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

### Custom local ONNX models

```swift
import IndeRunOnnxProviders

let modelPackage = ModelPackage(
    files: Files(config: nil, external: nil, filesRequired: ["model.onnx"], tokenizer: "tokenizer.json"),
    format: .onnx,
    id: "my-onnx-model",
    integrity: nil, license: nil, limits: nil, runtime: nil,
    source: Source(ref: "my-model", sourceType: .bundled),
    tasks: ["text_to_text"],
    version: "1.0"
)
try registry.register(OnnxRuntimeAppleProvider(options: OnnxProviderOptions(modelPackage: modelPackage)))
```

Defaults to `SystemOnnxGenAiRuntime` (official ONNX Runtime SPM bindings + `swift-transformers`
tokenization, greedy decoding, no KV-cache reuse). Pass `runtime:` in `OnnxProviderOptions` to
supply a different `OnnxGenAiRuntime` implementation, or `createFixtureOnnxRuntime()` for demos
and tests. See `docs/architecture/onnx-runtime-provider-family.md#apple-implementation` for the
model IO contract, source-type support, and error mapping.

## Notes

- Keep credentials behind `authContextRef`.
- Use the Apple provider for on-device Mode 1 execution when the system runtime is available.
- Use the OpenAI provider for OpenAI-compatible cloud execution through a host-provided HTTP client.
- Use the ONNX Runtime provider for developer-supplied/custom local models.

## Commands

The SwiftPM manifest lives at the repository root (`Package.swift`); these sources are
referenced from there. Run the package commands from the repo root:

```sh
swift build
swift test
```
