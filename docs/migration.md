# Migration guide

IndeRun is pre-1.0: a breaking change bumps the minor version. Each section lists what an application or provider
author has to change, per platform. The release notes carry the same changes commit by commit.

## 0.4 → 0.5

**Text applications: nothing to change.** `generateText()`, `streamText()`, `run()` and `stream()` behave as in 0.4,
and a text request, result or stream has the same JSON. What changes for text code is the names of some generated types,
listed below. The 0.4 text suites still run on every platform (`pnpm test`), against the same shared fixtures.

### Speech API

`speak()`, `generateSpeech()` and `listVoices()` are new and additive; `generateText()` and `streamText()` are unchanged.
See [api-layering.md](./architecture/api-layering.md#primary-speech-api). No text provenance changes. On a speech run, a
`local` provider now reports locality `unknown` when its bound voice may send text off the device.

`listVoices()` returns every voice with an opaque `id` and a `name`. Pass an entry as `voice` to speak with it. Generated
Swift `ProviderVoice`, `SpeechVoice`, `SpeechOutputVoice` and `VoiceRequirement` memberwise initializers gain `id`,
`providerId` and `name` parameters. A provider that lists voices should give each an `id`, and resolve `context.voice`
by it.

Playback reports when the first word started, as `PlaybackOutput.timing.firstAudioMs` and `SpokenSpeech.timing`,
optional on every platform. The shape is described under "Neural speech model packages and voice locales" below; the
flat `firstAudioMs` fields of the 0.5 release candidates never shipped in a release. A custom Android
`AndroidSpeechEngine` keeps working unchanged: the new `speakWithTimings` defaults to `speak` and reports no first
word. A custom Web `SystemSpeechRuntime.speak` may resolve `firstAudioMs` too.

**Playback and retrievable audio are separate deliveries.** `speak()` asks for `playback`: the provider plays the audio
and the application gets an ending, never bytes. `generateSpeech()` asks for an `artifact`: silent, and its bytes are
read with `readArtifact()`. Neither stands in for the other. A provider declares what it can do in its `text_to_speech`
capability's `outputs`, so check `checkCapabilities()` before offering a download; the
[README](../README.md#speaking-text) has the check. In the browser the only speech provider is playback-only.

**Voices and privacy.** The voice catalog belongs to the device and differs between devices, engines and browsers, so
store a voice `id` only for the device that listed it. Under `local_required`, Android trusts the engine's per-voice
network flag, Apple has no such flag and relies on voices being installed, and the browser is always refused. Provenance
reports locality `unknown` whenever the platform cannot show that the text stays on the device. See the
[system speech family doc](architecture/system-speech-provider-family.md#locality).

### Prepare and readiness

`prepare()` is new and optional (ADR 019). The first run of a task now prepares that task once, for providers that
declare `interaction.prepare`. `ProviderRegistry.register` gains optional `autoDownload`, off by default. A run refused
while something is not ready reports `not_ready`. ML Kit, Chrome and Foundation Models descriptors now carry
`taskCapabilities`. `AppleFoundationModelsAvailability` gains `.notReady`. Generated Swift `TaskOutput`, `ProviderVoice`,
`ProviderTaskAvailability` and `Payload` memberwise initializers gain new parameters.

The ONNX runtime seams split in two: a custom `OnnxGenAiRuntime`, `AndroidOnnxGenAiRuntime` or `OnnxTextGenerationRuntime`
adds a cheap `availability`, and `prepare` now loads the model. A corrupt model is found at load, not at routing.

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
for providers that produce media. A request may name an application destination with `delivery.destinationRef`
(artifact delivery only); it needs the new optional host service (`artifactDestinations` on Web `HostServices`, the
matching protocol / interface on Swift and Kotlin), and a host without one refuses the request before routing.

### Neural speech model packages and voice locales

Four contract shapes changed: three grew additively on the wire; `PlaybackOutput` moved its fields, a breaking change.

- **`ModelPackage`** gains `speech`, `variant` and `runtime.minOsVersion`. The Swift memberwise initializers grew;
  labelled compat initializers keep the old `ModelPackage(files:format:…version:)` and
  `Runtime(minOpset:minRuntimeVersion:platforms:)` signatures compiling. `Format` gains `coreai`, so an exhaustive
  `switch` / `when` over it needs a case.
- **`ProviderVoice`** gains `locales`. The Swift memberwise initializer grew (use the labelled convenience
  initializer) and the Kotlin positional constructor order changed.
- **`PlaybackOutput`** loses its flat `durationMs`, `firstAudioMs` and `firstChunkMs` and gains `timing`, a
  `PlaybackTiming` with the same three optional fields (`minimum: 0`); `timing` is absent when the provider measured
  nothing. `SpokenSpeech.durationMs`, `.firstAudioMs` and `.firstChunkMs` are replaced by `SpokenSpeech.timing`, the
  generated `PlaybackTiming`, on all three SDKs. Read `speech.timing?.firstAudioMs` instead of `speech.firstAudioMs`.
  On Swift the `PlaybackOutput(durationMs:)` and `PlaybackOutput(durationMs:firstAudioMs:)` compatibility initializers
  and `with(durationMs:)` are removed (use `PlaybackOutput(timing: PlaybackTiming(durationMs:…))`), and
  `PlaybackOutput.CodingKeys` has only `timing`. On Kotlin use `PlaybackOutput(timing = PlaybackTiming(…))`; every
  `PlaybackTiming` field defaults to null. No current engine reports timing for a cancelled run; a provider-to-engine
  path for partial timing on cancel is a follow-up of the neural speech provider PR.
- **`firstAudioMs` origin.** `firstAudioMs` and `firstChunkMs` count from the moment the provider's `run()` or `stream()`
  started handling the request, including its own queue wait and voice lookup and excluding routing. The three system
  speech providers add that receipt-to-handoff time to what the platform reports, so `firstAudioMs` reads slightly
  higher than in the 0.5 release candidates, where it counted from the handoff to the platform only. The runtime seams
  (`SystemSpeechRuntime`, `AppleSpeechRuntime`, `AndroidSpeechEngine`) are unchanged.
- **TypeScript `SpeechVoiceInfo`** gains a required `kind` plus optional `model` and `locales`; code that constructs
  one by hand must supply `kind`.

### Audio output host service

Additive. `HostServices` gains an optional `audioOutput` (an `AudioOutputService`) on all three SDKs, for providers
that synthesize PCM themselves ([ADR 021](./architecture/decisions/021-audio-output-host-service.md)). The browser,
Apple and Android default bundles now include one, so nothing changes for an app that uses them. A hand-built
`HostServices` needs nothing and keeps working; a provider that needs audio output then refuses before commit with
`audio_output_unavailable`. The Swift `DefaultHostServices.make` grew one defaulted `audioOutput` parameter,
`createBrowserHostServices` accepts `audioOutput` to replace the default, and the Kotlin
`HostServicesFactory.create(context)` signature is unchanged.

### Neural speech provider family

Additive, apart from three changes listed below: a wider Swift re-export, a new Kotlin `api` dependency and one moved
Kotlin import. The neural speech family
([ADR 020](./architecture/decisions/020-neural-speech-and-model-packages.md),
[family doc](./architecture/neural-speech-provider-family.md)) adds a Web subpath `@independo/inderun-web/neural-speech`
with a `neuralSpeech` option on `createIndeRunWeb`, a Swift product and target `IndeRunNeuralSpeech`, and a Kotlin Gradle
module `inderun-neural-speech`. Nothing registers it by default, so an app that does not use it changes nothing. The provider takes a required
`runtime`; an ONNX Runtime runtime with the Articulino pipeline now ships on all three SDKs (below).

- **Web: a new optional peer.** `onnxruntime-web` is an optional peer dependency of `@independo/inderun-web`, needed only
  for `createOnnxNeuralSpeechRuntime()`. Apps that do not use it install nothing.
- **Swift: a wider re-export.** `IndeRunOnnxProviders` now re-exports `IndeRunNeuralSpeech`, so an app that imports it
  also sees the neural speech types; a name clash is the only way this can break existing code.
- **Kotlin: a new `api` dependency.** `inderun-onnx-providers` now depends on `inderun-neural-speech` with `api`, so its
  types are on a consumer's compile classpath.

The model package validator moved into Core on Swift and Kotlin, so the ONNX and neural speech families share one. This
matters only to code that names it directly.

- **Kotlin: a source break.** `getModelPackageValidationIssues` and `ModelPackageValidationIssue` moved from
  `app.independo.inderun.providers.onnx` to `app.independo.inderun.core`. A consumer of `inderun-onnx-providers` that
  imports either from the old package changes the import; no dependency changes, because `inderun-onnx-providers`
  already exposes `inderun-core` as an `api` dependency.
- **Swift: source-compatible.** Both moved from `IndeRunOnnxProviders` to `IndeRunCore`. `IndeRunOnnxProviders`
  re-exports `IndeRunCore`, so code that imports `IndeRunOnnxProviders` still compiles unchanged.

`SpeechWAV` is public in `IndeRunCore`.

Apple Core AI runtime and the readiness hint ([ADR 022](./architecture/decisions/022-core-ai-runtime.md)), all additive:

- **Swift: a new product and target `IndeRunCoreAIProviders`.** It holds the Core AI executor and composed runtime
  (`makeCoreAINeuralSpeechProvider`). Nothing registers it, so an app that does not import it changes nothing.
- **All SDKs: `NeuralSpeechAvailability.readiness`.** An optional field (`readiness?: "not_prepared" | "cold"` on the
  Web, `NeuralSpeechReadiness?` on Swift and Kotlin). A custom runtime that does not set it changes nothing.
  Kotlin's `NeuralSpeechAvailability` is a data class whose constructor, `copy` and `componentN` gained the parameter:
  source compiles unchanged, but a runtime compiled against an earlier release must be recompiled.
- **Swift: `NeuralSpeechProvider.close()`.** A provider made by `makeCoreAINeuralSpeechProvider` owns the Core AI
  runtime the factory built, and `close()` releases it. A provider built with `NeuralSpeechProvider(options:)` leaves the
  runtime it was given open, so code that already closes its own runtime changes nothing.
- **Swift: `ModelPackageDirectory` is a new public type in `IndeRunCore`.** It resolves a package directory and verifies
  its checksums; the ONNX runtimes now call it instead of their own copy, with unchanged behaviour.

German text frontend ([ADR 023](./architecture/decisions/023-german-text-frontend.md)), all additive:

- **All SDKs: an optional `normalizeText` on `NeuralSpeechRuntime`.** TypeScript: an optional member that may return a
  Promise. Swift: a protocol-extension default. Kotlin: a default method. A custom runtime that does not implement it
  changes nothing.
- **Web: `normalizeSpeechText` and `initSpeechText` in `@independo/inderun-route-core-wasm`,** backed by a second
  generated module, `inderun_speech_text`, loaded lazily. Hosts that serve the wasm from a custom path also need
  `initSpeechText(moduleOrPath)` for `inderun_speech_text_bg.wasm`; the planner's `initSharedCore` path does not cover
  it.
- **Android: `libinderun_speech_text.so` in the `inderun-neural-speech` AAR.** The `inderun-core` library stays
  planner-only.
- **Apple: a second binary target, `InderunSpeechTextFFI.xcframework`,** linked only by `IndeRunNeuralSpeech`.

### Capacitor

The Capacitor bridge is versioned separately and moves to the 0.5 contracts in its own release (#250); the
[compatibility matrix](release.md#compatibility-matrix) says which bridge version pairs with which core version.
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
