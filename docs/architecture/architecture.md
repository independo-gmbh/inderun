# Architecture

This document describes the conceptual architecture of IndeRun. It stays intentionally high level so the code and schemas remain the source of detailed behavior.

## Layers

IndeRun is organized into four layers:

- Application consumers, such as web apps, native mobile apps, and demo apps
- Public SDK surfaces, such as the TypeScript, Swift, and Kotlin entrypoints
- Engine core and host services, which own routing, orchestration, telemetry, and platform access
- Provider adapters, which wrap local runtimes, system services, or cloud APIs

The separation matters because provider-specific details should remain behind adapter boundaries whenever a normalized IndeRun shape exists.

## Execution Model

The current public execution path is Mode 1 `run()`. The engine validates the request, selects a provider deterministically, executes the request, and normalizes the result or error.

The same conceptual model is shared across platforms:

- request and result shapes come from the schema-backed contracts
- host services provide connectivity, storage, timing, HTTP, and telemetry access
- provider adapters advertise static and dynamic capability information
- routing stays deterministic for a fixed request, policy, and capability snapshot

## Cancellation And Fallback

Cancellation should produce a terminal cancellation outcome and no further user-visible events after the cancel point.

Fallback should be predictable and inspectable. If a preferred provider cannot execute, the engine should use the same normalized routing and error model rather than exposing provider-specific control flow to the app.

## Security And Parity

Credentials must be referenced through secure storage, not embedded in request payloads. Cross-platform behavior should stay aligned even when the underlying runtime differs by OS or provider.

## Out Of Scope

Mode 4 submit/jobs infrastructure is out of scope for the current phase. The architecture may leave room for it, but this document should not spec that future work in detail.
