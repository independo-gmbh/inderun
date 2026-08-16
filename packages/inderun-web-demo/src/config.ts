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
