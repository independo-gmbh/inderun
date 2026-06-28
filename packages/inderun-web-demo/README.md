# IndeRun Web Demo

Minimal browser demo for the Mode 1 cloud flow.

It runs a prompt through `@independo/inderun-web`, shows either generated text or a normalized error, and surfaces the run metadata returned by the SDK.

## Security Model

The browser app uses the proxy-first configuration from `@independo/inderun-web`. The browser does not carry raw provider secrets.

## Commands

```sh
pnpm --filter @independo/inderun-web-demo dev
pnpm --filter @independo/inderun-web-demo build
pnpm --filter @independo/inderun-web-demo preview
pnpm --filter @independo/inderun-web-demo test
```

## Review Flow

1. Start `@independo/inderun-demo-proxy`.
2. Start this demo.
3. Open the local Vite URL and run a prompt.
