# IndeRun Demo Proxy

Standalone proxy backend for the IndeRun demo apps.

It exposes an OpenAI Responses-compatible route so browser, iOS, and Android demos can keep provider credentials server-side.

## Routes

- `POST /api/inderun/openai-responses`
- `GET /health`

## Configuration

- `OPENAI_API_KEY`
- `INDERUN_OPENAI_ENDPOINT_URL`
- `INDERUN_OPENAI_MODEL`
- `INDERUN_DEMO_PROXY_HOST`
- `INDERUN_DEMO_PROXY_PORT`
- `INDERUN_DEMO_PROXY_CORS_ORIGIN`

## Commands

```sh
pnpm --filter @independo/inderun-demo-proxy dev
pnpm --filter @independo/inderun-demo-proxy start
pnpm --filter @independo/inderun-demo-proxy build
pnpm --filter @independo/inderun-demo-proxy test
```
