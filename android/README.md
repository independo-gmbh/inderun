# IndeRun Android

Android workspace for the IndeRun SDK, host services, provider adapters, and demo app.

## Modules

- `inderun-kotlin` - public Android SDK entrypoint
- `inderun-core` - platform host services
- `inderun-contracts` - generated Kotlin contract models
- `inderun-mlkit-providers` - on-device ML Kit GenAI provider (Mode 1 and Mode 2)
- `inderun-openai-providers` - OpenAI-compatible cloud provider
- `inderun-onnx-providers` - ONNX Runtime provider for developer-supplied local models
  (`local.onnx.genai.android`)
- `inderun-neural-speech` - neural text-to-speech with a developer-supplied speech model package
  (`local.onnx.speech.android:<package id>`), played through the host's audio output or written as
  `audio/wav`; registered explicitly, with a `NeuralSpeechRuntime` the app supplies
- `inderun-system-speech-providers` - system text-to-speech through `android.speech.tts.TextToSpeech`
  (`android_system_speech`), registered explicitly
- `inderun-demo-app` - demo app for reviewing the Mode 1, Mode 2 and speech flows
- `inderun-consumer-smoke` - not published; compiles the README quick start against a single
  `implementation(project(":inderun-kotlin"))` so a missing `api(...)` edge fails here rather
  than in a consumer's app

### Published dependency scopes

A dependency whose types appear in a module's public signatures is declared with `api(...)`,
not `implementation(...)`: Gradle keeps `implementation` dependencies off consumers' compile
classpath, and the publish plugin maps them to POM `runtime` scope. `inderun-kotlin` therefore
brings `inderun-contracts`, `inderun-core` and `kotlinx-coroutines-core` with it, and an app
needs no further declarations to name `TaskRequest`, `TaskResult` or `Flow<StreamEvent>`.

The resulting scopes are pinned in `published-api-dependencies.txt` and checked in CI:

```sh
pnpm verify:android-api-deps            # verify
node scripts/verify-android-api-dependencies.mjs --update   # after an intentional change
```

## Host requirements

What the build of an app (or a library such as a Capacitor plugin) needs before it can depend on
`app.independo.inderun:inderun-*`. Every row except JDK was measured against a Capacitor 8-shaped app (AGP 8.13.0,
Gradle 8.14.3, compileSdk 36) and against AGP 9.1.0 with Gradle 9.3.1; the JDK row restates AGP's own requirement and
was not measured:

