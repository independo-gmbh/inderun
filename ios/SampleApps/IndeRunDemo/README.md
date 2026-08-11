# IndeRun Demo

This sample app is a broader iOS SwiftUI demo for the full IndeRun iOS SDK. It runs the same
text-to-text request through IndeRun's capability-based provider routing across three
registered providers:

- Apple Foundation Models on-device
- an ONNX Runtime local provider (`IndeRunOnnxProviders`). By default it auto-downloads a small
  real model (DistilGPT-2, quantized, ~84 MB) from Hugging Face on first launch and runs actual
  on-device generation — the same "just try it out" experience as the web demo's automatic
  model download, no manual setup required. A no-download fixture runtime (echoes the prompt
  instead of generating text) is available as an alternate selection.
- an OpenAI-compatible cloud endpoint configured in the app, typically via `@independo/inderun-demo-proxy`

## Requirements

- Xcode 26.0 or newer with the iOS 26.0 SDK installed
- For on-device Apple mode:
  - a physical iPhone or iPad that supports Apple Intelligence and Apple Foundation Models
  - Apple Intelligence enabled on the device
  - an OS/device/locale state where the system model is eligible and ready
- For the ONNX local provider:
  - no setup needed — DistilGPT-2 (quantized, ~84 MB) downloads automatically from Hugging
    Face on first launch (Wi-Fi recommended) into the app's Application Support directory,
    and is cached there afterward. Progress shows under **ONNX Local Settings**.
  - the catalog (`DemoOnnxModelOption.catalog` in `DemoOnnxModel.swift`) is limited to plain
    decoder-only ONNX exports (`input_ids`/`attention_mask` in, `logits` out, no
    `past_key_values`) because that's what the SDK's default `SystemOnnxGenAiRuntime`
    supports; more capable instruction-tuned models can be added once
    [#126](https://github.com/independo-gmbh/inderun/issues/126) adds KV-cache support
  - select **Fixture (no download)** from the ONNX Model picker to fall back to a
    deterministic runtime that echoes the prompt instead of generating text
- For cloud mode:
  - the iOS Simulator or a physical device
  - a reachable OpenAI-compatible endpoint
  - if you use the local demo proxy, start `pnpm --filter @independo/inderun-demo-proxy dev` first

## Project Layout

- `IndeRunDemo.xcodeproj`: iOS app project
- `IndeRunDemo/`: SwiftUI app sources

The app depends on the local Swift package at `ios/IndeRun` and imports:

- `IndeRunSwift`
- `IndeRunCore`
- `IndeRunContracts`
- `IndeRunAppleProviders`
- `IndeRunOnnxProviders`
- `IndeRunOpenAIProviders`

## Manual Demo Test

1. Open `IndeRunDemo.xcodeproj` in Xcode.
2. Configure a signing team for the app target if Xcode requests one.
3. Build and run the app; for full Apple Foundation Models coverage, run on a real supported
   iOS 26.0+ device.
4. Choose a Privacy Preference: `Local Only`, `Prefer Local`, `Cloud Allowed`, or `Cloud Only`.
   IndeRun selects the provider automatically based on this preference and each provider's
   reported capabilities — there is no manual per-provider toggle.
5. If you plan to exercise the cloud route, confirm the endpoint and model settings:
   - simulator local proxy default: `http://127.0.0.1:8787/api/inderun/openai-responses`
   - physical device local proxy: replace `127.0.0.1` with your Mac's LAN IP
   - remote proxy or remote OpenAI-compatible server: enter its full URL
6. Keep or edit the prompt, then tap **Run**.
7. Review the **Provider Availability** panel — one badge per registered provider, driven by
   `IndeRun.checkCapabilities()`, refreshed automatically after every run.
8. Review the **Result** panel for generated text or a normalized `IndeRunException`, and the
   **Routing Decision** panel for which provider was selected, why, and which providers (if
   any) were rejected.

## Demo Proxy Setup

The sample app never embeds OpenAI credentials in `TaskRequest`. For cloud testing, the intended path is:

1. start `@independo/inderun-demo-proxy`
2. point the app's endpoint setting at that proxy
3. let the proxy handle upstream auth and any server-side model override

Example with local Ollama:

```sh
export INDERUN_OPENAI_ENDPOINT_URL=http://localhost:11434/v1/responses
export INDERUN_OPENAI_MODEL=gemma4:latest
pnpm --filter @independo/inderun-demo-proxy dev
```

Example with OpenAI:

```sh
export OPENAI_API_KEY=...
pnpm --filter @independo/inderun-demo-proxy dev
```

## Expected Failure Modes

- `CapabilityMismatch`: no registered provider satisfies the current privacy preference and
  system state (e.g. `Local Only` selected but Apple Foundation Models are unavailable and the
  ONNX model hasn't finished downloading)
- `Offline`: cloud execution was required but the device has no network connection
- `Unavailable`: the configured cloud endpoint could not be reached or failed before returning a response
- `AuthError`: the configured upstream rejected authentication
- `Internal`: an unexpected runtime or payload-mapping failure occurred

## Notes

- Routing is automatic and capability-based: IndeRun picks among the three registered
  providers per the selected Privacy Preference, not a manual on-device/cloud toggle.
- The default cloud endpoint only works from the simulator against a proxy running on the same machine.
- Apple availability depends on device class, OS version, locale, Apple Intelligence state, and model readiness.
- The ONNX Local provider downloads and caches a small real model automatically; until that
  download finishes (or if you explicitly pick the fixture option), it runs against a
  deterministic fixture runtime instead, so the demo still works offline.
- DistilGPT-2 is a small base language model, not instruction-tuned, so expect rambly
  continuations rather than direct answers — it's there to prove real on-device ONNX inference
  end-to-end, not to demonstrate output quality. It also has no chat template, so the SDK
  formats the prompt as a plain `"user: <prompt>"` line rather than a real chat turn; an
  instruction phrased as a task (e.g. "Summarize X") often makes it immediately predict the
  end-of-text token, producing empty output. The default prompt is a declarative sentence
  fragment for the model to continue, which it follows far more reliably — edit-in the same
  style if you change it. Every small instruction-tuned model checked (Qwen2.5-0.5B-Instruct,
  Qwen1.5-0.5B-Chat, TinyLlama-1.1B-Chat) only ships a KV-cache export, which the SDK's default
  runtime doesn't support (see #126), so a base model is the only fit today.
- Cloud settings are persisted locally with `UserDefaults` so repeated manual testing is faster.
- The UI calls IndeRun's public Swift APIs only. It does not talk directly to Apple Foundation Models, ONNX Runtime, or a cloud API.
