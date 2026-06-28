# Providers

This document explains the provider concept in IndeRun and records the provider families that currently exist in the repository.

## Vocabulary

- A provider is an execution backend chosen by routing.
- A runtime is the underlying system, framework, or API the provider wraps.
- Routing chooses providers, not models.

## Provider Contract

Every provider should define:

- a stable descriptor
- a dynamic capability check against the current host
- the interaction modes it supports
- its cancellation behavior
- normalized error and telemetry behavior

The code and public types should define the exact field shapes and behavior. This document only records the concept and the repository-level mapping.

## Current Provider Families

- iOS on-device: Apple Foundation Models provider
- Android on-device: ML Kit GenAI provider
- Web and native cloud: OpenAI-compatible provider
- Shared route planning: Rust core used by the TypeScript/Web side and WASM wrapper

## Current Guidance

- Provider-specific behavior should stay behind provider adapters.
- Cloud credentials should be resolved through `authContextRef`.
- Capability checks should determine whether a provider is usable before execution.
- If a provider only supports Mode 1 today, this document should not imply shipping support for streaming or realtime sessions.
- Bridge layers such as Capacitor may pass provider bootstrap inputs like model or endpoint into existing provider adapters, but they should not add provider-specific execution branches beyond that registration step.

## What Belongs Elsewhere

Detailed request mapping, error tables, and per-provider option shapes belong in code comments, schema descriptions, and package-level README files for the relevant SDK or provider package.
