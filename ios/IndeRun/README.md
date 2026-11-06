# IndeRun iOS SDK

Swift implementation of IndeRun for iOS and macOS.

The package is split into public API, core engine, contracts, and provider targets:

- `IndeRunContracts` - generated schema-backed models
- `IndeRunCore` - host services, router, registry, and error mapping
- `IndeRunSwift` - public SDK entrypoint
- `IndeRunAppleProviders` - Apple Foundation Models and Apple system speech providers
- `IndeRunOpenAIProviders` - OpenAI-compatible cloud provider
- `IndeRunOnnxProviders` - ONNX Runtime provider family member for developer-supplied/custom
  local models (see `docs/architecture/onnx-runtime-provider-family.md`)
- `IndeRunNeuralSpeech` - neural speech provider for developer-supplied text-to-speech model
  packages, played through the host's `audioOutput` or returned as `audio/wav`
- `IndeRunCoreAIProviders` - neural speech runtime for `coreai` model packages through Apple Core
  AI (iOS 27 / macOS 27); builds to a stub on an SDK without Core AI

Requires iOS 16+ / macOS 14+ (raised from iOS 15 / macOS 12 by `IndeRunOnnxProviders`'s
dependencies: the official ONNX Runtime SPM bindings and `swift-transformers`).

Every target re-exports what its own public API names — `IndeRunCore` re-exports
`IndeRunContracts`, and the SDK and provider targets re-export `IndeRunCore` (see each target's
`Exports.swift`). So one import is always enough for the types in scope: `import IndeRunSwift`
brings `TaskRequest`, `TaskResult` and `StreamRun`, and `import IndeRunOpenAIProviders` brings
`ProviderRegistry` and `ProviderAdapter`. This is the Swift counterpart of the Android SDK's
`api(...)` dependencies, and the two consumer smoke test targets in `Package.swift` hold it in
place.

Products are a separate question from imports. The `IndeRun` product contains the engine and the
contract types, and no providers — unlike the Android SDK, where `IndeRun.initialize()` registers
the on-device provider for you, the Swift initializer takes a registry you built. Add
`IndeRunAppleProviders`, `IndeRunOpenAIProviders`, `IndeRunOnnxProviders` or `IndeRunNeuralSpeech`
for the providers you intend to register; the usage example below needs the first two.

## Usage

```swift
import IndeRunSwift
import IndeRunCore
import IndeRunAppleProviders
import IndeRunOpenAIProviders

let hostServices = DefaultHostServices.make()
let registry = try AppleProviderRegistryFactory.makeDefaultRegistry()
try registry.register(
    OpenAIProvider(
        options: OpenAIProviderOptions(
            model: "gpt-5.2",
            // A backend you control that holds the OpenAI key and relays the
            // Responses stream — not api.openai.com. See Credentials below.
            endpointURL: "https://api.example.com/inderun/openai-responses",
            authContextRef: "openai_primary"
        )
    )
)

let inderun = IndeRun(registry: registry, hostServices: hostServices)
let result = try await inderun.generateText(TextGenerationOptions(
    .prompt("Translate 'Hello' to Spanish"),
    execution: TextExecutionOptions(privacy: .localRequired)
))

let stream = try await inderun.streamText(TextGenerationOptions(.prompt("Explain routing.")))
for try await delta in stream.textStream { print(delta, terminator: "") }
let ending = try await stream.result()
```

`generateText` and `streamText` are extensions on `IndeRunApi`: each compiles to one canonical
`TaskRequest` (`TextGenerationOptions.taskRequest()`) and calls `run(request:)` or `stream(request:)`,
which remain public as the advanced API.

### Speech

```swift
let voices = await inderun.listVoices(locale: "de-AT")

// Speech is opt-in: try registry.register(AppleSystemSpeechProvider())
let playback = try await inderun.speak(SpeakOptions(
    "Der Bus kommt.",
    locale: "de-AT",
    voice: voices.first?.asSpeechVoice()
))
// playback.cancel() stops the audio; result() then returns with .cancelled.
let ending = try await playback.result()
```

`try await inderun.prepare()` is optional and makes the first call fast; see ADR 019. A provider's download starts only
under `registry.register(provider, options: ProviderRegistrationOptions(autoDownload: true))` or
`PrepareRequest(allowDownload: true)`.

`speak` compiles to `stream(request:)` with playback delivery. `generateSpeech` compiles to
`run(request:)` with artifact delivery and returns an `artifact` to read with `readArtifact` and
release with `disposeArtifact`; routing refuses it on a provider that can only play. See
[ADR 018](../../docs/architecture/decisions/018-speech-application-api.md).

`AppleSystemSpeechProvider` plays through the application's audio session and never configures it.
Under the default category the Silent switch mutes speech while the run still completes normally.
An application that must be heard sets a category such as `.playback` before calling `speak`.

### Custom local ONNX models

