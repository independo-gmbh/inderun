# ADR 020 — Neural speech and model packages

## Status

Accepted. Recorded for Milestone 5 (issue #260). It widens the contracts that
[ADR 018](./018-speech-application-api.md) left narrow for the first cloud and neural speech providers, and leaves
[ADR 019](./019-prepare-and-readiness.md) section 5 unchanged: IndeRun downloads and stores nothing.

## Context

Independo's accessibility apps hear recurring feedback that system voices sound bad. The aim is for neural voices to be
selectable options on devices that can run them, with system voices as the fallback everywhere else and the end user
still picking one specific voice. Issue #260 asks for that across several model families, so the contracts must not
assume one family. Three runtime constraints shape the work:

- Speech needs two runtimes at most, ONNX Runtime and Apple Core AI. IndeRun does not grow its own inference engine.
- Models are app-owned files. The package describes them; it does not fetch or keep them.
- A neural model has no `ProviderVoice` of its own: its voices are files inside the package, and one voice can speak
  several languages.

The contracts had four gaps:

- `ModelPackage` described text models only: `format` was `onnx`, `ort` or `genai`, and nothing described voices, a
  sample rate or a text frontend.
- It had no place to tell a model from the bytes that carry it, such as an int8 build of the same model.
- `ProviderVoice.locale` was one required tag. ADR 018 named this as the limit the first multilingual provider has to
  widen.
- `PlaybackOutput` had one timing, `firstAudioMs`, measured at the audio sink. A benchmark could not tell synthesis
  time from output time.

## Decision

### 1. One `ModelPackage` describes any local model

`model-package.schema.json` stays the provider-neutral description of a local model, and grows instead of forking:

- `format` gains `coreai`, an Apple Core AI asset. The runtime seam switches on `format`, as it does for `onnx` and `ort`.
- `variant` is an optional string for the concrete build, for example `onnx-int8`. `id` stays the logical model and
  `license` the weights licence.
- `runtime.minOsVersion` is an optional string for platform-gated runtimes.
- `speech` is an object, required when `tasks` contains `text_to_speech`. It carries `pipeline`, `sampleRate`,
  `channels`, `graphs` (role to file), `frontend` and `voices`.
- `frontend` has a `kind` of `grapheme` or `phoneme`, its `assets` by role, and an optional `license`.
- Each voice has an `id`, a `name`, `locales`, an optional `gender`, an optional `file` and an optional `license`. A
  voice has no `file` when the graphs carry it and the pipeline selects it, for example by speaker index. Voice ids are
  unique within a package.
- `pipeline` is an open string, not an enum. An enum would cost a schema change, three code generators and the
  wire-value table for every model family, and a provider that does not know a value can refuse it.

The required-when rule is in the schema (`if`/`then`), and the TypeScript validator enforces the schema. The native
validators (Swift and Kotlin, whose generated types decode the shape) enforce the required-when rule for decoded values,
unique voice ids and the structural speech rules (sample rate and channels at least 1, at least one graph and one voice,
non-empty hyphenated locales), besides the existing id and secret checks. Moving the validator out of the ONNX modules
into `IndeRunCore` / `inderun-core` stays the first step of the neural speech provider PR.

### 2. A voice may list every locale it speaks

`ProviderVoice` gains an optional `locales` array of further tags. `locale` stays required and stays the primary tag, so
existing providers and the Swift convenience initializer keep working. This resolves the limit recorded in ADR 018.

The route planner matches a request's locale against `locale` or any of `locales`, at every site that compares one:
fit, locale rank and the exact-region tiebreak. A multilingual voice therefore binds for `en-US` and for `de-DE`. The
shared fixtures in `contracts/fixtures/routing/planner-conformance.json` pin this.

### 3. Playback reports its timings as one type

`PlaybackOutput.timing` is a `PlaybackTiming`: `durationMs`, `firstAudioMs` (first audible-output callback or first
frame leaving the output) and `firstChunkMs` (first playable PCM chunk, for a provider that synthesizes PCM itself).
`SpokenSpeech.timing` carries the generated type on all three SDKs, as `provenance` carries `ExecutionProvenance`,
so the facade has no hand-written copy. `firstAudioMs` and `firstChunkMs` count from the same origin, the moment the
provider's `run()` or `stream()` started handling the request, so `firstAudioMs - firstChunkMs` is the provider's output
latency. Both are measured from the same origin, though the end event differs (a word callback for a system voice,
the first frame out for a model voice). The system speech providers add their own receipt-to-handoff time to what the
platform reports; their runtime seams still measure from the handoff. No current engine reports timing for a cancelled
run; a provider-to-engine path for partial timing on cancel is a follow-up of the neural speech provider PR.

### 4. "Neural" is not a wire field

The wire carries no neural flag, because a provider cannot honestly assert one: Apple's premium system voices are
neural too. `listVoices()` instead returns `SpeechVoiceInfo.kind`, `platform` or `model`, with the model id beside it.
The facade derives both from `descriptor.model`, which is the grouping an application needs to offer a person a choice.
`contracts/fixtures/facade/list-voices.json` pins the derivation.

## Consequences

- One neural speech provider per runtime can serve every model family that shares this package shape, instead of one
  provider per family. Adding a family adds a `pipeline` value, not a contract change.
- Core AI reuses the same package: `format: coreai` plus `runtime.minOsVersion`, with the same `speech` block.
- A provider that meets an unknown `pipeline` must refuse it explicitly. Nothing validates the string beyond its type.
- The planner can bind one multilingual voice to requests in several languages, and benchmarks can separate synthesis
  from output latency.
- A voice with `locales` appears under every language it lists, so a catalog filtered by language can show it more than
  once. Code that read `locale` alone now misses the other tags.
- The planner's exact-region comparison ignores case and does not normalise `_`, so `de_DE` is not `de-DE`. Packages
  must spell tags with hyphens.
- The generated Swift types for the extended contracts take more initializer parameters (`ModelPackage`, `Runtime`,
  `PlaybackOutput`, `ProviderVoice` and the speech types), so call sites that use memberwise initializers have to pass the
  new ones. Labelled compat initializers keep the old `ModelPackage`, `Runtime` and `PlaybackOutput` signatures; use the
  labelled convenience initializer for `ProviderVoice`.
- Nothing on the wire says a voice is neural. An application that wants that label reads `kind` and the model id.
- The package says where files are, not how to get them. Downloads, consent and storage stay with the application, as
  ADR 019 section 5 requires.
- This ADR changes contracts only. It adds no provider, executor or audio output service, and Core AI support is not
  implemented by it.
