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

## Advanced: registering the OpenAI provider directly

`createIndeRunWeb` wires the OpenAI Responses provider for you. To register it
manually (e.g. alongside other providers), import it from the provider subpath:

```ts
import { OpenAIResponsesProvider } from "@independo/inderun-web/openai";
```

The provider normalizes OpenAI transport and API failures into the IndeRun error
taxonomy (`AuthError`, `RateLimited`, `Timeout`, `Unavailable`, `Internal`). The
exact status-to-class mapping is documented on the provider in code — see
`OpenAIResponsesProvider` — so it stays in sync with behavior.

## Commands

```sh
pnpm --filter @independo/inderun-web build
pnpm --filter @independo/inderun-web test
```
