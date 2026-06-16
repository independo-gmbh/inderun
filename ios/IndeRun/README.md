# IndeRun iOS SDK

This is the Swift implementation of the **IndeRun** AI execution framework, providing a unified developer API for running tasks across on-device, edge, and cloud providers.

## Key Features

- **Execution Abstraction**: Single `run()` API for applications, regardless of backend implementation.
- **Dynamic Routing**: Deterministically selects the optimal provider based on execution policy (e.g. `on_device` vs `cloud`) and real-time connectivity or device capabilities.
- **Standardized Errors**: Maps varying provider exceptions into a unified `IndeRunException` taxonomy.
- **Built-in Telemetry Hooks**: Standard hooks for tracing route decisions, execution latency, and success/failure rates.

---

## Package Structure

The package is split into two targets to separate the core orchestrator infrastructure from public client API surfaces:

- **`IndeRunContracts`**:
  - `Contracts.swift`: generated `Codable` models for schema-backed request, result, usage, HTTP, telemetry, and error payloads.
- **`IndeRunCore`**:
  - `HostServices.swift`: Protocols representing OS-level capabilities (Connectivity, Storage, Telemetry, Clock, HTTP Client) that the app provides.
  - `AppleHostServices.swift`: Default Apple-platform implementations for network reachability, Keychain credential slots, system timing, and URLSession HTTP transport.
  - `Provider.swift`: Adapter and capability descriptor interfaces for provider developers.
  - `Router.swift` & `Registry.swift`: Orchestration and route selection engines.
  - `Errors.swift`: Unified exceptions mapping.
- **`IndeRunSwift`**:
  - `IndeRun.swift`: The public API surface for initiating runs.
- **`IndeRunAppleProviders`**:
  - `AppleFoundationModelsProvider.swift`: iOS/macOS on-device Mode-1 text-to-text provider backed by Apple Foundation Models.

---

## Integration and Usage

### Requirements
- **Swift**: 5.9+ / Swift 6
- **Platforms**: iOS 15.0+ / macOS 12.0+

### Adding to your project
Add the package dependency to your `Package.swift`:

```swift
dependencies: [
    .package(path: "../ios/IndeRun")
]
```

Or add it directly in Xcode using the local folder reference.

### Code Example

```swift
import IndeRunSwift
import IndeRunCore
import IndeRunAppleProviders

// 1. Initialize host services
let hostServices = DefaultHostServices.make(
    telemetry: MyTelemetryService()
)

// 2. Setup registry and register providers. This helper registers the Apple
// Foundation Models on-device provider; add cloud providers separately.
let registry = try AppleProviderRegistryFactory.makeDefaultRegistry()

// 3. Initialize the SDK
let inderun = IndeRun(registry: registry, hostServices: hostServices)

// 4. Execute a task
let request = TaskRequest(
    prompt: "Translate 'Hello' to Spanish",
    policy: Policy(execution: .onDevice)
)

do {
    let result = try await inderun.run(request: request)
    print("Output: \(result.output.text)")
} catch let error as IndeRunException {
    print("Task failed: \(error.errorClass) - \(error.message)")
}
```

### Apple Foundation Models provider

`AppleFoundationModelsProvider` is available through the `IndeRunAppleProviders` product. It supports Mode-1
`text_to_text` requests with `Policy(execution: .onDevice)`, reports local/system-service provider metadata, and maps
Apple system model unavailability to the normalized `CapabilityMismatch` flow.

Runtime availability depends on the host OS and Apple system model state. The provider uses Apple Foundation Models only
when the framework is present and the runtime is available; otherwise `capabilities()` returns unavailable and the
router rejects `onDevice` requests with `CapabilityMismatch`.

---

## Development

### Building
Compile the package and targets:
```bash
swift build
```

### Running Tests
Execute the verification test suite:
```bash
swift test
```
