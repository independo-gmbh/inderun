# Migration guide

IndeRun is pre-1.0: a breaking change bumps the minor version. Each section lists what an application or provider
author has to change, per platform. The release notes carry the same changes commit by commit.

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
