# IndeRun Android

Android workspace for the IndeRun SDK, host services, provider adapters, and demo app.

## Modules

- `inderun-kotlin` - public Android SDK entrypoint
- `inderun-core` - platform host services
- `inderun-contracts` - generated Kotlin contract models
- `inderun-mlkit-providers` - on-device ML Kit GenAI provider
- `inderun-openai-providers` - OpenAI-compatible cloud provider
- `inderun-onnx-providers` - ONNX Runtime provider for developer-supplied local models
  (`local.onnx.genai.android`)
- `inderun-demo-app` - demo app for reviewing the Mode 1 flow

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

`events` is cold — the run starts on first collection — and single-use: collecting it twice
throws rather than re-running the provider. Order by `event.sequence`, not by arrival: it is the
ordering authority for a run. Treat an unrecognized `event.type` as ignore-or-pass-through, since
the set is open and additive. Exactly one terminal event is produced per run, and `cancel` is
idempotent.

Streaming needs a host that can deliver a response body incrementally.
`HostServicesFactory.create(context)` provides one; a host without a `streamingHttpClient` still
runs Mode 1, and a stream request is refused at routing time with a `streaming_unavailable`
reason.

The OpenAI adapter speaks the OpenAI **Responses** API, not chat completions: a custom endpoint
must accept `"stream": true` and emit `text/event-stream` with the Responses event types. Keep
credentials behind `authContextRef`, and never ship a developer-owned API key in a distributed
app — point `endpointUrl` at a trusted backend proxy that holds the key and relays the stream.

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
missing. The compiled libraries are not committed — CI builds the AAR that goes to Maven
Central. See [docs/ci.md](../docs/ci.md).

## Commands

```sh
cd android && ./gradlew build
cd android && ./gradlew test
```
