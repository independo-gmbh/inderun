# IndeRun Web Demo

Minimal browser demo for the Mode 1 cloud and on-device flows.

It runs a prompt through `@independo/inderun-web`, shows either generated text or a normalized error, and surfaces the run metadata returned by the SDK.

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
