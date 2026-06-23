# IndeRun Demo Proxy

Standalone backend for the IndeRun demo apps. It exposes one OpenAI Responses-compatible proxy route that web, iOS, and
Android demos can use without embedding provider secrets in app request payloads.

## Routes

- `POST /api/inderun/openai-responses`: forwards a Responses-compatible request to the configured upstream.
- `GET /health`: returns the configured upstream URL, model, and whether bearer auth is configured.

## Configuration

- `OPENAI_API_KEY`: optional bearer token for the configured upstream
- `INDERUN_OPENAI_ENDPOINT_URL`: optional full upstream override
- `INDERUN_OPENAI_MODEL`: optional server-side model override
- `INDERUN_DEMO_PROXY_HOST`: optional bind host, defaults to `127.0.0.1`
- `INDERUN_DEMO_PROXY_PORT`: optional bind port, defaults to `8787`
- `INDERUN_DEMO_PROXY_CORS_ORIGIN`: optional CORS origin, defaults to `*`

Default upstream is `https://api.openai.com/v1/responses`. That default requires `OPENAI_API_KEY`. Custom upstreams can
run without bearer auth, which supports local OpenAI-compatible servers such as Ollama:

```sh
export INDERUN_OPENAI_ENDPOINT_URL=http://localhost:11434/v1/responses
export INDERUN_OPENAI_MODEL=gemma4:latest
pnpm --filter @independo/inderun-demo-proxy dev
```

For OpenAI:

```sh
export OPENAI_API_KEY=...
pnpm --filter @independo/inderun-demo-proxy dev
```

## Commands

```sh
pnpm --filter @independo/inderun-demo-proxy dev
pnpm --filter @independo/inderun-demo-proxy start
pnpm --filter @independo/inderun-demo-proxy build
pnpm --filter @independo/inderun-demo-proxy test
```
