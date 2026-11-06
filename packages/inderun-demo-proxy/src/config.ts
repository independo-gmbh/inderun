import {
  DEFAULT_DEMO_PROXY_HOST,
  DEFAULT_DEMO_PROXY_PORT,
  DEFAULT_OPENAI_MODEL,
  DEFAULT_OPENAI_RESPONSES_URL
} from "./shared.js";

export interface DemoProxyConfig {
  apiKey?: string;
  endpointUrl: string;
  model: string;
  host: string;
  port: number;
  corsOrigin: string;
  /** Exact URLs the `/assets` route may fetch. Defaults to the catalog's file and voice URLs. */
  assetAllowlist?: ReadonlySet<string>;
  /** Path to `neural-model-catalog.json`; read once at start-up. */
  assetCatalogPath?: string;
  /** Injected in tests so `/assets` never reaches the network. */
  assetFetch?: typeof fetch;
}

export function resolveDemoProxyConfig(env: NodeJS.ProcessEnv = process.env): DemoProxyConfig {
  return {
    apiKey: getNonEmpty(env.OPENAI_API_KEY),
    endpointUrl: getNonEmpty(env.INDERUN_OPENAI_ENDPOINT_URL) ?? DEFAULT_OPENAI_RESPONSES_URL,
    model: getNonEmpty(env.INDERUN_OPENAI_MODEL) ?? DEFAULT_OPENAI_MODEL,
    host: getNonEmpty(env.INDERUN_DEMO_PROXY_HOST) ?? DEFAULT_DEMO_PROXY_HOST,
    port: parsePort(env.INDERUN_DEMO_PROXY_PORT),
    corsOrigin: getNonEmpty(env.INDERUN_DEMO_PROXY_CORS_ORIGIN) ?? "*",
    assetCatalogPath: getNonEmpty(env.INDERUN_DEMO_PROXY_ASSET_CATALOG)
  };
}

function parsePort(value: string | undefined): number {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0 || parsed > 65535) {
    return DEFAULT_DEMO_PROXY_PORT;
  }

  return parsed;
}

function getNonEmpty(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed && trimmed.length > 0 ? trimmed : undefined;
}
