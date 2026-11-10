---
slug: docs/concepts/architecture
title: "How IndeRun is structured"
description: "The parts of IndeRun and how they relate: platform SDKs, the Capacitor bridge, the engine and router, host services, provider adapters and runtimes."
sidebar:
  order: 2
---

IndeRun is an execution layer. Your app talks to one SDK, the engine decides which registered provider may run the task, and a provider adapter hands it to a runtime. IndeRun does not itself run a foundation model. For what happens to a single request, see [When on-device AI is unavailable](routing-and-privacy.md).

## The parts and how they relate

![Component map of IndeRun. Applications and public SDKs sit above the IndeRun engine, which holds orchestration, a router/planner and a registry of provider targets. Host services are consulted by the engine and providers. Provider adapters connect to runtimes and services: Apple Foundation Models, Android ML Kit GenAI / Gemini Nano, a browser-managed web system model, ONNX Runtime and an OpenAI-compatible cloud endpoint.](../assets/diagrams/architecture-map.svg)

This is a map of relationships, not a timeline. Solid arrows mean "exposes, connects to or wraps"; dashed arrows mean "supplies context or is consulted by". Available providers depend on the SDK, platform, device and released version.

**Text equivalent of the diagram**, from top to bottom:

1. **Applications and public SDK.** Capacitor, Web/TypeScript, Swift and Kotlin. The Capacitor plugin is a thin bridge into the platform SDK; it is not a separate execution engine.
2. **IndeRun engine.** Execution orchestration, a router/planner and a registry of provider targets. The router decides which targets are allowed and capable; the engine coordinates the run and normalizes output and errors.
3. **Host services** (platform context and facilities). Supplied when the engine is set up and consulted when needed, for example for connectivity or platform HTTP. They are consulted by the engine and by providers. They are neither a provider nor an inference runtime, and not a step every request passes through.
4. **Provider adapters.** Each registered target is one provider instance bound to at most one model where a model is known. Its descriptor and live capability check inform routing.
5. **Runtimes and services.** Apple Foundation Models (Apple platforms), Android ML Kit GenAI / Gemini Nano (Android), the web system-model provider (a browser-managed runtime), ONNX Runtime (a model you supply) and an OpenAI-compatible cloud endpoint, which is used only when you configure it and the request permits it. No platform has all of them.

## Glossary

- **Engine.** Coordinates execution: plans a route, runs the attempt, and returns a normalized result or error with provenance.
- **Router / planner.** Decides which registered targets are allowed and capable for a request, and in what order.
- **Host services.** Supply platform facilities such as connectivity, secure storage, timing, HTTP and the local telemetry hook (nothing is sent to Independo).
- **Provider adapter.** Connects a selected target to a backend and maps its behaviour and errors to IndeRun's normalized shapes.
- **Runtime.** The thing that actually executes the task: an on-device model runtime or a cloud service.
- **Target.** A registered provider instance, bound to at most one model where a model is known. Routing chooses among targets.

## Source

- [Architecture](../architecture/architecture.md), the baseline document.
- [Providers and support matrix](../architecture/providers.md).
- [API layering](../architecture/api-layering.md).
- [Router source](../../packages/inderun-web/src/core/router.ts) (TypeScript).
- [Capacitor plugin README](https://github.com/independo-gmbh/capacitor-inderun/blob/v1.3.0-dev.1/README.md) (pinned to v1.3.0-dev.1).
