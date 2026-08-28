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

## Commands

```sh
cd android && ./gradlew build
cd android && ./gradlew test
```
