# IndeRun Demo

This sample app is a broader iOS SwiftUI demo for the full IndeRun iOS SDK. It runs the same
text-to-text request through IndeRun's capability-based provider routing across three
registered providers:

- Apple Foundation Models on-device
- an ONNX Runtime local provider (`IndeRunOnnxProviders`). By default it auto-downloads a small
  real model (DistilGPT-2, quantized, ~84 MB) from Hugging Face on first launch and runs actual
  on-device generation — the same "just try it out" experience as the web demo's automatic
  model download, no manual setup required. A second, more capable instruction-tuned model
  (LaMini-GPT-124M, quantized, ~130 MB) is available from the same picker and exercises the
  SDK's KV-cache decode path (see [#126](https://github.com/independo-gmbh/inderun/issues/126)).
  A no-download fixture runtime (echoes the prompt instead of generating text) is available as
  an alternate selection.
- an OpenAI-compatible cloud endpoint configured in the app, typically via `@independo/inderun-demo-proxy`

The app has two tabs, and an optional third. **Text** holds everything above: the privacy preference, the prompt, run,
stream and cancel, the result and routing panels, provider availability, and the cloud and ONNX
settings. **Speech** speaks text through the device's system voices. **Voices lab** is opt-in (below).

## Voices lab (opt-in)

Switch on **Voices lab** at the bottom of the Speech tab (persisted in `UserDefaults`, off by default) and a third tab
appears. While the switch is off the tab is hidden and nothing is read, registered, downloaded or created on disk.

- It downloads the Articulino neural speech model and seven demo voices (about 113 MB) only after a consent sheet that
  shows the real total size, the model licence and attribution, and each distinct voice licence. Declining makes no
  request. Files stream to `<name>.part` with an incremental SHA-256 and a byte check (a slow disk suspends the request
  once a few MB wait unwritten, so a file is never held in memory whole), then move into
  `Application Support/voices-lab/<entry id>/<version>/`, which is where the SDK resolves the `app_managed` package
  `ref`. A mismatch deletes the file (`checksum mismatch: <path>`); a retry resumes by skipping verified files.
  **Cancel** stops a download; verified files are kept.
- The tab speaks the same text through the neural voice and the OS voice (**Speak**, **Repeat**, **A/B** = neural then
  OS control). The status card names the provider that actually spoke; a neural request answered by the OS voice reads
  "fell back to OS voice", and an A/B run whose neural leg fell back stops there with "comparison invalid: neural fell
  back to <provider>" instead of playing the OS voice twice. The Core AI entry is listed as unavailable with the catalog's reason (this app does not link
  `IndeRunCoreAIProviders`).
- The catalog (`contracts/fixtures/speech/neural-model-catalog.json`) and the utterance corpus used for presets are
  referenced from the repository by relative path and bundled as resources, so there is one copy.
- The model files come from Hugging Face; the voices and the rewritten `text.onnx` come from the GitHub release
  `neural-speech-assets-1`. **Until that release is published those downloads fail with "asset not published yet
  (HTTP 404)".** The voices are demo assets (`review.status: benchmark_only`, legal sign-off pending, #260).
- Switching the lab off (not leaving the tab) stops a running download or playback.

## Tests

`IndeRunDemoTests` is a unit-test bundle hosted by the app. It runs the shared catalog-to-package fixture, the
consent downloader against a fake transport and a temporary directory, and the Voices lab view model:

```bash
xcodebuild test -project ios/SampleApps/IndeRunDemo/IndeRunDemo.xcodeproj -scheme IndeRunDemo \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro"
```

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
  - the catalog (`DemoOnnxModelOption.catalog` in `DemoOnnxModel.swift`) is limited to exports
    `SystemOnnxGenAiRuntime` auto-detects: plain decoder-only graphs
    (`input_ids`/`attention_mask` in, `logits` out, no `past_key_values`) or Hugging Face
    Optimum's non-merged `decoder_with_past_model` KV-cache export — not the `_merged` variant,
    which needs a `use_cache_branch` boolean input this runtime's ORT bindings can't feed
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
4. On the **Text** tab, choose a Privacy Preference: `Local Only`, `Prefer Local`, `Cloud Allowed`, or `Cloud Only`.
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

## Manual Streaming Test (Mode 2)

Tapping **Stream** instead of **Run** sends the same request through `IndeRun.stream(request:)`
and renders content events in the **Streaming (Mode 2)** panel as they arrive. **Cancel**
replaces the button while a stream is in flight.

Only two of the three registered providers stream: Apple Foundation Models (on-device) and the
OpenAI-compatible cloud provider. The ONNX Local provider does not, so it is rejected at routing
time for every stream request. When routing still finds a streaming provider, ONNX shows up under
**Rejected** in the **Routing Decision** panel (which lists provider ids, not reason codes; the
underlying code here is `streaming_not_supported`). When routing finds none, it refuses the call
outright — the panel is not updated at all, because no route was decided.

