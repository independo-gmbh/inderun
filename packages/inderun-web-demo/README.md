# IndeRun Web Demo

Minimal browser demo for the Mode 1 and Mode 2 cloud and on-device flows.

It runs a prompt through `@independo/inderun-web`, shows either generated text or a normalized error, and surfaces the run metadata returned by the SDK. **Stream** sends the same prompt through `stream()` instead.

## Execution Modes

**On Device** (the default mode) routes with `privacy: "local_required"` through the Web ONNX
Runtime provider (`local.onnx.genai.web`). **Cloud** routes with `privacy: "cloud_required"` through
the demo proxy.

Without `VITE_INDERUN_ONNX_MODEL_ID` the on-device mode uses the deterministic fixture runtime, so
the local route works offline and in CI without downloading model weights. Set it to run real
weights; that also requires installing `@huggingface/transformers`.

| Env var                              | Effect                                                     |
| ------------------------------------ | ---------------------------------------------------------- |
| `VITE_INDERUN_ONNX_MODEL_ID`         | Hub model ref; switches on-device mode to a real runtime    |
| `VITE_INDERUN_ONNX_MODEL_PACKAGE_ID` | Model package id reported by the provider (cosmetic)        |
| `VITE_INDERUN_OPENAI_MODEL`          | Cloud model id                                              |
| `VITE_INDERUN_DEMO_PROXY_URL`        | Proxy endpoint for the cloud route                          |

Suggested model: `onnx-community/gemma-3-1b-it-ONNX` — text-only, single-graph, and loadable through
the `text-generation` pipeline the default runtime uses. At the default `q4f16` it downloads roughly
700 MB on first run and is cached afterwards. `onnx-community/LFM2.5-350M-ONNX` is a lighter
alternative.

Multimodal exports (Gemma 4's `any-to-any` E2B/E4B, for example) are split across separate
vision/audio/decoder graphs and do **not** load through that pipeline; they would need a custom
`OnnxTextGenerationRuntime`.

## Manual Streaming Test (Mode 2)

Pressing **Stream** instead of **Run** sends the same request through
`IndeRun.stream(request)` and renders content events in the **Streaming (Mode 2)** panel as they
arrive. **Cancel** replaces the button while a stream is in flight.

Only the OpenAI-compatible cloud provider streams here. Neither the Web ONNX Runtime provider nor
the Prompt API provider implements Mode 2, so both are rejected at routing time for every stream
request — `Local Only` therefore always refuses, which is correct rather than a bug.

This is the only place the browser's real streaming transport runs. The Vitest suites drive the
reassembly and orchestration contracts in jsdom; they do not prove that `fetch` delivers a
`text/event-stream` body incrementally in an actual browser.

- **Cloud streaming**: choose `Cloud Allowed` or `Cloud Only` and press **Stream** against a
  running demo proxy. Text arrives in incremental `content_delta` events, so the panel grows as
  chunks land, and the event log's `sequence` column increases by exactly one with no gaps.
- **Cancellation**: press **Cancel** mid-generation. The run ends with a `cancelled` outcome
  carrying whatever text had already been delivered, nothing is logged after it, and repeated
  presses are harmless.
- **Routing refusal**: choose `Local Only` and press **Stream**. The call itself rejects — no run
  handle and no events, so the panel shows a refusal rather than a terminal event.
- **Terminal error**: point `VITE_INDERUN_DEMO_PROXY_URL` at an unreachable endpoint. The run ends
  with a terminal `error` **outcome**, logged as an event. It is not a rejection, and the
  distinction is the easiest one to conflate.

## Expected Failure Modes

- `CapabilityMismatch`: **On Device** selected but the ONNX Web provider isn't usable in this
  browser (e.g. no WebGPU/WASM support for the runtime)
- `Offline`: **Cloud** selected but the browser has no network connection
- `Unavailable`: the demo proxy or configured cloud endpoint could not be reached, or failed
  before returning a response
- `AuthError`: the configured upstream rejected authentication
- `Internal`: an unexpected runtime or payload-mapping failure occurred

On **Stream** specifically:

- `CapabilityMismatch` on the `stream()` call: no registered provider can stream under the current
  preference. This is a routing refusal, so it rejects the call — no run handle and no events.
- A `cancelled` terminal outcome is not an error. It is the normal result of pressing **Cancel**,
  and it carries the partial text delivered before the cancel landed.
- A terminal `error` outcome is an event on a run that started, unlike the rejection above.

The demo surfaces these as the normalized error shown in place of generated text — see
[Error Model](../../docs/architecture/providers.md#error-model). Note this demo does not yet
exercise the Web system-model provider (Chrome Prompt API); see the
[Provider Matrix](../../docs/architecture/providers.md#provider-matrix) for its dedicated test
coverage.

## Security Model

The browser app uses the proxy-first configuration from `@independo/inderun-web`. The browser does not carry raw provider secrets.

## Commands

```sh
pnpm --filter @independo/inderun-web-demo dev
pnpm --filter @independo/inderun-web-demo build
pnpm --filter @independo/inderun-web-demo preview
pnpm --filter @independo/inderun-web-demo test
```

## Review Flow

1. Start `@independo/inderun-demo-proxy`.
2. Start this demo.
3. Open the local Vite URL and run a prompt in both **Cloud** and **On Device** mode.
