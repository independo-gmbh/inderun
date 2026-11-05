# Neural Speech Provider Family

Neural speech adapters synthesize audio from a developer-supplied speech model package, in process, and play it through
the host or return it as a WAV artifact. They are the first consumers of the `audioOutput` host service
([ADR 021](./decisions/021-audio-output-host-service.md)) and the first `text_to_speech` providers whose voices are
files inside a model package rather than a platform catalog. The package and voice contracts, the timing origin and the
decisions behind them are in [ADR 020](./decisions/020-neural-speech-and-model-packages.md); the speech application API
is in [ADR 018](./decisions/018-speech-application-api.md). Playback semantics follow the
[system speech family](./system-speech-provider-family.md), which this document does not repeat.

| Platform  | Default provider id         | Where                                  | Playback | Artifact    |
| --------- | --------------------------- | -------------------------------------- | -------- | ----------- |
| Web       | `local.onnx.speech.web`     | `@independo/inderun-web/neural-speech` | Yes      | `audio/wav` |
| iOS/macOS | `local.onnx.speech.apple`   | `IndeRunNeuralSpeech`                  | Yes      | `audio/wav` |
| Android   | `local.onnx.speech.android` | `inderun-neural-speech`                | Yes      | `audio/wav` |

## Scope

What ships now is the provider on all three SDKs, the runtime seam it delegates to, a deterministic fixture runtime, the
text frontend and the WAV encoder. **No runtime that runs a real model ships yet.** The ONNX Runtime executor and the
first model pipeline (Articulino) follow in #260 PR 4, and Apple Core AI in PR 5. Until then only an injected runtime
synthesizes; the fixture runtime serves demos and tests. `runtime` is therefore a required option, not a defaulted one.

## Ids and registration

An instance serves one model package. Its id is `<default id>:<modelPackage.id>` unless the caller passes `id`, so an app
registers one provider per model without clashing ids, and the descriptor's `model` is the package id. Like system
speech, the family is registered explicitly: default registries stay unchanged, because the router probes every
registered provider on every request.

- **Web.** `createIndeRunWeb({ neuralSpeech: [{ modelPackage, runtime }] })`, or `new NeuralSpeechWebProvider(options)`
  from the subpath. Each entry also takes `ProviderRegistrationOptions`.
- **Apple.** `NeuralSpeechProvider(options:)` taking a `NeuralSpeechProviderOptions`, with
  `NeuralSpeechProvider.defaultId`.
- **Android.** `NeuralSpeechProvider(modelPackage, runtime, id, timeoutMs)`, with `DEFAULT_ID` in its companion.

## Options

| Option         | Meaning                                                                                                                                      |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `id`           | Replaces the composed id.                                                                                                                    |
| `modelPackage` | The package. Its `speech` block names the pipeline, graphs, sample rate and voices.                                                          |
| `runtime`      | Required. Executes the package.                                                                                                              |
| `timeoutMs`    | Bounds the synthesis until the run commits. A request's `constraints.timeoutMs` wins; zero or less is unbounded. Swift spells it `timeout`. |

The budget means what `constraints.timeoutMs` means in the request schema: the time until the run commits, not the
duration of the audio it plays. It counts from the start of synthesis; the turn wait and the model load do not count.
For playback it bounds the wait for the first chunk only. After that commit nothing times out, and a runtime that stalls
is ended only by a cancel, as with the system speech providers. For an artifact it bounds the whole synthesis, across
sentences, up to the handoff in `finish()`: one absolute deadline, checked again before the artifact is created and
immediately before `finish()`, so encoding and writing the WAV count too. Expiry throws `Timeout` at once, without
waiting for the runtime, and always before commit (an artifact writer already created is aborted), so the run can fall
back.

## The seams

The provider does no inference. It delegates to a `NeuralSpeechRuntime` with three members: `availability(package)`,
`prepare(package)` and `synthesize(input)`, which is called once per sentence and returns that sentence's `PcmChunk`s.
A chunk is mono 16-bit PCM with its `sampleRate` and an `isLast` flag set on the final chunk of a sentence. The chunk's
rate must equal the package's `speech.sampleRate`; IndeRun never resamples, and a chunk with another rate is `Internal`.

