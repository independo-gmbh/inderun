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

## Platform Requirements

| Platform | Minimum version        |
|----------|------------------------|
| iOS      | 15.0                   |
| Android  | API 26 (Android 8.0)   |
| Web      | Any modern browser     |

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

- `createIndeRunCapacitor(options)` — returns a handle that lazily `configure()`s on the first `run()` and memoizes it. Safe to call once at app startup.
- The low-level plugin methods `configure(options)` and `run(request)` are also exported.

The `IndeRunCapacitorPlugin`, `ConfigureOptions`, and `OpenAIProviderBootstrapOptions`
contracts — including the `openAI` bootstrap config and the web-only
`allowDirectOpenAIEndpoint` flag — are defined and documented in
`src/definitions.ts`. `run()` returns the canonical IndeRun `TaskResult`.

## Platform Notes

- Web requires `openAI` registration because the current web SDK only has the OpenAI-compatible provider.
- iOS always registers the Apple on-device provider and optionally registers OpenAI when configured.
- Android always registers the ML Kit on-device provider and optionally registers OpenAI when configured.
- Keep credentials behind `authContextRef`. For browser apps, prefer a proxy endpoint with `auth: "none"`.

## Current Limitations

- Mode 1 `run()` only.
- No plugin-level credential management API is exposed in this first cut.
- The bridge is intentionally thin; cloud provider bootstrap still has to come from the app.

## Error Handling

Errors thrown by `configure()` and `run()` conform to `IndeRunError` from
`@independo/inderun-contracts`; branch on `error.errorClass` (the shared error
taxonomy). The bridge unwraps the native error envelope before re-throwing, so
callers receive the same `IndeRunError` shape on every platform.

```ts
try {
  await inderun.run(request);
} catch (error) {
  if (error && typeof error === "object" && "errorClass" in error) {
    // error.errorClass is one of the IndeRun error taxonomy values
  }
}
```
