# IndeRun Web Demo

Reference demo for `@independo/inderun-web`, built around one accessibility feature: **rewriting dense
text in plain language**. It shows how an app uses the primary text API, runs on the device when it
can, uses the cloud only when the user allows it, and tells the user where each result came from.

It is for developers reading the code, not a product: the UI is vanilla TypeScript and the whole
feature is a handful of lines in [`src/simplify.ts`](src/simplify.ts) and [`src/app.ts`](src/app.ts).

## The Simplify Flow

The top of the page is the feature itself.

1. **Text to simplify** — starts with a dense administrative paragraph.
2. **Where may this text be processed?** — maps to `execution.privacy`:

   | Choice              | `execution.privacy` | What it means                                                      |
   | ------------------- | ------------------- | ------------------------------------------------------------------ |
   | On this device only | `local_required`    | The text never leaves the device; fails if no on-device model runs |
   | Prefer this device  | `local_preferred`   | On-device first, **but the cloud may be used** if none can run it  |
   | Cloud allowed       | `cloud_allowed`     | Any target in the profile, the cloud included                      |

3. **How should the result arrive?**
   - **Whole result** (default) calls `generateText()`. Every target can serve it, on-device ones
     included. It cannot be stopped once started (Mode 1 has no cancellation channel).
   - **Stream** calls `streamText()` and renders `textStream` as it arrives; **Stop** calls
     `cancel()`. Neither on-device Web provider streams yet, so routing skips them for this call and
     only the cloud target can run it. The demo says so when it happens rather than hiding it.

Both modes make the same call:

```ts
await generateText(inderun, {          // or streamText(...)
  model: "simplify",                   // model profile, not a vendor model id
  system: PLAIN_LANGUAGE_INSTRUCTION,
  prompt: text,
  execution: { privacy }
});
```

`model: "simplify"` names a model profile registered in [`src/demo-client.ts`](src/demo-client.ts).
It lists the demo's three targets in preference order:

1. `local.system-model.web` — the browser's built-in model (Chrome Prompt API)
2. `local.onnx.genai.web` — an ONNX model run in the browser
3. `openai:<VITE_INDERUN_OPENAI_MODEL>` — the cloud model behind the demo proxy

The privacy choice still decides which of them a request may use.

### Where It Ran

The **Where it ran** panel reads `result.provenance` (or the thrown `IndeRunException`'s
`.provenance`), never telemetry or `providerUsed`:

- where it ran — the attributed target's declared locality (`On this device`, `Cloud`, `Unknown`)
- which target, as a readable label plus its id
- the configured model and the model the provider reported; either shows as *not declared* /
  *not reported* when absent, and is never guessed. With the demo proxy the two can differ: the
  proxy sends its own `INDERUN_OPENAI_MODEL` upstream whatever the browser asked for.
- whether IndeRun fell back, every attempt in order with its outcome, and the targets routing
  skipped with their normalized reason codes

### Honest States

Each outcome lists the notices that apply to it, derived from the provenance, the error class, and
`navigator.onLine`:

- **Offline** — the cloud target cannot run; only an on-device target can.
- **No on-device model could run this** — with *On this device only*, nothing on the device was
  usable; the notice suggests allowing the cloud.
- **Cloud not permitted** — the cloud target was skipped because of the privacy choice.
- **On-device targets cannot stream yet** — *Stream* skipped them.
- **Browser built-in model not available** — the Prompt API is missing (it needs desktop Chrome
  138+); other browsers fall through to the next target.
- **Fixture output, not a real model** — the ONNX target ran the deterministic fixture runtime (see
  below), which echoes its input.
- **Stopped** — a cancelled stream keeps and shows the text delivered before the stop.

Above the output, **What can run here now** shows the profile's targets as `checkCapabilities()`
reports them, plus the network state. Availability can change before a run; the provenance is the
record of what actually happened. The demo makes no claim that on-device execution is available in
general, and simplified text is machine-generated, not a certified plain-language translation.

## Advanced: Task API

The collapsed **Advanced: task API** section keeps the raw panels: Mode 1 `run()`, Mode 2 `stream()`
with an ordered event log and Cancel, provider availability badges from `checkCapabilities()`, and
the routing decision read from `route_decided` telemetry. These panels build a `TaskRequest` by hand
and send it without a model profile, so they route across every registered target, and they offer
`Cloud Only` (`cloud_required`) as well.

## Configuration

