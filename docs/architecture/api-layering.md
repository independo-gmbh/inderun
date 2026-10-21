# Public API Layering

This document defines which parts of the IndeRun SDKs are public API, who each part is for, and how the
layers relate. It is the baseline for the familiar text facade, model profiles, and execution provenance, and for
every later capability (such as `text_to_speech`) that has to fit the same shape.

It stays at the level of concepts and public names. Exact signatures live in code, and the request mapping is pinned
by shared fixtures rather than restated here.

## Status

| Part | Status |
| --- | --- |
| Layer definitions and compatibility contract | Specified (this document) |
| Model profiles | Implemented on Web, iOS/macOS, and Android |
| Execution provenance | Implemented on Web, iOS/macOS, and Android |
| Primary text API (`generateText` / `streamText`) | Implemented on Web, iOS/macOS, and Android; translation pinned by `contracts/fixtures/facade/text-generation.json` |
| Package surface restructuring along these layers | Not started; the current exports are classified below |

## Layers

IndeRun exposes three public layers and keeps one internal layer.

| Layer | Who it is for | What it contains | Stability |
| --- | --- | --- | --- |
| **Primary** | Application developers | `generateText()` / `streamText()`, model profile names, the compact `execution` policy | Public; the default path in documentation |
| **Advanced** | Applications that need full control | `IndeRun.run()` / `stream()` / `checkCapabilities()`, `TaskRequest`, `TaskResult`, `StreamEvent`, `StreamTerminalOutcome`, `IndeRunError`, `ExecutionProvenance` | Public; the canonical execution contract |
| **Provider authoring** | Provider and host integrators | `ProviderAdapter` and its streaming variant, `ProviderDescriptor`, dynamic capabilities, `HostServices` and its services, `ProviderRegistry` | Public; changes are called out in release notes |
| **Internal** | The engine itself | `Router`, the route planner bindings (`WasmRoutePlanner`, `SharedRoutePlanner`, `SharedCoreRoutePlanner`), planner input and plan types, `EventGate` | No compatibility promise; may be exported today for historical reasons |

The primary layer is a translation layer, not an engine. Every primary call compiles to exactly one canonical
`TaskRequest` and calls `run()` or `stream()` on the `IndeRunApi` surface. Routing, fallback, cancellation, credential
resolution, telemetry, and error normalization happen once, in the engine, for both layers. A call through the
facade and the equivalent direct call produce the same canonical outcome.

Because the facade is written against the generated `IndeRunApi` interface rather than the concrete engine class,
anything that implements that interface — including a bridge such as Capacitor — gets the facade without
reimplementing it.

The advanced layer stays public and documented. Developers reach for it when they need the canonical request shape
itself: building requests programmatically, inspecting the full stream event sequence, reading capability snapshots,
or targeting a future task kind before the facade covers it.

## Primary Text API

The Web SDK is the reference developer experience. Swift and Kotlin expose the same concepts in their own idiom
(extension methods on `IndeRunApi`) rather than identical syntax.

- `generateText(inderun, options)` returns the text, finish reason, usage when reported, the run id, and the
  execution provenance. It is not cancellable, for the same reason `run()` is not: Mode 1 has no cancellation channel.
  Use `streamText()` when cancellation matters.
- `streamText(inderun, options)` returns a text-only view of the stream, the full canonical event sequence, a promise
  (or the platform equivalent) of the final result, and `cancel()`. The canonical terminal guarantees apply unchanged:
  exactly one ending, nothing after it, cancellation is an ending rather than an error.

Options cover the common case and nothing else:

| Facade option | Canonical `TaskRequest` field |
| --- | --- |
| `prompt` | `prompt` |
| `messages` | `messages` |
| `system` | a leading `system` message; a request with `system` always uses the `messages` form |
| `model` | `modelProfile`; omitted means `"auto"` |
| `maxOutputTokens`, `temperature`, `topP`, `stop`, `seed` | `generation.*` |
| `execution.privacy`, `execution.cloud`, `execution.timeoutMs` | `constraints.*` |
| `execution.optimizeFor` | `preferences.optimizeFor` |
| `authContextRef`, `telemetry` | passed through unchanged |

The `execution` object reuses the canonical enum values (`local_required`, `cloud_allowed`, `latency`, …) rather
than inventing a second vocabulary, so moving a call between the layers never changes what a constraint means.
Fallback has no separate switch: whether a run may fall back to the cloud is exactly what `privacy` and `cloud`
already decide.