| Requirement | Value | Error you see without it |
| --- | --- | --- |
| compileSdk | 36 or higher | `Dependency 'app.independo.inderun:inderun-kotlin:<version>' requires libraries and applications that depend on it to compile against version 36 or later of the Android APIs.` |
| minSdk | 26 or higher | `Manifest merger failed : uses-sdk:minSdkVersion 24 cannot be smaller than version 26 declared in library [app.independo.inderun:inderun-kotlin:<version>]` |
| Android Gradle plugin | 8.13.0 or higher; IndeRun adds no floor of its own (older versions are not tested) | — |
| Gradle | Whatever the app's AGP requires: 8.14.3 runs AGP 8.13.0, AGP 9.1.0 needs 9.3.1 | `Minimum supported Gradle version is 9.3.1. Current version is 8.14.3.` (AGP 9.1.0's check) |
| Kotlin Gradle plugin | 2.3.0 or higher, on the **app's** buildscript classpath | `e: Incompatible classes were found in dependencies. Remove them from the classpath or use '-Xskip-metadata-version-check' to suppress errors`, then per artifact: `Module was compiled with an incompatible version of Kotlin. The binary version of its metadata is 2.4.0, expected version is 2.2.0.` |
| JDK | 17 or higher to run the build (AGP's own requirement); the published bytecode targets Java 17 | — |

The Kotlin requirement is the one a consumer cannot guess. The `inderun-*` artifacts, and ML Kit's
`genai-common` that `inderun-kotlin` brings in, carry Kotlin 2.4 metadata, and a Kotlin compiler reads metadata at
most one version newer than itself. AGP 9.1.0's built-in Kotlin compiles with 2.2, and so does KGP 2.2.x applied
through `kotlin-android` on AGP 8. This repository builds with Kotlin 2.4, but that does not reach a consuming
app, which resolves KGP from its own buildscript classpath. Put it there, in the app's top-level build file:

```groovy
buildscript {
    dependencies {
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.3.0")
    }
}
```

The same lines work in a Groovy `build.gradle` (Capacitor) and a `build.gradle.kts`. On AGP 8 it is the version
of the `kotlin-android` plugin the app applies; on AGP 9 it raises the version that AGP's built-in Kotlin uses, with
no further plugin to apply.

The published modules build with compileSdk 36 so that this floor stays 36: AGP writes a library's compileSdk into
its AAR metadata, and a dependency whose own AAR demands a newer compileSdk fails their build.

Releases 0.2.2 to 0.4.0 and the 0.5.0 release candidates rc.1 to rc.17 also required compileSdk 37 and AGP 9.1.0 or
higher. Their AARs declare `minCompileSdk=37`, and their `inderun-core` depends on `androidx.core:core-ktx` 1.19.x,
whose `androidx.core:core` AAR declares `minCompileSdk=37` and `minAndroidGradlePluginVersion=9.1.0`
([#214](https://github.com/independo-gmbh/inderun/issues/214)).

## Streaming

`IndeRun.stream(request)` returns the run handle, its canonical `StreamEvent` flow, and a
`cancel(reason)` hook:

```kotlin
val run = indeRun.stream(request)
run.events.collect { event ->
    when (event.type) {
        "content_delta" -> print(event.payload?.text)
        "terminal" -> println(event.payload?.outcome)
    }
}
```

`events` is cold — the run starts on first collection — and single-use: collecting it twice throws
rather than re-running the provider.

The HTTP-transport providers need a host that can deliver a response body incrementally.
`HostServicesFactory.create(context)` provides one; a host without a `streamingHttpClient` still
runs Mode 1, and a stream request that can only be served over HTTP is refused at routing time
with a `streaming_unavailable` reason. The ML Kit provider does not go through that path — it
streams from Gemini Nano with no host HTTP capability involved.
`HostServicesFactory.create(context)` also provides an `AudioTrack` `audioOutput` for providers that synthesize PCM
themselves; it requests no audio focus.

The OpenAI adapter speaks the OpenAI **Responses** API, not chat completions: a custom endpoint
must accept `"stream": true` and emit `text/event-stream` with the Responses event types. Keep
credentials behind `authContextRef`, and never ship a developer-owned API key in a distributed
app — point `endpointUrl` at a trusted backend proxy that holds the key and relays the stream.

Event types, ordering, the terminal guarantees, cancellation, and fallback are identical on every
SDK and documented once, in [Streaming (Mode 2)](../docs/streaming.md). Note in particular that
`content_snapshot` must be handled even though both Android providers emit `content_delta`: ML Kit
uses an empty snapshot to retract a response Gemini Nano rejected on a policy check.

## Neural speech

`inderun-neural-speech` holds the provider; `inderun-onnx-providers` holds the runtime that makes it
speak: `OnnxNeuralSpeechRuntime(context)` is the `NeuralSpeechRuntime` an app passes to
`NeuralSpeechProvider`. It runs the Articulino graphs through ONNX Runtime on the CPU execution
provider (intra-op threads `min(4, cores)`), and checks the package's declared checksums at `prepare`.

```kotlin
val provider = NeuralSpeechProvider(NeuralSpeechProviderOptions(modelPackage, OnnxNeuralSpeechRuntime(context)))
```

The package is a directory in the layout `tools/neural-speech/README.md` describes
(`model-package.json`, `config.json`, `text.onnx`, `dit_step.onnx`, `decoder.onnx`,
`voices/<id>.safetensors`), referenced by the `ModelPackage`'s `source`: `filesystem` (`ref` is the
directory), `bundled` (`ref` is an asset directory, extracted once into app-private storage) or
`app_managed` (`ref` is relative to `Context.filesDir`). Other source types are reported as
unavailable. No normalizer runs yet: write numbers as words until the German frontend lands.

## Route planner

Provider selection is decided by the shared Rust route core (`rust/inderun-route-core`), not by
Kotlin. There is no fallback planner: if the core cannot be loaded or cannot produce a plan, the
request fails with an `Internal` error naming the reason (`library_unavailable`, `plan_failed`,
`invalid_plan_shape`) rather than routing by a second set of rules.

The Gradle build produces the library itself, so it is a build dependency of this workspace:

- `./gradlew test` builds one library for the machine running the tests and puts it on
  `java.library.path`. Needs Node and `rustup`.
- Anything that assembles an AAR (`build`, `assembleRelease`, `publishToMavenLocal`)
  cross-compiles the four Android ABIs into `jniLibs`. Additionally needs the Android NDK.

`scripts/build-route-core-android.mjs` prints the exact install commands when a toolchain is
missing. The same script with `--speech-text` builds a second library, `libinderun_speech_text`
(the German speech text normalizer), which `:inderun-neural-speech` packages and loads; it is kept out
of `libinderun_route_core` so apps that do not use neural speech do not carry it (about 1.6 MB per
ABI). The unit tests of `:inderun-neural-speech` and `:inderun-onnx-providers` put its host build on
`java.library.path`. The compiled libraries are not committed — CI builds the AAR that goes to Maven
Central. See [docs/ci.md](../docs/ci.md).

## Commands

```sh
cd android && ./gradlew build
cd android && ./gradlew test
# Real TextToSpeech over the shared speech corpus; needs a running emulator or device and the NDK.
cd android && ./gradlew :inderun-kotlin:connectedAndroidTest
```