```swift
import IndeRunOnnxProviders

let modelPackage = ModelPackage(
    files: Files(config: nil, external: nil, filesRequired: ["model.onnx"], tokenizer: "tokenizer.json"),
    format: .onnx,
    id: "my-onnx-model",
    integrity: nil, license: nil, limits: nil, runtime: nil,
    source: Source(ref: "my-model", sourceType: .bundled),
    tasks: ["text_to_text"],
    version: "1.0"
)
try registry.register(OnnxRuntimeAppleProvider(options: OnnxProviderOptions(modelPackage: modelPackage)))
```

Defaults to `SystemOnnxGenAiRuntime` (official ONNX Runtime SPM bindings + `swift-transformers`
tokenization, greedy decoding, no KV-cache reuse). Pass `runtime:` in `OnnxProviderOptions` to
supply a different `OnnxGenAiRuntime` implementation, or `createFixtureOnnxRuntime()` for demos
and tests. See `docs/architecture/onnx-runtime-provider-family.md#apple-implementation` for the
model IO contract, source-type support, and error mapping.

### Neural speech

```swift
import IndeRunNeuralSpeech

// A package with tasks: ["text_to_speech"] and a `speech` block (pipeline, graphs, voices).
let speechPackage = try JSONDecoder().decode(ModelPackage.self, from: packageJSON)
try registry.register(NeuralSpeechProvider(options: NeuralSpeechProviderOptions(
    modelPackage: speechPackage,
    runtime: myRuntime // any NeuralSpeechRuntime; FixtureNeuralSpeechRuntime() for demos and tests
)))
let playback = try await inderun.speak(SpeakOptions("Der Bus kommt.", locale: "de-AT"))
```

`NeuralSpeechProvider` runs a developer-supplied speech model package (its `speech` block names
the pipeline, graphs and voices) through a `NeuralSpeechRuntime` you pass in, so `runtime` is
required. Its id is `local.onnx.speech.apple:<modelPackage.id>`, so one provider per
model registers without clashes. `speak` plays through the host's `audioOutput`
(`DefaultHostServices.make()` provides one; a host without it refuses before any sound with
`audio_output_unavailable`, so the run can fall back), one utterance at a time per provider;
`generateSpeech` returns an `audio/wav` artifact of at most 16 MiB and needs no audio output.
`prepare()` loads the model ahead of the first call.

`OnnxNeuralSpeechRuntime()` (in `IndeRunOnnxProviders`, which re-exports `IndeRunNeuralSpeech`) runs
`pipeline: "articulino"` packages through ONNX Runtime on the CPU execution provider. The package
sits in one directory, as `tools/neural-speech/README.md` writes it:

```
model-package.json        # the ModelPackage; speech.graphs, speech.voices, integrity.checksums
config.json
text.onnx  dit_step.onnx  decoder.onnx
voices/<id>.safetensors
```

