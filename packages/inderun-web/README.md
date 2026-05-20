# @independo/inderun-web

This is the JS/TS Engine Core and Web SDK package for the IndeRun framework.

It implements:
- `ProviderRegistry` for registering execution adapters.
- `Router` for deterministic routing based on policy and host capability snapshots.
- Standard error taxonomy (`IndeRunException`) and error mapping.
- Core orchestrator flow with timing and telemetry measurements.
- `OpenAIResponsesProvider` for Mode-1 text-to-text cloud execution through the OpenAI Responses API.

## Mode 1 cloud run with OpenAI

Use `createIndeRunWeb` to create a Web SDK instance with the OpenAI Responses provider registered:

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
  prompt: "Write a one-sentence summary of IndeRun.",
  policy: { execution: "cloud" }
});

console.log(result.output.text);
```

The configured endpoint must accept an OpenAI Responses-compatible request body and return an OpenAI Responses-compatible
JSON response. The provider sends `POST` requests with `model` and `input`, plus supported generation hints such as
`max_output_tokens`, `temperature`, `top_p`, and `stop`.

### Do not ship OpenAI API keys in browser apps

Production browser apps should use a same-origin proxy endpoint, as shown above. `createIndeRunWeb` is proxy-first: it
throws if configured to call `https://api.openai.com/v1/responses` directly with browser-side credentials unless
`allowDirectOpenAIEndpoint: true` is set.

The proxy should:

- keep `OPENAI_API_KEY` only on the server
- reject unauthenticated app users before forwarding requests
- add the OpenAI `Authorization` header server-side
- forward only the Responses fields your app supports
- return the OpenAI response JSON to the browser
- never log prompts, responses, API keys, or bearer tokens unless your app has explicit consent and safe handling

Example proxy route:

```ts
export async function POST(request: Request): Promise<Response> {
  const body = await request.text();

  const upstream = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${process.env.OPENAI_API_KEY}`,
      "Content-Type": "application/json"
    },
    body
  });

  return new Response(await upstream.text(), {
    status: upstream.status,
    statusText: upstream.statusText,
    headers: {
      "Content-Type": upstream.headers.get("Content-Type") ?? "application/json"
    }
  });
}
```

If you use the official OpenAI TypeScript SDK, use it inside this server-side proxy, not in browser code that can expose
credentials.

Direct OpenAI calls are supported only through an explicit opt-in for controlled environments:

```ts
const inderun = createIndeRunWeb({
  openAI: {
    model: "gpt-5.2",
    auth: "authContextRef"
  },
  allowDirectOpenAIEndpoint: true,
  hostServices: {
    secureStorage: mySecureStorage
  }
});
```

In this mode, the request must provide `authContextRef`, or the provider config must define a default `authContextRef`.
The provider resolves that slot through `SecureStorageService` and only then adds the transport-level `Authorization`
header. Do not place API keys, bearer tokens, or other secrets directly in `TaskRequest`.

## Error mapping

The OpenAI provider maps transport and API failures to the normalized IndeRun taxonomy:

- `401` and `403` -> `AuthError`
- `429` -> `RateLimited`
- `408` and `504` -> `Timeout`
- `409` and `5xx` -> `Unavailable`
- other non-2xx responses -> `Internal`

## Commands

```sh
# Build the package
pnpm --filter @independo/inderun-web build

# Run unit tests
pnpm --filter @independo/inderun-web test
```