The provider consumes (copies or hands to the host) a chunk's samples before the yield returns, so a runtime may reuse
its buffer afterwards.

`synthesize` may be called concurrently: artifact runs do not wait for the playback turn, and two providers may share
one runtime instance. A runtime must serialize or isolate its own sessions.

A runtime signals a failure with `NeuralSpeechRuntimeError` and a kind (`capability`, `unavailable`, `timeout` or
`internal`), which the provider maps onto the matching error class. Anything else a runtime throws is `Internal`.

`SpeechGraphExecutor` and `SpeechTensor` are the seam beneath a runtime: it loads a package's graph files and runs one
graph by role. The ORT and Core AI executors implement it in PR 4 and PR 5; a pipeline sits on top and produces the
chunks. Nothing in the provider calls it.

**Where refusals live.** `limits.memBytes` and an unknown `speech.pipeline` are refused by the runtime's `availability`,
not by the provider. The runtime is what allocates and knows the platform, so only it can say whether the package fits
and whether it can run the pipeline. The provider passes the reason through verbatim.

`availability` must not load anything; `prepare` loads. On Kotlin, a runtime must move inference off the collector's
dispatcher (`flowOn`), because `speak` may collect on the main dispatcher.

## Capabilities

Checks run in this order, and the first that fails decides the reason: package validation
(`getModelPackageValidationIssues` from Core), then the task (`text_to_speech`, and a `speech` block present), then
`speech.channels` (the provider plays mono only, so any other count is `unsupported channels: <n>`), then the model
source type, then the runtime's `platforms`, then `runtime.availability`, then any remembered load failure. An
`availability` that throws reports the provider unavailable (`runtime availability failed: <message>`) rather than
failing the capability check of every provider on the engine.

| Source type    | Web | Apple and Android |
| -------------- | --- | ----------------- |
| `registry`     | Yes | No                |
| `bundled`      | Yes | Yes               |
| `programmatic` | Yes | Yes               |
| `app_managed`  | Yes | Yes               |
| `filesystem`   | No  | Yes               |

Readiness is `cold` until `prepare` has loaded the model. Voices are one `ProviderVoice` per `speech.voices[]` entry, with
all its `locales`, never `networkRequired`. The task's `locales` are the union across voices. IndeRun stores and downloads
nothing (ADR 019); the developer supplies the package files.

## Playback and artifact

**Playback** needs the host's `audioOutput`. The provider takes its turn, then refuses before commit, in this order: a
request without `speech` or with another delivery mode is a `CapabilityMismatch`; a host without `audioOutput` is a
`CapabilityMismatch` with `details.code: "audio_output_unavailable"`; a bound voice the package lacks is
`voice_not_available`. Failures from `audioOutput.open()` propagate as thrown (`audio_format_unsupported`,
`audio_not_allowed`, `audio_output_failed`).

Cancellation is `hard`: audio stops at once; residual compute is bounded to the in-flight sentence and is never audible.
The commit happens immediately before the first `write()`, so a cancel before it returns quietly with no result and no
sound. After the commit a cancel stops the audio session at once, including while `drain()` is waiting, ends the
runtime's iteration, and returns quietly; the engine owns the `cancelled` terminal. Any error after the commit
(a runtime failure, `audio_output_interrupted`) is thrown and not retried, so the text is never spoken twice. A normal
ending is `drain()` then `stop()`. One utterance plays at a time per instance, first in first out.

**Artifact** delivery needs no `audioOutput`. PCM is buffered in memory and the WAV is written once, because the engine's
artifact writer is append-only and a WAV header needs the final size. When the file would exceed
`MAX_ARTIFACT_BYTES` (16 MiB, about 5.5 minutes at 24 kHz, a number that duplicates the engine default on purpose),
synthesis stops and the provider throws `Unavailable` with `details.code: "artifact_too_large"` before the artifact is
committed, so the run may fall back. `stream()` serves artifact delivery as well as playback, and in both cases emits
only its lifecycle: no content events, ending with `result` or quietly when cancelled.

## Timing

A finished playback reports `timing` with `firstChunkMs`, `firstAudioMs` and `durationMs`, all in milliseconds from one
origin, the moment the provider received the request.

