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
- `inderun-demo-app` - demo app for reviewing the Mode 1 and Mode 2 flows
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

Two providers stream on Android: `AndroidMlKitGenAiProvider` on-device and the OpenAI-compatible
cloud adapter. Both emit incremental text, so their content events are normally `content_delta` and
each payload appends to what came before.

Handle `content_snapshot` anyway — a snapshot payload *replaces* the text so far rather than
appending to it. Two reasons it can arrive: the Apple provider emits nothing else on iOS/macOS, and
a provider of any style may emit an empty snapshot to **retract** content it already delivered. ML
Kit does exactly that when Gemini Nano rejects a half-generated response on a policy check, so a
consumer that only implements the delta branch would keep rejected text on screen.

The HTTP-transport providers need a host that can deliver a response body incrementally.
`HostServicesFactory.create(context)` provides one; a host without a `streamingHttpClient` still
runs Mode 1, and a stream request that can only be served over HTTP is refused at routing time
with a `streaming_unavailable` reason. The ML Kit provider does not go through that path — it
streams from Gemini Nano with no host HTTP capability involved.

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