- **On-device streaming** requires a real Apple-Intelligence-capable device on iOS 26.0+ with the
  system model ready. Choose `Local Only` and tap **Stream**: text arrives in cumulative
  `content_snapshot` events, so the panel replaces its contents on each event rather than
  appending. This path cannot be exercised in the Simulator or in CI — the system model is
  unavailable there, and routing correctly refuses the request.
- **Cloud streaming** works in the Simulator against the demo proxy. Choose `Cloud Only` and tap
  **Stream**: the OpenAI adapter emits incremental `content_delta` events, so the text grows.
- **Cancellation**: tap **Cancel** mid-generation. The run ends with a `cancelled` outcome —
  shown on the panel's **Outcome** row — carrying whatever text had already been delivered. No
  event arrives after it, and repeated taps are harmless.

## Manual Speech Test

1. On the **Speech** tab, open the **Language** picker. It lists one entry per locale that
   `listVoices()` reports for this device, sorted by name, and starts on the device's own locale,
   then on one with the same language, then on the first entry. Edit the text to suit the language:
   the sample sentence is German, and a voice for another language reads it as best it can.
   The **Voice** picker lists every voice of that locale, and **Automatic** leaves the choice to
   routing. A repeated name gets a number.
2. Tap **Speak**. Local system speech plays under `local_required`, and the outcome line shows the
   finish reason, locale, voice, provider, and locality.
3. Tap **Stop** while it plays. The audio stops at once and the outcome reads `cancelled`. **Stop**
   stays disabled until routing has produced a playback handle.
   With a finished utterance the line also shows the time to the first word; after **Stop** it
   shows how long stopping took.
4. Tap **Synthesize**. The app renders the text silently through `generateSpeech()`, reads the
   WAV header back and releases the artifact; the line shows the media type, header, byte count,
   audio duration, render time, and locality.
5. Install or remove a voice in Settings under Accessibility, then come back. The list reloads each
   time the tab appears or the app returns to the foreground, and the selection moves only if its
   locale is gone.

The picker offers only locales that have a voice, so a language with no installed voice cannot be
chosen and that routing refusal cannot be reached from this screen. A device with no voices shows
a message in place of the picker and disables **Speak**.

The app calls `speak()`, `generateSpeech()`, `listVoices()` and `prepare()` only; it never touches
`AVSpeechSynthesizer`. Record device results in
[docs/verification/system-speech.md](../../../docs/verification/system-speech.md).

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
- `CapabilityMismatch` on **Stream** specifically: no registered provider can stream under the
  current preference. `Local Only` on the Simulator or on a device without Apple Intelligence
  always lands here, because the ONNX Local provider does not implement Mode 2. This is a
  routing refusal, so it rejects the `stream()` call itself — no run handle and no events.
- `cancelled` terminal outcome: not an error. It is the normal result of tapping **Cancel**, and
  carries the partial text delivered before the cancel landed.
- `Offline`: cloud execution was required but the device has no network connection
- `Unavailable`: the configured cloud endpoint could not be reached or failed before returning a response
- `AuthError`: the configured upstream rejected authentication
- `Internal`: an unexpected runtime or payload-mapping failure occurred

## Notes

- Routing is automatic and capability-based: IndeRun picks among the three registered
  providers per the selected Privacy Preference, not a manual on-device/cloud toggle.
- The default cloud endpoint only works from the simulator against a proxy running on the same machine.
- Apple availability depends on device class, OS version, locale, Apple Intelligence state, and model readiness.
- Apple's stream reports neither a finish reason nor token usage, so a completed on-device
  stream always shows `stop` with no usage figures — that is the runtime's limit, not a gap in
  the demo.
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
  style if you change it.
- LaMini-GPT-124M is a GPT-2-architecture model fine-tuned on the LaMini-instruction dataset, so
  it follows plain instructions ("Summarize X", "List three Y") noticeably better than base
  DistilGPT-2 despite a similar parameter count — it's the model to pick for output quality, not
  just plumbing. It has no chat template either (same plain `"role: content"` prompt join), but
  unlike DistilGPT-2 its instruction fine-tuning makes it far less prone to immediately emitting
  end-of-text on task-shaped prompts. Most other small instruction-tuned models checked
  (Qwen2.5-0.5B-Instruct, Qwen1.5-0.5B-Chat, TinyLlama-1.1B-Chat) only ship a *merged*
  `use_cache_branch`-gated KV-cache export, which the SDK's default runtime deliberately doesn't
  support (see #126's doc comment); LaMini-GPT-124M's non-merged `decoder_with_past_model`
  export is the one that fits.
- Cloud settings are persisted locally with `UserDefaults` so repeated manual testing is faster.
- The UI calls IndeRun's public Swift APIs only. It does not talk directly to Apple Foundation Models, ONNX Runtime, or a cloud API.