The directory comes from the package `source`: `filesystem` (`ref` is the path), `bundled` (relative
to the app bundle's resources) or `app_managed` (relative to Application Support); other source
types are refused with the reason in `availability`. Declared checksums are verified at `prepare()`.
The runtime has no German frontend for digits yet: write numbers as words until it lands.

#### Core AI

```swift
import IndeRunCoreAIProviders

try registry.register(makeCoreAINeuralSpeechProvider(options: CoreAINeuralSpeechProviderOptions(
    modelPackage: coreAIPackage // format: "coreai", speech.pipeline: "articulino"
)))
```

`makeCoreAINeuralSpeechProvider` (in `IndeRunCoreAIProviders`, which re-exports
`IndeRunNeuralSpeech`) registers a `NeuralSpeechProvider` over a `CoreAINeuralSpeechRuntime`, with the
id `local.coreai.speech.apple:<modelPackage.id>`. It runs `format: "coreai"`, `pipeline: "articulino"`
packages laid out like the ONNX ones, with one Core AI asset holding the three graphs in place of
the `.onnx` files, as `tools/neural-speech/prepare_coreai_package.py` writes it:

```
model-package.json        # the ModelPackage; format: "coreai"
config.json
articulino.aimodel        # --asset under its own name, a file or a directory
voices/<id>.safetensors
```

A `speech.graphs` value names the `.aimodel` file and, after a `#`, the inference function in it:
`articulino.aimodel#text`, `articulino.aimodel#dit_step`, `articulino.aimodel#decoder`. Without a `#`
the function is named after the role. The asset must be specialized for the device before it runs,
which can take minutes, and a consented `prepare` specializes it: until then the provider reports
`readiness: not_prepared`, and IndeRun prepares it only under `autoDownload` or
`PrepareRequest(allowDownload: true)`. Core AI needs iOS 27 / macOS 27; below that,
or on an SDK without it, the provider reports `available: false` with the reason, so routing falls
back. As with the ONNX runtime, write numbers as words.

## Streaming

`IndeRun.stream(request:)` returns the run handle, its canonical `StreamEvent` sequence, and a
`cancel(reason:)` hook:

```swift
let run = try await indeRun.stream(request: request)
for try await event in run.events {
    if event.type == "content_delta" { print(event.payload?.text ?? "", terminator: "") }
    if event.type == "terminal" { print(event.payload?.outcome as Any) }
}
```

The HTTP-transport providers need a host that can deliver a response body incrementally.
`DefaultHostServices.make()` provides one; a host without a `streamingHttpClient` still runs
Mode 1, and a stream request that can only be served over HTTP is refused at routing time with a
`streaming_unavailable` reason. The Apple provider does not go through that path — it streams
from the system model with no host HTTP capability involved, and it emits `content_snapshot`
rather than `content_delta`.
`DefaultHostServices.make()` also provides an `AVAudioEngine` `audioOutput` for providers that
synthesize PCM themselves; it leaves the `AVAudioSession` category to the app. The SDK sets no
category, so under the default category playback is muted by the silent switch: an app that must
be heard sets `.playback` itself, as the demo does.

The OpenAI adapter speaks the OpenAI **Responses** API, not chat completions: a custom endpoint
must accept `"stream": true` and emit `text/event-stream` with the Responses event types.

Event types, ordering, the terminal guarantees, cancellation, and fallback are identical on every
SDK and documented once, in [Streaming (Mode 2)](../../docs/streaming.md).

## Media artifacts

A run with `artifact` delivery returns a `MediaArtifact` reference; read the bytes with
`readArtifact(request:)` and release them with `disposeArtifact(artifact:)`
([ADR 017](../../docs/architecture/decisions/017-media-artifacts.md)):

```swift
let result = try await indeRun.run(request: request)
guard let artifact = result.output.artifact else { return }
var audio = Data()
var offset = 0
while true {
    let chunk = try await indeRun.readArtifact(
        request: ArtifactReadRequest(artifactId: artifact.id, maxBytes: nil, offset: offset)
    )
    audio.append(chunk.bytes)
    offset += chunk.bytes.count
    if chunk.done { break }
}
await indeRun.disposeArtifact(artifact: artifact)
```

`AppleSystemSpeechProvider` produces such an artifact with real speech: it renders text with
`AVSpeechSynthesizer.write(_:toBufferCallback:)` and hands it over as `audio/wav` — a canonical
44-byte RIFF/WAVE header followed by mono, 16-bit signed little-endian PCM at the sample rate of the
synthesizer's first buffer (float buffers are clamped and scaled). The artifact reports `byteLength`
and `durationMs` (samples ÷ sample rate). `AppleSystemSpeechArtifactTests` reads one back; it skips
when the host has no English voice or the synthesizer delivers no audio within 10 seconds.

## Credentials

`authContextRef` names a slot in secure platform storage, so the secret never enters a
`TaskRequest` and never sits in source. That is worth having, and it is not the same as making
a key safe to ship: anything an installed app can read, someone with that app can read. A
developer-owned API key does not become safe by being referenced indirectly.

So `authContextRef` is for credentials that legitimately live on the device — a per-user or
per-install token your backend issued. For a key you own, put it behind a backend you control
and point `endpointURL` at that, which is what the example above does. The Web SDK enforces
this; here it is a convention, because a native app can reach any endpoint it likes.

## Notes

- Use the Apple provider for on-device Mode 1 and Mode 2 execution when the system runtime is available.
- Use the OpenAI provider for OpenAI-compatible cloud execution through a host-provided HTTP client.
- Use the ONNX Runtime provider for developer-supplied/custom local models.

## Route planner

Provider selection is not implemented in Swift. `Router` collects the provider snapshots and
maps the result back onto adapters, but the ranking, constraint, and rejection rules all come
from the shared Rust core (`rust/inderun-route-core`), which every platform shares. There is
no second planner behind it: if the core cannot answer, routing fails with an `Internal`
error rather than routing by a second set of rules.

The core is linked from `Frameworks/InderunRouteCoreFFI.xcframework`, declared as a
`binaryTarget` in the root `Package.swift`. That XCFramework is committed to git: SwiftPM has
no publish step, so consumers resolving `.package(url:from:)` get exactly what the git tag
contains. `swift build` therefore works on a plain checkout with no Rust toolchain installed.

Rebuild it — and commit the result — whenever the route core changes:

```sh
pnpm build:route-core-apple
```

That needs `rustup` (which installs the pinned toolchain from `rust-toolchain.toml` on demand,
along with the five Apple targets) and the Xcode command line tools. Commit the regenerated
`InderunRouteCoreFFI.provenance.json` alongside the framework. The same command also builds
`InderunSpeechTextFFI.xcframework` (the German speech text normalizer, linked only by
`IndeRunNeuralSpeech`); commit its manifest too.

Because the framework is an executable in git, CI does not take it on trust:

```sh
pnpm verify:route-core-apple
```

checks it against that manifest — the compiler that built it, SHA-256 hashes of every source it
was built from, hashes of every packaged file — and validates each slice's architectures,
deployment target, exported FFI symbols, install name, and linked libraries. `swift.yml` runs
this before rebuilding anything, then rebuilds from source and runs the Swift suite a second
time against the result; `release.yml` gates the release on it, since the git tag is the Swift
distribution channel. A Cargo dependency bump alone will fail verification until the framework
is rebuilt: a lockfile change can alter the compiled core.

## Commands

The SwiftPM manifest lives at the repository root (`Package.swift`); these sources are
referenced from there. Run the package commands from the repo root:

```sh
swift build
swift test
```
