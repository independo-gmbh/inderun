/**
 * Provider-specific entry point for the Web member of the ONNX Runtime provider family.
 *
 * Kept out of the unified SDK index (`@independo/inderun-web`) so the top-level
 * surface stays provider-agnostic. Import from `@independo/inderun-web/onnx`
 * when registering the adapter manually or when implementing a custom
 * `OnnxTextGenerationRuntime`; most browser apps should pass `onnx` to
 * `createIndeRunWeb` from the main entry point instead.
 */
export {
  OnnxRuntimeWebProvider,
  DEFAULT_ONNX_WEB_PROVIDER_ID,
  SUPPORTED_WEB_MODEL_SOURCE_TYPES,
  type OnnxProviderOptions
} from "./providers/onnx/provider.js";

export {
  OnnxRuntimeError,
  createFixtureOnnxRuntime,
  type FixtureOnnxRuntimeOptions,
  type OnnxGenerationInput,
  type OnnxGenerationMessage,
  type OnnxGenerationOutput,
  type OnnxRuntimeAvailability,
  type OnnxRuntimeErrorKind,
  type OnnxTextGenerationRuntime
} from "./providers/onnx/runtime.js";

export {
  createTransformersJsRuntime,
  type TransformersJsRuntimeOptions,
  type TransformersModule,
  type TransformersTextGenerator
} from "./providers/onnx/transformers-runtime.js";
