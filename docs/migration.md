# Migration guide

IndeRun is pre-1.0: a breaking change bumps the minor version. Each section lists what an application or provider
author has to change, per platform. The release notes carry the same changes commit by commit.

## 0.4 → 0.5

### Provider capability types are generated contracts

`ProviderDescriptor`, `ProviderDynamicCapabilities` and `ProviderCapabilitySnapshot` are now generated from
`contracts/schemas/provider-*.schema.json` on every platform (issue #210), so the hand-written copies are gone. The
JSON shape is unchanged; the names of the nested types are not.

| 0.4 (Swift / Kotlin nested type)            | 0.5                  |
| ------------------------------------------- | -------------------- |
| `ProviderDescriptor.ProviderType`           | `ProviderType`       |
| `ProviderDescriptor.TransportType`          | `ProviderTransport`  |
| `ProviderDescriptor.StreamingStyle`         | `StreamingStyle`     |
| `ProviderDescriptor.SupportsCapabilities`   | `ProviderSupports`   |
| `ProviderDescriptor.CancelSemantics`        | `CancelSemantics`    |
| `ProviderDescriptor.ResourceLimits`         | `ProviderLimits`     |
| `ProviderDescriptor.PrivacyDescriptor`      | `ProviderPrivacy`    |
| `PrivacyEnum` (the request privacy constraint) | `Privacy`         |

- **Web.** The three types are re-exported from `@independo/inderun-contracts`; imports from
  `@independo/inderun-web/provider` keep working. `validateProviderCapabilitySnapshot` (plus the descriptor and
  dynamic-capability validators) is new in the contracts package. The ONNX `OnnxRuntimeAvailability` is now a type
  alias rather than an interface.
- **Swift.** The types live in `IndeRunContracts`, which every module re-exports. Convenience initializers keep the
  0.4 argument labels and defaults (`ProviderDescriptor(id:type:model:transport:…)`,
  `ProviderDynamicCapabilities(available:reason:…)`). `ProviderPrivacy(dataLeavesDevice:)` covers the common case;
  pass `regions:` through the generated initializer. Properties are `var`, and `ProviderCapabilitySnapshot` is now
  `Codable`.
- **Kotlin.** The types live in `app.independo.inderun.contracts`. Enum entries follow the generated convention and
  carry their wire value: `ProviderType.Local`, `ProviderTransport.InProcess`, `ProviderTransport.HTTP`,
  `CancelSemantics.None`, `StreamingStyle.Tokens` (`.rawValue` is the schema string). `ProviderLimits` fields are
  `Long?`. Constructor parameters are in alphabetical order, so construct these types with named arguments.

### Planner input carries the full descriptor

`route-planner-input.schema.json` now references the provider schemas instead of carrying its own subset, so a
planner input must contain complete descriptors (`transport`, every `supports` flag, `cancel`). This only affects
code that calls `@independo/inderun-route-core-wasm`'s `planRouteJson` directly; the SDKs pass their descriptors
through unchanged.

### Per-task provider capabilities

Providers can declare what they do per task (`taskCapabilities` on the descriptor and, for live narrowing, on the
dynamic capabilities); see [providers.md](architecture/providers.md#provider-contract). Nothing has to change for an
existing text provider: a descriptor without `taskCapabilities` keeps routing exactly as before for `text_to_text`.
A provider that listed any other task in `tasks` alone is now rejected for it with `task_not_supported` — declare a
task capability to be routed a non-text task.

The planner's reason codes gain `input_not_supported`, `output_delivery_not_supported`,
`output_format_not_supported`, `locale_not_supported` and `voice_not_available`. An exhaustive Swift `switch` over
the generated `Code` must handle them. The generated Swift `RoutePlannerInputTask`, `ProviderDescriptor` and
`ProviderDynamicCapabilities` memberwise initializers gain the new optional parameters; the convenience initializers
take `taskCapabilities:` with a `nil` default.

Route-plan candidates gain an optional `voice`: the voice a speech candidate must use, bound by the planner within
the request's privacy policy. The generated Swift `Candidate` memberwise initializer gains a `voice:` parameter. Text
requests now reach the planner with `inputs: ["text"]`, so a provider that declares a `text_to_text` capability
without text input is rejected with `input_not_supported`.

Provider contexts (`RunContext`, `ProviderStreamContext`) gain an optional `voice`: the voice the plan bound this
provider to for a speech request, and a `commit()` a provider calls immediately before an external effect such as
audible playback. Text providers can ignore both. The provider stream event vocabulary gains `result`, which ends a
stream with a non-text output; text providers keep `done`. On Swift and Kotlin an exhaustive `switch` / `when` over
`ProviderStreamEvent` must handle it, and a hand-built context must supply a commit handler.

The planner no longer writes `null` for an absent optional in its output (`selectedProviderId`, `failureCode`): the key
is omitted, which is what the route-plan schema always described.

### Task-generic requests and results

The request, result and terminal contracts admit `text_to_speech` next to `text_to_text`
([ADR 016](architecture/decisions/016-modality-extensible-task-contracts.md)). The JSON of a text request, result or
stream is unchanged; the generated types are not, because one type now describes every task.

| 0.4 (generated type)                                   | 0.5                                                          |
| ------------------------------------------------------ | ------------------------------------------------------------ |
| `Output` / `OutputType` (Swift, Kotlin)                | `TaskOutput` / `TaskOutputType`                              |
| `Kind` (Swift)                                         | `TaskKind`                                                   |
| `TaskResult.output.text: String`                       | `String?` — set whenever `output.type` is `text`             |
| terminal `finalText` / `partialText` (TS)              | optional — a non-text run carries `output` instead           |
| `TaskKind` / `TaskOutputType` cases                    | gain `text_to_speech` / `playback`, `artifact`               |

- **Primary text API: nothing to change.** `generateText` / `streamText` still return a non-optional string.
- **Web.** Read `result.output.text ?? ""` where you read the generated result directly. New narrowed aliases in
  `@independo/inderun-contracts` (`TextTaskRequest`, `SpeechTaskRequest`, `TextTaskOutput`, `PlaybackTaskOutput`,
  `ArtifactTaskOutput`) restate the per-task requirements the generated types cannot carry, and
  `validateTaskOutput` / `validateMediaArtifact` are new.
- **Swift.** Build an output with `TaskOutput(text:)`, `TaskOutput(playback:speech:)` or
  `TaskOutput(artifact:speech:)`. `TaskRequest(...)` gains `speech:` and `delivery:` parameters with `nil` defaults.
  An exhaustive `switch` over `TaskKind` or `TaskOutputType` must handle the new cases.
- **Kotlin.** Construct `TaskOutput(type = TaskOutputType.TEXT, text = …)`; `TaskOutput.type` has no default because
  it is meaningful for every task. An exhaustive `when` must handle `TaskKind.TEXT_TO_SPEECH` and the new
  `TaskOutputType` entries.
- **Provider authors.** A text provider returns the same result as before with the renamed type.

### Media artifacts and two new `IndeRunApi` operations

`IndeRunApi` gains `readArtifact(request)` and `disposeArtifact(artifact)`
([ADR 017](architecture/decisions/017-media-artifacts.md)). Anything that implements the interface — a bridge, a test
fake — must add both. A run with `artifact` delivery returns a `MediaArtifact` reference; read its bytes in ranges
with `readArtifact({ artifactId, offset?, maxBytes? })`, which returns an `ArtifactChunk` (`Uint8Array` / `Data` /
`ByteArray`), and dispose it when done — artifacts outlive their run. The engine options gain artifact store limits
(`artifacts` on Web, an `artifactLimits` parameter on Swift and Kotlin). Provider contexts gain an `artifacts` sink
for providers that produce media.

### Capacitor

The bridge can drop its own copy of the snapshot type and import `ProviderCapabilitySnapshot` and
`validateProviderCapabilitySnapshot` from `@independo/inderun-contracts`. It must implement `readArtifact` and
`disposeArtifact` by forwarding to the native engine; only the artifact id crosses the bridge, and each read is bounded
by the engine's maximum read size.

## 0.3 → 0.4

0.4 introduces the public API layering ([api-layering.md](architecture/api-layering.md)): a primary text API, model
profiles, execution provenance, and separate entry points for applications and provider authors.

### New, nothing to change

- `generateText()` / `streamText()` on all three SDKs. Existing `run()` / `stream()` code keeps working; the facade is
  the new default in the documentation.
- `ExecutionProvenance` on `TaskResult`, every `StreamTerminalOutcome`, and `IndeRunError` — read it instead of
  `telemetry.providerUsed` to show where a run executed.
- Model profiles: `modelProfiles` on the engine and `modelProfile` on `TaskRequest` (`model` in the facade).
- The OpenAI-compatible provider accepts OpenRouter's Responses dialect; see [OpenRouter](openrouter.md).

### Web: entry points (`@independo/inderun-web`)

The root entry point now carries only the application API: the facade, `createIndeRunWeb`, `IndeRun` / `IndeRunApi`,
model profiles, the contract types, `IndeRunException` / `toIndeRunException`, and telemetry.

Provider-authoring and host-integration APIs moved to `@independo/inderun-web/provider`:

| Moved to `/provider` |
| --- |
| `ProviderAdapter`, `ProviderDescriptor`, `ProviderDynamicCapabilities`, `RunContext`, `ProviderStreamContext`, `ProviderStreamEvent` |
| `ProviderRegistry` |
| `HostServices` and every host-service interface (`HttpClientService`, `HttpStreamingClientService`, `SecureStorageService`, `ConnectivityService`, `ClockService`, `DeviceConstraintsService`, `HttpRequest`, `HttpResponse`, `HttpStreamResponse`, `AbortSignalLike`, `ThermalState`) |
| `createBrowserHostServices`, `BrowserConnectivityService`, `FetchHttpClient`, `FetchStreamingHttpClient`, `SystemClockService`, `CreateBrowserHostServicesOptions`, `FetchHttpClientOptions` |
| `createCapabilityMismatch`, `createOffline`, `createAuthError`, `createRateLimited`, `createTimeout`, `createUnavailable`, `createInternal`, `IndeRunExceptionParams` |

`StreamRun` and `ProviderCapabilitySnapshot` are exported from both entry points, since the application API returns
them.

```ts
// 0.3
import { IndeRun, ProviderRegistry, createUnavailable } from "@independo/inderun-web";
// 0.4
import { IndeRun } from "@independo/inderun-web";
import { ProviderRegistry, createUnavailable } from "@independo/inderun-web/provider";
```

Removed without replacement — they are engine internals with no compatibility promise: `Router`, `RouteSelection`,
`RoutePlanner`, `WasmRoutePlanner`, `PlannerOutcome`, `WasmUnavailableReason`, `SharedPlannerInput`,
`SharedPlannerRoutePlan`, and `EventGate`. Routing decisions remain inspectable through the `route_decided` telemetry
event and the provenance's `routeRejections`.

`ExecutionProvenance` is newly re-exported from the root entry point.

### All platforms: OpenAI-compatible targets

The factories (`createIndeRunWeb({ openAI })`, Swift and Kotlin `makeOpenAIRegistry`) take `models: [...]` instead of
`model`, and register one target per model with the id `<id>:<model>` — `openai:gpt-5.2` rather than `openai`. Code
that compares provider ids, such as UI labels or telemetry filters, must expect the new ids.

HTTP `402` and numeric error codes are now classified (see [OpenRouter](openrouter.md#behavior)); a `402` that used to
surface as `Internal` is now `Unavailable` and not retryable.

### Web: engine constructor

`new IndeRun(registry, host, telemetryService)` became `new IndeRun(registry, host, { telemetryService, modelProfiles })`.

### Provider authors

- `ProviderDescriptor` gains an optional `model`: the model the target is bound to. Set it when the provider knows it;
  it becomes the provenance's `configuredModel`.
- The stream `done` event gains `reportedModel`, the model the backend says served the request. On Swift,
  `ProviderStreamEvent.done` binds four values in a pattern match.
- Swift and Kotlin `StreamTerminalOutcome` builders take a required `provenance` argument, and the generated Swift
  memberwise initializers of `TaskResult`, `IndeRunError` and `StreamTerminalOutcome` gain a `provenance` parameter.

### Capacitor

The bridge consumes the published SDKs. When it moves to 0.4 it imports `createUnavailable` from
`@independo/inderun-web/provider`, forwards `modelProfile` and `provenance`, and configures OpenAI targets with
`models`.
