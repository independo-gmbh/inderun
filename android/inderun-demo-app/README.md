# IndeRun Android Demo

Small Android demo app for validating Mode-1 IndeRun usage on Android.

The app supports:

- `On Device`: ML Kit GenAI / Gemini Nano where the runtime is available
- `Cloud`: OpenAI-compatible execution through an editable endpoint, intended to point at `@independo/inderun-demo-proxy`

## Run the demo

1. Open the `android/` workspace in Android Studio.
2. Sync Gradle.
3. Run the `inderun-demo-app` configuration on either:
   - an Android emulator for cloud testing
   - a supported physical Android device for on-device ML Kit testing

## Local proxy defaults

The demo defaults to:

- endpoint: `http://10.0.2.2:8787/api/inderun/openai-responses`
- model: `gpt-5.2`

`10.0.2.2` is the Android emulator alias for the host machine. For a physical device, replace it with a reachable LAN IP
or remote server URL.

For the local proxy flow:

```sh
pnpm --filter @independo/inderun-demo-proxy dev
```

Example with local Ollama behind the demo proxy:

```sh
export INDERUN_OPENAI_ENDPOINT_URL=http://localhost:11434/v1/responses
export INDERUN_OPENAI_MODEL=gemma4:latest
pnpm --filter @independo/inderun-demo-proxy dev
```

## Notes

- The app never embeds production secrets in `TaskRequest`.
- Cloud mode always uses `OpenAIAuthMode.none`; credentials belong behind the proxy or gateway.
- Routing is explicit. The demo does not automatically fall back between on-device and cloud providers.
- The cloud status card actively probes the configured endpoint and will warn when the local proxy is not reachable.
- On-device availability depends on ML Kit GenAI support, Gemini Nano availability, download state, and AI Core/device readiness.
