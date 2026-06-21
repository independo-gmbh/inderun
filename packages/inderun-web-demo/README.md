# IndeRun Web Demo

This package is the web client workpackage for issue #11. It is a minimal browser demo for the canonical IndeRun Mode-1
cloud flow. Run it alongside `@independo/inderun-demo-proxy` for live execution.

- enter a prompt
- execute through `@independo/inderun-web`
- display generated text or a normalized `IndeRunException`
- show `runId`, `telemetry.providerUsed`, and `telemetry.totalMs`

## Security model

The browser app uses the existing proxy-first configuration from `@independo/inderun-web`:

- the client calls `VITE_INDERUN_DEMO_PROXY_URL`
- the standalone `@independo/inderun-demo-proxy` backend handles that route server-side
- the browser never sends raw provider secrets in the request payload

Optional environment variables:

- `VITE_INDERUN_DEMO_PROXY_URL` optional proxy URL, defaults to `/api/inderun/openai-responses`
- `VITE_INDERUN_OPENAI_MODEL` optional client-side displayed/requested model default

## Commands

```sh
pnpm --filter @independo/inderun-web-demo dev
pnpm --filter @independo/inderun-web-demo build
pnpm --filter @independo/inderun-web-demo preview
pnpm --filter @independo/inderun-web-demo test
```

## Review flow

1. Start the proxy backend with `pnpm --filter @independo/inderun-demo-proxy dev`.
2. Start the web client with `pnpm --filter @independo/inderun-web-demo dev`.
3. Open the local Vite URL and run a prompt.
4. Confirm the app shows text output or a normalized error plus metadata.

During Vite development, the web client uses a same-origin `/api/inderun/*` URL and Vite forwards those requests to
`http://127.0.0.1:8787`. For a statically served build, set `VITE_INDERUN_DEMO_PROXY_URL` to the full proxy URL.
