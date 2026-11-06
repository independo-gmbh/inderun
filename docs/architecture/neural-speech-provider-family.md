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
| iOS/macOS | `local.coreai.speech.apple` | `IndeRunCoreAIProviders`               | Yes      | `audio/wav` |

## Scope

What ships now is the provider on all three SDKs, the runtime seam it delegates to, a deterministic fixture runtime, the
text frontend and the WAV encoder, and a first real runtime: an ONNX Runtime `SpeechGraphExecutor` (CPU execution
provider only) composed with the Articulino pipeline, on every SDK (#260 PR 4a), and the Apple Core AI runtime
(`IndeRunCoreAIProviders`, iOS/macOS 27, [ADR 022](./decisions/022-core-ai-runtime.md)). The German text frontend
(numbers, dates, abbreviations) follows in PR 4b. `runtime` stays a required option, not a defaulted
one: the app composes the runtime it wants and passes it in, and the fixture runtime still serves demos and tests.

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
- **Apple, Core AI.** `makeCoreAINeuralSpeechProvider(options:)` in `IndeRunCoreAIProviders`, with
  `NeuralSpeechProvider.coreAIDefaultId` (`local.coreai.speech.apple`). It builds the same provider around the composed
  Core AI runtime, so `runtime` is not passed.

## Options

| Option         | Meaning                                                                                                                                      |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `id`           | Replaces the composed id.                                                                                                                    |
| `modelPackage` | The package. Its `speech` block names the pipeline, graphs, sample rate and voices.                                                          |
| `runtime`      | Required. Executes the package.                                                                                                              |
| `timeoutMs`    | Bounds the synthesis until the run commits. A request's `constraints.timeoutMs` wins; zero or less is unbounded. Swift spells it `timeout`. |

`makeCoreAINeuralSpeechProvider` takes `CoreAINeuralSpeechProviderOptions` (`id`, `modelPackage`, `timeout`) plus
`CoreAINeuralSpeechRuntimeOptions`:

| Runtime option      | Meaning                                                                          |
| ------------------- | -------------------------------------------------------------------------------- |
| `noise`             | The noise source of the pipeline; absent uses the pipeline's default.            |
| `speed`             | Speech speed factor, default 1.0.                                                |
| `pauseMs`           | Silence after each sentence, default 150.                                        |
| `deviceMemoryBytes` | Overrides the device memory that `limits.memBytes` is checked against (tests).   |

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

`NeuralSpeechAvailability` carries an optional `readiness` hint (`not_prepared` or `cold`) for a runtime whose model
is not usable yet, for example one that must specialize a model for the device. It is additive: absent means the
provider's own `cold`.

`synthesize` may be called concurrently: artifact runs do not wait for the playback turn, and two providers may share
one runtime instance. A runtime must serialize or isolate its own sessions.

A runtime signals a failure with `NeuralSpeechRuntimeError` and a kind (`capability`, `unavailable`, `timeout` or
`internal`), which the provider maps onto the matching error class. Anything else a runtime throws is `Internal`.

`SpeechGraphExecutor` and `SpeechTensor` are the seam beneath a runtime: it loads a package's graph files and runs one
graph by role. `SpeechTensor` is `f32` or `i64` on every SDK and nothing else. The ORT executor implements the seam
and the Core AI executor on Apple; a pipeline sits on top and produces the chunks. Nothing in the provider calls it.
A `load` replaces the graphs an earlier load left; a pipeline runtime calls it once per successful `prepare` of a
package (`prepare` is idempotent on success) and again only after a failed one.

`SpeechPackageFiles` is the seam beside it: it hands the pipeline the bytes of the non-graph files a package names
(config, voices, frontend assets). Graphs are opened by the executor: the Web executor reads them through the same
`SpeechPackageFiles`, the Swift and Kotlin executors open them in the package directory they are given. Every reader
refuses a file name that is empty, absolute or contains `..`. The Web ships `createUrlPackageFiles` for packages served
over HTTP; Swift and Kotlin read the package directory. An app may inject its own implementation.

**Composed ORT runtime.** The ORT module of each SDK composes its executor with the Articulino pipeline into one
`NeuralSpeechRuntime`, so the app passes a single value as the provider's `runtime`. No ONNX Runtime type appears in a
public API.

| Platform | Composition                                                                                                                                    |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| Web      | `createOnnxNeuralSpeechRuntime()`. `onnxruntime-web` is an optional peer dependency, reached structurally; files come from `createUrlPackageFiles` or an injected `SpeechPackageFiles`. |
| Apple    | `OnnxNeuralSpeechRuntime()` in `IndeRunOnnxProviders`, which re-exports `IndeRunNeuralSpeech`.                                                  |
| Android  | `OnnxNeuralSpeechRuntime(context)` in `inderun-onnx-providers`, which depends on `inderun-neural-speech` with `api`.                            |

The executor runs CPU only, with one session per graph; Swift and Kotlin create and run the sessions on the existing ORT
execution queue or dispatcher, the Web on onnxruntime-web's wasm backend. One pipeline runtime and its sessions are
kept per package id and version and live as long as the composed runtime. `availability` stays static: a missing peer
module, a missing graph file or an ORT load failure surfaces from `prepare` as `available: false` with the reason (never
thrown), and the provider then reports the remembered load failure.

**Where refusals live.** An unknown `speech.pipeline` is refused by the runtime's `availability`, not by the provider.
`limits.memBytes` is refused there too, by the composed ORT runtime on Apple (against
`ProcessInfo.physicalMemory`) and Android (against `ActivityManager.MemoryInfo.totalMem`), as
`insufficient memory: package needs <N> bytes, device has <M> bytes`, at `availability`, `prepare` and `synthesize`
before anything loads. The Web has no host memory API and does not enforce it. The runtime is what allocates and knows
the platform, so only it can say whether the package fits and whether it can run the pipeline. The provider passes the
reason through verbatim.

A `config.json` or voice bundle with a value out of range refuses at `prepare`
(`pipeline config malformed: <key> <why>`, `voice file malformed: <voice id>: letter_rate out of range`), and a graph
output of the wrong size or with non-finite durations ends the sentence as `internal`, the same on every SDK. The
ranges live next to the parsers (`articulino/config.ts`, `ArticulinoConfig`).

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

Readiness is `cold` until `prepare` has loaded the model. While the model is not loaded, a runtime's `readiness` hint
replaces `cold` on the task and on every voice, so `not_prepared` reaches routing (the planner then skips the package
without `autoDownload` / `allowDownload`, ADR 019); after a successful `prepare` readiness is absent (`ready`) whatever
the hint says. Voices are one `ProviderVoice` per `speech.voices[]` entry, with
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
Normalizers that expand numbers or abbreviations belong to a pipeline; the German one arrives with PR 4b.

`GraphemeTokenizer` lowercases a sentence in NFC form, maps each code point through the package vocabulary and drops code
points the vocabulary lacks.

## The Articulino pipeline

The first pipeline, `speech.pipeline` `articulino`, turns text into 24 kHz PCM with three graphs and a precomputed voice.
It is adapted from [eigenhand/articulino-onnx](https://github.com/eigenhand/articulino-onnx) (Apache-2.0). The pipeline
lives in the runtime-free neural speech modules (`articulino/` on each SDK) so Core AI reuses it; the host math is pinned
by [`articulino-pipeline.json`](../../contracts/fixtures/speech/articulino-pipeline.json).

- **Graph roles.** On the device a package carries exactly `text`, `dit_step` and `decoder`. The upstream `encoder` and
  `voice` graphs never appear in a `ModelPackage`: they run offline in the preparation tool.
- **The `text_mask` rewrite.** Upstream's `text` graph takes `text_mask` as bool, which the ONNX Runtime Objective-C
  binding cannot feed (`ORTTensorElementDataType` has no bool). Rather than widen `SpeechTensor`, the tool rewrites
  `text.onnx` once, offline: the input becomes int64 and a `Cast(to=BOOL)` node feeds the original consumer. The packaged
  file is therefore not byte-identical to upstream; its sha256 is in `integrity.checksums`. Every SDK feeds `text_mask`
  as int64.
- **The `config` asset.** The upstream `config.json` is referenced as `speech.frontend.assets.config`. The pipeline reads
  its constants (sample rate, latent size, charset, languages, flow times, post-processing) there at `prepare`.
- **Voices.** A voice is one safetensors file (`voices[].file`) in format `inderun.articulino.voice/1`: f32 tensors
  `voice_tokens`, `voice_vector`, `voice_cache`, `prompt_latents` and `letter_rate`. The prompt length is read from
  `voice_cache`'s shape, never stored twice. A wrong format or a missing tensor refuses at `prepare` with a reason naming
  the voice; a package whose voice file is absent is unavailable. No speaker encoder runs on the device.
- **Synthesis granularity.** One `PcmChunk` per sentence, `isLast` set, followed inside that chunk by `pauseMs` (default
  150 ms) of silence. A sentence over 180 letters is split before synthesis at the last `, ; : -` or space after letter
  60 and returned as one chunk. A sentence whose letters are all outside the charset yields only the pause.
- **Cancellation.** The pipeline checks for cancel before each graph call, so no graph runs after a cancel.

Limitations of this pipeline today:

- No normalizer. Digits are charset letters and reach the model unspelled, so write numbers as words until the German
  frontend (PR 4b). English has no frontend upstream either.
- Latency is sentence-level: the first audio is available only after a whole sentence is synthesized.
- Outlier retry and rate equalisation beyond the bundle's `letter_rate` are not implemented.
- The composed runtimes have no `close()`; sessions live as long as the runtime, and the cache key (`id@version`) ignores
  `source.ref`.
- CPU execution provider only. CoreML, NNAPI and WebGPU are not used (see the findings below).

**Preparing a package.** [`tools/neural-speech/`](../../tools/neural-speech/README.md) (Python, not run in CI) takes the
upstream ONNX release and a voice recording and writes the package directory (`model-package.json`, `config.json`, the
three graphs and `voices/<id>.safetensors`), and it generates the fixture. Its README has the commands. Real-model tests
on each SDK read that directory from `INDERUN_NEURAL_SPEECH_MODEL_DIR` (web, Swift) or the instrumentation argument
`neuralSpeechModelDir` (Android) and skip when it is absent.

## Core AI runtime

The Apple Core AI runtime ([ADR 022](./decisions/022-core-ai-runtime.md)) runs a `format: "coreai"` package through the
same Articulino pipeline as the ORT runtimes, with a `CoreAISpeechGraphExecutor` beneath it. It exists only on iOS and
macOS 27; on an older Xcode the module builds to a stub, and on an older OS it reports `available: false` with
`Core AI requires iOS 27 / macOS 27`.

- **Graph references.** `speech.graphs` values are `<file>.aimodel` (the function is named after the role) or
  `<file>.aimodel#<function>`. One `AIModel` is loaded per distinct file and one function per role. The asset name may
  not contain `#`, and an `.aimodel` may be a file or a directory.
- **What `availability` checks.** Core AI is available, `format` is `coreai`, the pipeline is `articulino`,
  `limits.memBytes` fits the device, the package directory resolves, the Articulino metadata is complete (roles,
  frontend config, voice files), and every graph file, the config file and every voice file are present. It loads and specializes nothing. The order of the
  checks is in the code comments.
- **Readiness is the specialization state.** `not_prepared` means some graph file is not yet in `AIModelCache.default`,
  `cold` means every file is cached, and the provider reports `ready` after a successful `prepare`. Only `prepare`
  specializes; `synthesize` on a package that is not prepared is refused with `model not prepared: <id@version>`.
  Before specializing, `prepare` reads each asset's function list and refuses a role whose function is missing
  (`graph function missing: <role>: <function> in <file>`). After a successful `prepare` the runtime reports `cold`
  without consulting the cache.
- **Consent.** `autoDownload` and `prepare({ allowDownload: true })` authorize specialization as they authorize a
  download (ADR 019, amended by ADR 022): consent for a long preparation, not just for bytes. Without them the planner
  skips the package.
- **Cache policy.** The cache keeps Core AI's `.default`, purgeable, policy. After a purge the next `availability` of a
  runtime that has not prepared the package in this process reports `not_prepared` again and the next consented
  `prepare` specializes again. Loaded models stay in memory for the session. Specialized artifacts are bound to the
  device and the OS version.
- **The package.** [`prepare_coreai_package.py`](../../tools/neural-speech/README.md) writes `model-package.json`
  (`format` and `variant` `coreai`, `runtime.minOsVersion` `27.0`), `config.json`, the `.aimodel` under its own name
  and `voices/<id>.safetensors`, with `integrity.checksums` for every file but the manifest. The package ships
  `bundled` or `app_managed`; IndeRun never downloads it. The gated real-model tests read the directory from
  `INDERUN_COREAI_MODEL_DIR` and skip without it.
- **Conversion.** The `.aimodel` comes from the upstream PyTorch checkpoint through Apple's `coreai-torch`
  (`torch.export` with bounded `Dim`s, `run_decompositions`, one `TorchConverter` entrypoint per role, `to_coreai()`,
  `save_asset`). The entrypoints are `text`, `dit_step` and `decoder`, and `text_mask` is int64 and cast to bool inside
  the exported program. The full chain is in ADR 022 section 5.
- **Device numbers.** The asset hash, the shape bounds, the specialization time and the realtime factor are pending
  spike 0b; nothing here is measured on a device.

Follow-ups: a typed preparation kind on the contracts, a CI test of a successful `prepare`, and specialization of
unused `speech.graphs` entries. The code is in
[`IndeRunCoreAIProviders`](../../ios/IndeRun/Sources/IndeRunCoreAIProviders).

## Spike and device findings

All runs use the int8 package (`text` 26 MB, `dit_step` 28 MB, `decoder` 33 MB), one voice, the sentence "Ich habe
Hunger." (1.79 s of audio), the CPU execution provider and a model prepared before timing. "x realtime" is audio seconds
over wall seconds. The desktop, emulator and simulator rows say the graphs load and run everywhere; only the device
rows say a phone is fast enough.

| Platform and runtime                                   | Load and run          | Wall time for 1.79 s            | Realtime factor |
| ------------------------------------------------------ | --------------------- | ------------------------------- | --------------- |
| Python reference, onnxruntime 1.31.1, Apple silicon, 4 threads | all graphs        | 58-111 ms (first of three sentences)   | 28-46x over three sentences |
| Web, onnxruntime-web 1.31.1 (wasm), Node 26            | all graphs            | 179 ms                          | about 10x       |
| Apple, onnxruntime-swift-package-manager 1.24.2, macOS 27.2, debug build | all graphs | 74 ms (provider end to end, `firstChunkMs`) | about 24x |
| Android, onnxruntime-android 1.31.0, arm64-v8a emulator, API 34 | all graphs  | 187-209 ms                      | about 9x        |
| iOS simulator, iPhone 17 Pro, iOS 26.2, arm64, onnxruntime-swift-package-manager 1.24.2 | all graphs | 95 ms | about 19x |
| iPhone 15 (A16), iOS 27.2, onnxruntime-swift-package-manager 1.24.2, demo app Release build | all graphs | 61-79 ms (warm, cold) | about 23-29x; 26-33x over six DE/EN sentences of 1.5-4.4 s |
| Midrange Android                                       | pending (owner)       | pending (owner)                 | pending (owner) |

- In the reference, `dit_step` dominates (35-64 ms for four steps), then `decoder` (21-38 ms) and `text` (3-9 ms).
- No ORT operator error occurred on any platform. The fp32 set was run on the desktop only, not on the SDKs.
- The CoreML execution provider (MLProgram) partitions the graphs into three to five subgraphs and fails to compile one
  (`'mps.matmul' op contracting dimensions differ 1 & 512`), so this PR uses the CPU provider only.
- iPhone 15, measured 2026-11-05 over five rounds of six sentences: `prepare` 347 ms, warm wall time 54-139 ms for
  1.5-4.4 s of audio (realtime factor 0.030-0.038), the first round about 20% slower, thermal state nominal throughout,
  peak process footprint 233 MB. The pipeline returns one chunk per sentence, so time to first audio equals wall time.
- Device runs are opt-in and not part of CI: with a phone at hand,
  [`ios_device_bench.sh`](../../tools/neural-speech/README.md#time-a-package-on-an-iphone) builds the demo app with a
  temporary benchmark hook, runs it on the phone and reverts the hook. Run it when a model, a runtime or the pipeline
  changes in a way that could move these numbers.
- The real-phone rows are what gate the demo's default model.

## Demo: Voices lab

The web, Android and iOS demos carry an opt-in Voices lab (off by default: `VITE_INDERUN_VOICES_LAB=1` on the web, a
settings toggle on Android, a toggle on the iOS Speech tab). It lets a developer download a neural model and its voices
on a device and speak through this family, with the package the app builds from the catalog rather than a hand-prepared
directory. The lab is a demo, not SDK surface: nothing in the SDKs changes for it.

- **Catalog.** [`neural-model-catalog.json`](../../contracts/fixtures/speech/neural-model-catalog.json) lists the
  entries, their files and voices, checksums and review status. Every download asks for consent and is verified against
  the catalog's checksums. The entry-to-`ModelPackage` mapping is pinned by
  [`catalog-to-package.json`](../../contracts/fixtures/speech/catalog-to-package.json) and run by each demo
  ([speech-conformance.md](../speech-conformance.md)). The Core AI entry stays `manual_install` until its conversion
  record exists.
- **Assets.** The upstream weights are fetched from Hugging Face at a pinned revision. The derived `text.onnx` and the
  seven voices are built by
  [`build_demo_assets.py`](../../tools/neural-speech/README.md) and hosted in the GitHub release
  `neural-speech-assets-1`, which the repository owner publishes. GitHub sends no CORS headers, so the web demo fetches
  those files through the [demo proxy](../../packages/inderun-demo-proxy/README.md) `GET /assets` route and stores them
  in OPFS.
- **Demos.** [Web](../../packages/inderun-web-demo/README.md), [Android](../../android/inderun-demo-app/README.md) and
  [iOS](../../ios/SampleApps/IndeRunDemo/README.md) describe how to enable and use it.

## Fixtures

Three shared catalogs pin behaviour across the SDKs, listed in [speech-conformance.md](../speech-conformance.md):

- [`neural-frontend.json`](../../contracts/fixtures/speech/neural-frontend.json): text to sentences to token ids.
- [`neural-speech-lifecycle.json`](../../contracts/fixtures/speech/neural-speech-lifecycle.json): commit placement,
  cancel, missing audio output, the artifact cap and timing.
- [`articulino-pipeline.json`](../../contracts/fixtures/speech/articulino-pipeline.json): the Articulino host math
  (letters, durations, frame condition, flow steps, decode, long-sentence split, cancel) against scripted executor
  outputs.

Each SDK's runner is guarded so that a case added to a catalog without a handler fails the build instead of passing
unrun. `FixtureNeuralSpeechRuntime` (`createFixtureNeuralSpeechRuntime` on the Web) is the deterministic runtime they run
against: a sine tone sized by sentence length, which records every `synthesize` call and honours cancellation between
chunks.

## Placement

The neural speech members (provider, seams, pipeline, safetensors reader, `SpeechPackageFiles`) depend on Core only and
add no dependency on ONNX Runtime or any other third-party library. The ORT executor and the composed runtime live in the
existing ONNX modules.

- **Web.** `packages/inderun-web/src/providers/neural-speech`, exported at `@independo/inderun-web/neural-speech`, with
  `articulino/` for the pipeline. The ORT executor and composed runtime are in the same directory and reach
  `onnxruntime-web`, an optional peer dependency, structurally.
- **Apple.** The `IndeRunNeuralSpeech` target and product (with `Articulino/`). `SpeechWAV` is public in `IndeRunCore`.
  The ORT executor and composed runtime are in `IndeRunOnnxProviders`; the Core AI executor and composed runtime are
  in `IndeRunCoreAIProviders`.
- **Android.** The `inderun-neural-speech` Gradle module (with `articulino/`). `SpeechWavEncoder` lives in it. The ORT
  executor and composed runtime are in `inderun-onnx-providers`.

`getModelPackageValidationIssues` lives in Core on Swift and Kotlin, so the ONNX and neural speech families share one
validator.

## Implementation detail

Algorithms, gate ordering, buffering and threading are in code comments next to the code, not here:

- Web: [`providers/neural-speech`](../../packages/inderun-web/src/providers/neural-speech)
- Apple: [`IndeRunNeuralSpeech`](../../ios/IndeRun/Sources/IndeRunNeuralSpeech)
- Android: [`inderun-neural-speech`](../../android/inderun-neural-speech/src/main/kotlin/app/independo/inderun/providers/neuralspeech)
- Core AI executor and composed runtime: [`IndeRunCoreAIProviders`](../../ios/IndeRun/Sources/IndeRunCoreAIProviders)
- ORT executor and composed runtime: the same Web directory, [`IndeRunOnnxProviders`](../../ios/IndeRun/Sources/IndeRunOnnxProviders)
  and [`inderun-onnx-providers`](../../android/inderun-onnx-providers/src/main/kotlin/app/independo/inderun/providers/onnx)
- Package and voice preparation: [`tools/neural-speech`](../../tools/neural-speech/README.md)
