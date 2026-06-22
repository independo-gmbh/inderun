# IndeRun Demo

This sample app is a broader iOS SwiftUI demo for the full IndeRun iOS SDK. It lets you run the same text-to-text
request through either:

- Apple Foundation Models on-device
- an OpenAI-compatible cloud endpoint configured in the app, typically via `@independo/inderun-demo-proxy`

## Requirements

- Xcode 26.0 or newer with the iOS 26.0 SDK installed
- For on-device mode:
  - a physical iPhone or iPad that supports Apple Intelligence and Apple Foundation Models
  - Apple Intelligence enabled on the device
  - an OS/device/locale state where the system model is eligible and ready
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
- `IndeRunOpenAIProviders`

## Manual Demo Test

1. Open `IndeRunDemo.xcodeproj` in Xcode.
2. Configure a signing team for the app target if Xcode requests one.
3. For on-device mode, choose a real supported iOS 26.0+ device.
4. For cloud mode, you can use either the simulator or a device.
5. Build and run the app.
6. Review the on-device and cloud availability cards.
   - the cloud card now actively probes the configured endpoint
   - for the default local proxy path, it probes `/health` before you run a request
7. Keep or edit the prompt.
8. Use the segmented control to choose `On Device` or `Cloud`.
9. If you choose `Cloud`, confirm the endpoint and model settings:
   - simulator local proxy default: `http://127.0.0.1:8787/api/inderun/openai-responses`
   - physical device local proxy: replace `127.0.0.1` with your Mac's LAN IP
   - remote proxy or remote OpenAI-compatible server: enter its full URL
10. Tap the run button for the selected mode.
11. Confirm one of these outcomes:
   - success: generated text appears with run metadata
   - normalized failure: the UI shows `IndeRunException.errorClass`, message, and run metadata

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

- `CapabilityMismatch`: Apple Foundation Models are unavailable for the current device or system state
- `Offline`: cloud execution was selected but the device has no network connection
- `Unavailable`: the configured cloud endpoint could not be reached or failed before returning a response
- `AuthError`: the configured upstream rejected authentication
- `Internal`: an unexpected runtime or payload-mapping failure occurred

## Notes

- This demo uses explicit execution mode selection. It does not automatically reroute or fall back between providers.
- The default cloud endpoint only works from the simulator against a proxy running on the same machine.
- Apple availability depends on device class, OS version, locale, Apple Intelligence state, and model readiness.
- Cloud settings are persisted locally with `UserDefaults` so repeated manual testing is faster.
- The UI calls IndeRun's public Swift APIs only. It does not talk directly to Apple Foundation Models or a cloud API.
