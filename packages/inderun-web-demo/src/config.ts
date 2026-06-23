const DEFAULT_DEMO_PROXY_ENDPOINT_URL = "/api/inderun/openai-responses";
const DEFAULT_OPENAI_MODEL = "gpt-5.2";

export function getDemoProxyEndpointUrl(env: ImportMetaEnv = import.meta.env): string {
  return env.VITE_INDERUN_DEMO_PROXY_URL ?? DEFAULT_DEMO_PROXY_ENDPOINT_URL;
}

export function getDemoModel(env: ImportMetaEnv = import.meta.env): string {
  return env.VITE_INDERUN_OPENAI_MODEL ?? DEFAULT_OPENAI_MODEL;
}
