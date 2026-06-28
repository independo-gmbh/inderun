# `@independo/capacitor-inderun`

Thin Capacitor bridge for IndeRun Mode 1 `run()` execution.

The package delegates to the existing platform SDKs instead of re-implementing routing, provider logic, or normalized error handling:

- web: `@independo/inderun-web`
- iOS: Swift SDK in `ios/IndeRun`
- Android: Kotlin SDK in `android/inderun-*`

## Install

```sh
pnpm add @independo/capacitor-inderun @capacitor/core
```

Then sync native projects with your normal Capacitor workflow.

## Usage

```ts
import { createIndeRunCapacitor } from "@independo/capacitor-inderun";

const inderun = createIndeRunCapacitor({
  openAI: {
    model: "gpt-5.2",
    endpointUrl: "/api/inderun/openai-responses",
    auth: "none"
  }
});

const result = await inderun.run({
  schemaVersion: "1.0",
  task: { kind: "text_to_text" },
  prompt: "Summarize why a thin bridge matters.",
  constraints: { privacy: "cloud_required" }
});
```

## API

Preferred usage:

- `const inderun = createIndeRunCapacitor(configureOptions)`
- `await inderun.run(request)`

Low-level plugin methods:

- `configure(configureOptions)`
- `run(request)`

- `configureOptions.openAI`: bootstrap config for registering the existing OpenAI-compatible provider when cloud execution is needed
- `configureOptions.allowDirectOpenAIEndpoint`: web-only opt-in for direct browser calls to `https://api.openai.com/v1/responses`

The return value is the canonical IndeRun `TaskResult`.

## Platform Notes

- Web requires `openAI` registration because the current web SDK only has the OpenAI-compatible provider.
- iOS always registers the Apple on-device provider and optionally registers OpenAI when configured.
- Android always registers the ML Kit on-device provider and optionally registers OpenAI when configured.
- Keep credentials behind `authContextRef`. For browser apps, prefer a proxy endpoint with `auth: "none"`.

## Current Limitations

- Mode 1 `run()` only.
- No plugin-level credential management API is exposed in this first cut.
- The bridge is intentionally thin; cloud provider bootstrap still has to come from the app.
