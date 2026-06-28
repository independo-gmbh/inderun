# IndeRun Android Demo

Small Android demo app for validating Mode 1 IndeRun usage on Android.

The app supports:

- on-device execution through the ML Kit GenAI provider when available
- cloud execution through the OpenAI-compatible provider with proxy-first auth disabled in the app

## Run the Demo

1. Open the `android/` workspace in Android Studio.
2. Sync Gradle.
3. Run the `inderun-demo-app` configuration on an emulator or supported physical device.

## Local Proxy Defaults

- endpoint: `http://10.0.2.2:8787/api/inderun/openai-responses`
- model: `gpt-5.2`

## Notes

- The app never embeds production secrets in `TaskRequest`.
- Cloud mode uses `OpenAIAuthMode.none`.
- On-device availability depends on ML Kit GenAI support, Gemini Nano availability, download state, and device readiness.
