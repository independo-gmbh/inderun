# @independo/inderun-web

TypeScript/Web SDK for IndeRun.

This package provides the Web SDK entrypoint, the engine core, routing, telemetry, error normalization, and the OpenAI-compatible cloud provider.

## Basic Usage

```ts
import { createIndeRunWeb } from "@independo/inderun-web";

const inderun = createIndeRunWeb({
  openAI: {
    model: "gpt-5.2",
    endpointUrl: "/api/inderun/openai-responses",
    auth: "none"
  }
});

const result = await inderun.run({
  schemaVersion: "1.0",
  task: { kind: "text_to_text" },
  prompt: "Write a one-sentence summary of IndeRun."
});
```

## Security Model

Browser apps should use a proxy endpoint and keep provider credentials server-side. `createIndeRunWeb` rejects direct calls to the public OpenAI Responses endpoint unless `allowDirectOpenAIEndpoint: true` is set for a controlled environment.

## Error Mapping

The OpenAI provider maps transport and API failures into IndeRun errors:

- `401` / `403` -> `AuthError`
- `429` -> `RateLimited`
- `408` / `504` -> `Timeout`
- `409` / `5xx` -> `Unavailable`
- other non-2xx responses -> `Internal`

## Commands

```sh
pnpm --filter @independo/inderun-web build
pnpm --filter @independo/inderun-web test
```