| Env var                              | Effect                                                                        |
| ------------------------------------ | ----------------------------------------------------------------------------- |
| `VITE_INDERUN_ONNX_MODEL_ID`         | Hub model ref; switches the ONNX target from the fixture to real weights      |
| `VITE_INDERUN_ONNX_MODEL_PACKAGE_ID` | Model package id the ONNX target declares (default `inderun-demo-fixture`)    |
| `VITE_INDERUN_OPENAI_MODEL`          | Cloud model the browser registers as `openai:<model>` (default `gpt-5.2`)     |
| `VITE_INDERUN_DEMO_PROXY_URL`        | Proxy endpoint for the cloud target (default `/api/inderun/openai-responses`) |

The Vite dev server forwards `/api/inderun` to the demo proxy on `127.0.0.1:8787`. The proxy owns
the upstream endpoint, model and key (`OPENAI_API_KEY`, `INDERUN_OPENAI_ENDPOINT_URL`,
`INDERUN_OPENAI_MODEL`; see [`@independo/inderun-demo-proxy`](../inderun-demo-proxy/README.md)).
Keep `VITE_INDERUN_OPENAI_MODEL` and `INDERUN_OPENAI_MODEL` aligned so the target's configured model
matches what actually runs; the provenance panel shows both when they differ.

**OpenRouter** works through the same proxy: set `INDERUN_OPENAI_ENDPOINT_URL` to OpenRouter's
Responses endpoint, `OPENAI_API_KEY` to the OpenRouter key and `INDERUN_OPENAI_MODEL` to a
`vendor/model` id. See [OpenRouter](../../docs/openrouter.md).

### On-device targets

**Browser built-in model.** Registered with `systemModel: {}`. It needs no configured model: the
browser owns availability and download. It is only usable where Chrome's Prompt API is (desktop
Chrome 138+); everywhere else it reports unavailable, which is expected.

**ONNX in the browser.** Without `VITE_INDERUN_ONNX_MODEL_ID` it runs the deterministic fixture
runtime, so the on-device route works offline and in CI without downloading weights — and the UI
labels every such output as a fixture. Set the variable to run real weights through Transformers.js
(`@huggingface/transformers`, already a dependency of this demo).

Suggested model: `onnx-community/gemma-3-1b-it-ONNX` — text-only, single-graph, and loadable through
the `text-generation` pipeline the default runtime uses. At the default `q4f16` it downloads roughly
700 MB on first run and is cached afterwards. `onnx-community/LFM2.5-350M-ONNX` is a lighter
alternative.

Multimodal exports (Gemma 4's `any-to-any` E2B/E4B, for example) are split across separate
vision/audio/decoder graphs and do **not** load through that pipeline; they would need a custom
`OnnxTextGenerationRuntime`.

## Manual Test Checklist

The Vitest suite drives the UI against a fake `IndeRunApi` in happy-dom. It does not prove real
browser behavior — the Prompt API, ONNX Runtime Web, or `fetch` delivering `text/event-stream`
incrementally — so check these by hand:

- **On-device, whole result**: *Prefer this device* + *Whole result*. In desktop Chrome 138+ with
  the Prompt API ready, the run should land on the browser built-in model; elsewhere on the ONNX
  target (flagged as a fixture unless `VITE_INDERUN_ONNX_MODEL_ID` is set).
- **Fallback**: make the on-device run fail (e.g. a model ref that cannot load) with *Prefer this
  device*; the panel shows the failed attempt followed by the cloud attempt.
- **No local model**: in a non-Chrome browser with *On this device only* and the ONNX target failing,
  the run fails with its rejections and the "allow the cloud" notice.
- **Streaming and Stop**: *Cloud allowed* + *Stream* against a running proxy; text grows as chunks
  land. **Stop** mid-generation ends the run as *Stopped* with the partial text.
- **Offline**: switch the browser offline; the status shows the network as offline and cloud runs
  report it.
- **Advanced stream**: in the advanced section, *Local Only* + **Stream** is refused at routing (no
  run handle, no events); an unreachable `VITE_INDERUN_DEMO_PROXY_URL` ends a stream with a terminal
  `error` outcome, which is an event, not a rejection.

## Security Model

The browser app uses the proxy-first configuration from `@independo/inderun-web`. The browser never
carries raw provider secrets; the demo proxy resolves the upstream endpoint and bearer token
server-side.

## Commands

```sh
pnpm --filter @independo/inderun-web-demo dev
pnpm --filter @independo/inderun-web-demo build
pnpm --filter @independo/inderun-web-demo preview
pnpm --filter @independo/inderun-web-demo test
```

## Review Flow

1. Start `@independo/inderun-demo-proxy` (needed only for the cloud target).
2. Start this demo.
3. Open the local Vite URL and simplify the sample text under each privacy choice and delivery mode.
