# IndeRun Demo Proxy

Standalone proxy backend for the IndeRun demo apps.

It exposes an OpenAI Responses-compatible route so browser, iOS, and Android demos can keep provider credentials server-side.

Requests that ask for `"stream": true` are relayed as they arrive rather than buffered, so Mode 2
works through the proxy. That is the point of the proxy for streaming: a browser cannot open its
own authenticated connection to OpenAI without shipping the key in client code.

## Routes

- `POST /api/inderun/openai-responses`
- `GET /assets?url=<encoded url>`
- `GET /health`

### `GET /assets`

Relays the model and voice files of the web Voices lab. GitHub's release download answers `302`
without `Access-Control-Allow-Origin`, so the browser cannot fetch them itself. The proxy follows
the redirect server-side and streams the body (never buffered) with `Content-Type`, `Content-Length`
when known, and the configured CORS origin.

- Allowlist: every `files[].url` and `voices[].file.url` of
  `contracts/fixtures/speech/neural-model-catalog.json`, loaded once at start-up and matched
  exactly (no prefix matching). Anything else answers `403` without an upstream call.
- No client header (cookies, authorization, ...) is ever forwarded upstream.
- Upstream `404` answers `404` (`asset not published yet (HTTP 404)`); other upstream failures `502`.
- Only `GET` is accepted.

## Configuration

- `OPENAI_API_KEY`
- `INDERUN_OPENAI_ENDPOINT_URL`
- `INDERUN_OPENAI_MODEL`
- `INDERUN_DEMO_PROXY_HOST`
- `INDERUN_DEMO_PROXY_PORT`
- `INDERUN_DEMO_PROXY_CORS_ORIGIN`
- `INDERUN_DEMO_PROXY_ASSET_CATALOG` (optional path overriding the catalog the `/assets` allowlist is read from)

## Commands

```sh
pnpm --filter @independo/inderun-demo-proxy dev
pnpm --filter @independo/inderun-demo-proxy start
pnpm --filter @independo/inderun-demo-proxy build
pnpm --filter @independo/inderun-demo-proxy test
```
