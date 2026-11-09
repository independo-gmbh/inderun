const DEFAULT_DEMO_PROXY_ENDPOINT_URL = "/api/inderun/openai-responses";
const DEFAULT_OPENAI_MODEL = "gpt-5.2";
const DEFAULT_ONNX_MODEL_PACKAGE_ID = "inderun-demo-fixture";

export function getDemoProxyEndpointUrl(env: ImportMetaEnv = import.meta.env): string {
  return env.VITE_INDERUN_DEMO_PROXY_URL ?? DEFAULT_DEMO_PROXY_ENDPOINT_URL;
}

export function getDemoModel(env: ImportMetaEnv = import.meta.env): string {
  return env.VITE_INDERUN_OPENAI_MODEL ?? DEFAULT_OPENAI_MODEL;
}

/**
 * Hugging Face-style model reference for the on-device ONNX provider.
 *
 * When unset, the demo runs the on-device route against the deterministic fixture runtime, so the
 * on-device path works offline and in CI without downloading model weights.
 */
export function getDemoOnnxModelRef(env: ImportMetaEnv = import.meta.env): string | undefined {
  const ref = env.VITE_INDERUN_ONNX_MODEL_ID;
  return ref !== undefined && ref.length > 0 ? ref : undefined;
}

/**
 * Model package id reported by the on-device provider. Only cosmetic in the demo.
 */
export function getDemoOnnxModelPackageId(env: ImportMetaEnv = import.meta.env): string {
  return env.VITE_INDERUN_ONNX_MODEL_PACKAGE_ID ?? DEFAULT_ONNX_MODEL_PACKAGE_ID;
}

/** The Voices lab (neural speech models downloaded into the browser) is opt-in: `VITE_INDERUN_VOICES_LAB=1`. */
export function isVoicesLabEnabled(env: ImportMetaEnv = import.meta.env): boolean {
  return env.VITE_INDERUN_VOICES_LAB === "1";
}

/**
 * The demo proxy's `/assets` route, which relays GitHub release assets (they send no CORS headers).
 * The proxy serves it at its root; `VITE_INDERUN_DEMO_PROXY_URL` is the OpenAI route, so an absolute
 * proxy URL maps to `<origin>/assets`. A relative one (the dev default, `/api/inderun/...`) stays on
 * the page's origin as `/api/inderun/assets`, which the Vite dev server rewrites to `/assets`.
 * `VITE_INDERUN_DEMO_ASSETS_URL` overrides both.
 */
export function getDemoAssetsUrl(env: ImportMetaEnv = import.meta.env): string {
  const override = env.VITE_INDERUN_DEMO_ASSETS_URL;
  if (override !== undefined && override.length > 0) return override;
  const proxy = getDemoProxyEndpointUrl(env);
  if (/^https?:\/\//iu.test(proxy)) return `${new URL(proxy).origin}/assets`;
  return `${proxy.replace(/\/[^/]*$/u, "")}/assets`;
}