- `firstChunkMs` is when the first chunk arrived from the runtime.
- `firstAudioMs` = (instant before `open()` was called − `receivedAt`) + `session.firstAudioMs()`, which every host
  measures from the start of its `open()`, so a slow open is counted once. It is read after `drain()`, and is absent
  when the host reports none; a stopped run reports none.
- `durationMs` is the total frames over the sample rate.

On a real host `firstAudioMs` is not smaller than `firstChunkMs`. The fixture audio output uses a virtual clock that
cannot observe that ordering, so the conformance catalog does not pin it. On the Web, `firstAudioMs` carries the caveat
in ADR 021 about what the browser lets the output observe.

## Error codes

| Code                       | Where it comes from                                                        |
| -------------------------- | -------------------------------------------------------------------------- |
| `audio_output_unavailable` | The host has no `audioOutput`; playback is refused before commit.          |
| `voice_not_available`      | The bound voice is not in the package; refused before commit.              |
| `artifact_too_large`       | The WAV would pass 16 MiB; thrown before the artifact commits.             |
| `audio_format_unsupported` | `audioOutput.open()` cannot take the package's sample rate; propagated.    |
| `audio_not_allowed`        | The platform refuses audio until the app is allowed to play (a browser needs a user gesture); propagated from `open()`. |
| `audio_output_failed`      | The host output failed to start or render; propagated.                     |
| `audio_output_interrupted` | The output was interrupted after commit; thrown, not retried.              |

A runtime's error kinds map to `CapabilityMismatch`, `Unavailable`, `Timeout` and `Internal`. The gesture requirement on the Web comes
from the audio output, not from this family.

## The text frontend

Text is split into sentences, each of which is one `synthesize` call, so the first sentence plays while later ones are
still synthesizing. The rule is the same on every SDK and pinned by a shared fixture: split at newlines and after a run of
`.`, `!`, `?` or `…` that is followed by whitespace or the end of the text. "Whitespace" is exactly the ECMAScript `\s`
set on every SDK, not the platform's own notion. There is no abbreviation handling, so `z.B. Hallo` is two sentences.
Normalizers that expand numbers or abbreviations belong to a pipeline and arrive with PR 4.

`GraphemeTokenizer` lowercases a sentence in NFC form, maps each code point through the package vocabulary and drops code
points the vocabulary lacks.

## Fixtures

Two shared catalogs pin behaviour across the SDKs, listed in [speech-conformance.md](../speech-conformance.md):

- [`neural-frontend.json`](../../contracts/fixtures/speech/neural-frontend.json): text to sentences to token ids.
- [`neural-speech-lifecycle.json`](../../contracts/fixtures/speech/neural-speech-lifecycle.json): commit placement,
  cancel, missing audio output, the artifact cap and timing.

Each SDK's runner is guarded so that a case added to a catalog without a handler fails the build instead of passing
unrun. `FixtureNeuralSpeechRuntime` (`createFixtureNeuralSpeechRuntime` on the Web) is the deterministic runtime they run
against: a sine tone sized by sentence length, which records every `synthesize` call and honours cancellation between
chunks.

## Placement

Each member depends on Core only. None adds a dependency on ONNX Runtime or any other third-party library.

- **Web.** `packages/inderun-web/src/providers/neural-speech`, exported at `@independo/inderun-web/neural-speech`.
- **Apple.** The `IndeRunNeuralSpeech` target and product. `SpeechWAV` is public in `IndeRunCore`.
- **Android.** The `inderun-neural-speech` Gradle module. `SpeechWavEncoder` lives in it.

`getModelPackageValidationIssues` lives in Core on Swift and Kotlin, so the ONNX and neural speech families share one
validator.

## Implementation detail

Algorithms, gate ordering, buffering and threading are in code comments next to the code, not here:

- Web: [`providers/neural-speech`](../../packages/inderun-web/src/providers/neural-speech)
- Apple: [`IndeRunNeuralSpeech`](../../ios/IndeRun/Sources/IndeRunNeuralSpeech)
- Android: [`inderun-neural-speech`](../../android/inderun-neural-speech/src/main/kotlin/app/independo/inderun/providers/neuralspeech)
