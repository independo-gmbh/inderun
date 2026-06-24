# IndeRun API Surface & Execution Lifecycle

This document defines the core interaction model for the IndeRun engine. It serves as a guide for developers integrating the SDK into their applications, explaining how requests are processed and what to expect from the orchestrator.

## The `IndeRun` Orchestrator

The `IndeRun` class is the central entry point of the framework. It acts as an execution orchestrator that manages several critical respons been:
1. **Validation**: Ensures incoming requests adhere to strict schema contracts.
2. **Routing**: Selects the appropriate provider based on the provided `request constraints` and current host capabilities.
3. **Execution**: Triggers the selected provider's adapter.
4. **Telemetry**: Measures execution timing and enriches the result with runtime metadata.

## The `run()` Execution Lifecycle

When a developer calls the `run(request)` method, the engine follows a deterministic sequence of steps:

### 1. Request Validation
The engine first validates the `TaskRequest` against the published JSON schema contracts. This step catches malformed payloads (e.g., missing required fields like `task.kind`) before any side effects occur. If validation fails, an `IndeRunException` with a `Validation` error class is thrown.

### 2. Intelligent Routing
The engine consults the configured `Router`. The router evaluates the `request constraints` provided in the request:
* **On-Device Constraints**: The router looks for providers that are currently available and capable of running on the local host (e.g., mobile device's native ML capabilities).
* **Cloud Constraints**: The router prioritizes remote execution via configured endpoints.

The result is a `RouteSelection` containing the selected provider and an explanation of why that provider was chosen (useful for debugging routing decisions).

### 3. Provider Execution
The engine invokes the `run()` method on the selected `ProviderAdapter`. This step transitions from the platform-agnized IndeRun interface to the specific implementation required by the backend (e.g., a local OS service or a remote HTTP endpoint).

### 4. Telemetry Enrichment & Finalization
Before returning the result to the caller, the engine performs several post-processing steps:
* **Timing**: Measures total execution duration from start to finish.
* **Metadata Attachment**: Attaches critical telemetry fields (e.-g., `providerUsed`, `totalMs`) to the `TaskResult`.
* **Event Emission**: Emits internal telemetry events (e.g., `route_decided`, `attempt_succeeded`) for observability.

The final `TaskResult` is returned, providing a normalized response regardless of which provider handled the request.

## Error Handling Philosophy

IndeRun uses a standardized error model designed for predictable failure handling in production environments. Instead of raw system errors, developers receive an `IndeRunException`.

Every exception includes:
* **Error Class**: A high-level taxonomy (e.g., `Offline`, `CapabilityMismatch`, `Unavailable`) that allows the UI to decide on a fallback strategy without parsing error messages.
* **Runtime Context**: Metadata such as the `runId` and which provider was being attempted when the failure occurred.
