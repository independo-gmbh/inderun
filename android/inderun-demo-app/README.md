# IndeRun Android Demo

This sample app is a broader Android Compose demo for the full IndeRun Kotlin SDK. It runs the
same text-to-text request through IndeRun's capability-based provider routing across three
registered providers:

- Android ML Kit GenAI on-device
- an ONNX Runtime local provider (`inderun-onnx-providers`). By default it auto-downloads a small
  real model (DistilGPT-2, quantized, ~84 MB) from Hugging Face on first launch and runs actual
  on-device generation — the same "just try it out" experience as the web and iOS demos' automatic
  model download, no manual setup required. A no-download fixture runtime (echoes the prompt
  instead of generating text) is available as an alternate selection.
- an OpenAI-compatible cloud endpoint configured in the app, typically via
  `@independo/inderun-demo-proxy`

## Requirements

- Android Studio with the Android 34 SDK platform installed
- For on-device ML Kit mode:
  - a device or emulator with Gemini Nano/AICore support (most emulator images do not have this;
    expect `Unavailable` there — this is expected, not a bug)
- For the ONNX local provider:
  - no setup needed — DistilGPT-2 (quantized, ~84 MB) downloads automatically from Hugging Face on
    first launch (Wi-Fi recommended) into the app's private storage (`context.filesDir`), and is
    cached there afterward. Progress shows under **ONNX Local Settings**.
  - the catalog (`DemoOnnxModelOption.catalog` in `DemoOnnxModel.kt`) is limited to plain
    decoder-only ONNX exports (`input_ids`/`attention_mask` in, `logits` out, no
    `past_key_values`) because that's what the SDK's default `SystemAndroidOnnxGenAiRuntime`
    supports; more capable instruction-tuned models can be added once
    [#126](https://github.com/independo-gmbh/inderun/issues/126) adds KV-cache support
  - select **Fixture (no download)** from the ONNX Model picker to fall back to a deterministic
    runtime that echoes the prompt instead of generating text
- For cloud mode:
  - an emulator or a physical device
  - a reachable OpenAI-compatible endpoint
  - if you use the local demo proxy, start `pnpm --filter @independo/inderun-demo-proxy dev` first

## Project Layout

- `android/inderun-demo-app`: this Gradle application module (Jetpack Compose)
- `MainActivity.kt`, `DemoViewModel.kt`, `DemoScreen.kt`: app entry point, state, and UI
- `AndroidDemoRuntime.kt`: builds the `ProviderRegistry` (ML Kit + ONNX + cloud) and drives
  `IndeRun.run()`/`checkCapabilities()`
- `DemoOnnxModel.kt`: ONNX model catalog and Hugging Face downloader

The module depends on:

- `inderun-kotlin` (the `IndeRun` SDK entry point)
- `inderun-core`, `inderun-contracts`
- `inderun-mlkit-providers`
- `inderun-onnx-providers`
- `inderun-openai-providers`

## Manual Demo Test

1. Open the `android/` workspace in Android Studio, or run
   `./gradlew :inderun-demo-app:installDebug` from `android/`.
2. Launch the app on an emulator or supported physical device.
3. Choose a Privacy Preference: `Local Only`, `Prefer Local`, `Cloud Allowed`, or `Cloud Only`.
   IndeRun selects the provider automatically based on this preference and each provider's
   reported capabilities — there is no manual per-provider toggle.
4. If you plan to exercise the cloud route, confirm the endpoint and model settings:
   - emulator local proxy default: `http://10.0.2.2:8787/api/inderun/openai-responses`
   - physical device local proxy: replace `10.0.2.2` with your machine's LAN IP
   - remote proxy or remote OpenAI-compatible server: enter its full URL
5. Keep or edit the prompt, then tap **Run**.
6. Review the **Provider Availability** panel — one badge per registered provider, driven by
   `IndeRun.checkCapabilities()`, refreshed automatically after every run.
7. Review the **Result** panel for generated text or a normalized `IndeRunException`, and the
   **Routing Decision** panel for which provider was selected, why, and which providers (if any)
   were rejected.

## Demo Proxy Setup

The sample app never embeds OpenAI credentials in `TaskRequest`. For cloud testing, the intended
path is:

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

- `CapabilityMismatch`: no registered provider satisfies the current privacy preference and system
  state (e.g. `Local Only` selected but ML Kit GenAI is unavailable and the ONNX model hasn't
  finished downloading)
- `Offline`: cloud execution was required but the device has no network connection
- `Unavailable`: the configured cloud endpoint could not be reached or failed before returning a
  response
- `AuthError`: the configured upstream rejected authentication
- `Internal`: an unexpected runtime or payload-mapping failure occurred

## Notes

- Routing is automatic and capability-based: IndeRun picks among the three registered providers
  per the selected Privacy Preference, not a manual on-device/cloud toggle.
- The default cloud endpoint only works from the emulator against a proxy running on the host
  machine (`10.0.2.2` is the emulator's alias for the host loopback interface).
- ML Kit GenAI availability depends on device class, OS version, and Gemini Nano/AICore
  readiness — most emulator images report `Unavailable`, which is expected.
- The ONNX Local provider downloads and caches a small real model automatically; until that
  download finishes (or if you explicitly pick the fixture option), it runs against a
  deterministic fixture runtime instead, so the demo still works offline.
- DistilGPT-2 is a small base language model, not instruction-tuned, so expect rambly
  continuations rather than direct answers — it's there to prove real on-device ONNX inference
  end-to-end, not to demonstrate output quality. It also has no chat template, so the SDK formats
  the prompt as a plain `"role: content"` line rather than a real chat turn; an instruction phrased
  as a task (e.g. "Summarize X") often makes it immediately predict the end-of-sequence token,
  producing empty output. The default prompt is a declarative sentence fragment for the model to
  continue, which it follows far more reliably — edit-in the same style if you change it. Every
  small instruction-tuned model checked (Qwen2.5-0.5B-Instruct, Qwen1.5-0.5B-Chat,
  TinyLlama-1.1B-Chat) only ships a KV-cache export, which the SDK's default runtime doesn't
  support (see #126), so a base model is the only fit today.
- The ONNX Local provider depends on `libc++_shared.so`, which `inderun-onnx-providers` packages
  per ABI via a no-op CMake native target (`src/main/cpp/`) — its tokenizer library needs it but
  doesn't ship it. If you see `UnsatisfiedLinkError: dlopen failed: library "libc++_shared.so" not
  found`, that native build step didn't run (requires the NDK/CMake, auto-provisioned by AGP).
- Cloud settings and the ONNX model selection are persisted locally with `SharedPreferences` so
  repeated manual testing is faster.
- The UI calls IndeRun's public Kotlin APIs only. It does not talk directly to ML Kit GenAI, ONNX
  Runtime, or a cloud API.
