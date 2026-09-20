/**
 * Provider-specific entry point for the Web member of the ONNX Runtime provider family.
 *
 * Kept out of the unified SDK index (`@independo/inderun-web`) so the top-level
 * surface stays provider-agnostic. Import from `@independo/inderun-web/onnx`
 * when registering the adapter manually or when implementing a custom
 * `OnnxTextGenerationRuntime`; most browser apps should pass `onnx` to
 * `createIndeRunWeb` from the main entry point instead.
 *
 * See {@link https://github.com/independo-gmbh/inderun/blob/main/docs/architecture/onnx-runtime-provider-family.md | the ONNX Runtime provider family doc}
 * for the model IO contract, supported source types, and error mapping.
 */

/** The adapter itself, plus the source types and default id the router plans against. */
export {
  OnnxRuntimeWebProvider,
  DEFAULT_ONNX_WEB_PROVIDER_ID,
  SUPPORTED_WEB_MODEL_SOURCE_TYPES,
  type OnnxProviderOptions
} from "./providers/onnx/provider.js";

/**
 * The runtime seam. The provider does no inference itself: it delegates to an
 * `OnnxTextGenerationRuntime`, so an app can swap in its own engine, or
 * `createFixtureOnnxRuntime()` for demos and tests without shipping a model.
 */
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

/**
 * The model-description contract types this entry point's options take.
 * Re-exported for the same reason as the contract types on the SDK index — see
 * the note there.
 */
export type { ModelPackage, ModelSourceType } from "@independo/inderun-contracts";

/**
 * The default runtime, backed by `@huggingface/transformers`. That package is an
 * optional peer dependency and is reached structurally through
 * `TransformersModule`, so nothing here forces it on apps that supply their own
 * runtime.
 */
export {
  createTransformersJsRuntime,
  type TransformersJsRuntimeOptions,
  type TransformersModule,
  type TransformersTextGenerator
} from "./providers/onnx/transformers-runtime.js";