## Model Profiles

Model selection is a property of configuration, not of call sites. App code names *what kind* of model it wants; the
engine setup decides *which* concrete models and providers can serve it.

- A **target** is one registered provider instance bound to exactly one model. A local provider is one target. A cloud
  provider configured with several models registers one target per model.
- A **profile** is an application-defined name mapped to an ordered list of target ids, given when the engine is
  constructed (for example `fast` and `smart`).
- **`"auto"`** is the built-in profile: every registered target, ranked exactly as routing ranks them without a
  profile. It is the default, so an application that never configures a profile never sees one.
- A request names a profile and nothing else. Raw model ids and provider ids are never accepted in a request, so
  swapping a provider, renaming a model, or adding a cloud fallback is a configuration change, not a code change.

A profile is an allow-list and an order. Targets outside the profile are rejected with an inspectable reason code
(`not_in_model_profile`), exactly like any other routing rejection. Placement constraints keep their dominance: a
`local_required` request never reaches a cloud target because a profile lists one, and `local_preferred` still tries
local targets in the profile first. The profile order ranks targets within a placement tier.

An unknown profile name is a request validation failure, reported before any provider is probed.

There is deliberately no global model registry and no per-request model override. IndeRun does not catalog models;
each provider declares the one model it is bound to, and the application decides which of those it considers
interchangeable.

## Execution Provenance

Every completed result, every terminal stream outcome, and every normalized error can carry an `ExecutionProvenance`
record: which target ran, its declared locality, the configured and provider-reported model, whether fallback
happened, and why other candidates were skipped. It is the normalized answer to "what actually happened", so that
applications and bridges never need telemetry or provider-id parsing to show it. See
[architecture.md](./architecture.md#execution-provenance) for what it proves and what it does not.

## Compatibility With Familiar Ecosystems

- **Vercel AI SDK.** A future IndeRun provider package maps `inderun("smart")` to the `smart` profile and
  `inderun("auto")` to `"auto"`. AI SDK provider options map onto the `execution` object. The provider package
  compiles to the canonical path like the facade does; it is not a second engine.
- **OpenAI- and OpenRouter-style request shapes.** The facade borrows their vocabulary (`prompt`, `messages`,
  `system`, `model`, `maxOutputTokens`, `temperature`, `topP`, `stop`, `seed`) so existing code reads naturally. The
  one deliberate difference: `model` names an IndeRun profile, never a vendor model id. OpenRouter is a cloud
  target configured through the OpenAI-compatible provider, not a replacement for IndeRun routing.
- Features those ecosystems have and IndeRun does not (tools, structured output, images, embeddings) fail clearly in
  adapters rather than being silently dropped.

## Future Capabilities

New task kinds extend the canonical layer first, because routing needs the task. The primary layer then gains a
capability-specific entry point (for example `generateSpeech()` for `text_to_speech`) that follows the same rules:
one canonical request per call, the same `execution` object, the same profile mechanism (a profile can list text or
speech targets), and the same provenance. Nothing about the layering assumes chat-completion semantics.

## Current Export Classification

The Web SDK entry point (`packages/inderun-web/src/index.ts`) currently exports every layer from one barrel. Until the
package surface is restructured, this is how its exports map onto the layers:

- **Primary:** `generateText`, `streamText`, `toTaskRequest` and their option/result types, `createIndeRunWeb`.
- **Advanced:** `IndeRun`, `IndeRunApi`, the re-exported contract types, `IndeRunException` and its helpers,
  telemetry types.
- **Provider authoring:** the provider contract types, `ProviderRegistry`, the host-service interfaces and browser
  host-service implementations, the provider subpaths (`/openai`, `/onnx`, `/system-model`).
- **Internal:** `Router`, `RouteSelection`, `WasmRoutePlanner` and the planner types, `EventGate`.

Swift and Kotlin follow the same split along their module boundaries: `IndeRunSwift` / `inderun-kotlin` carry the
primary and advanced layers, `IndeRunCore` / `inderun-core` the provider-authoring layer, and the planner bindings
inside the core modules are internal.

## Non-Goals

Mode 3 sessions, text-to-speech, speech-to-text, realtime voice, tools and agents, a hosted gateway, a model
marketplace, and broad provider expansion are outside this layering decision. The layering leaves room for them; it
does not specify them.
