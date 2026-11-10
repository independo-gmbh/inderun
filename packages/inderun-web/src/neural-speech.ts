/**
 * Provider-specific entry point for the Web member of the neural speech provider family.
 *
 * Kept out of the unified SDK index (`@independo/inderun-web`) so the top-level surface stays
 * provider-agnostic. Import from `@independo/inderun-web/neural-speech` when registering the
 * adapter manually or when implementing a custom `NeuralSpeechRuntime`; most browser apps should
 * pass `neuralSpeech` to `createIndeRunWeb` from the main entry point instead.
 */

/** The adapter itself, plus the source types, cap and default id the router plans against. */
export {
  DEFAULT_NEURAL_SPEECH_WEB_PROVIDER_ID,
  MAX_ARTIFACT_BYTES,
  NeuralSpeechWebProvider,
  SUPPORTED_WEB_NEURAL_SPEECH_MODEL_SOURCE_TYPES,
  type NeuralSpeechProviderOptions,
  type NeuralSpeechRuntimeDescriptor
} from "./providers/neural-speech/provider.js";

/**
 * The runtime seam. The provider does no inference itself: it delegates to a
 * `NeuralSpeechRuntime`, so an app can supply its own, or `createFixtureNeuralSpeechRuntime()`
 * for demos and tests without shipping a model.
 */
export {
  NeuralSpeechRuntimeError,
  type NeuralSpeechAvailability,
  type NeuralSpeechRuntime,
  type NeuralSpeechRuntimeErrorKind,
  type NeuralSpeechSynthesisInput,
  type PcmChunk,
  type SpeechGraphExecutor,
  type SpeechPackageFiles,
  type SpeechTensor
} from "./providers/neural-speech/runtime.js";

export {
  createFixtureNeuralSpeechRuntime,
  type FixtureNeuralSpeechRuntime,
  type FixtureNeuralSpeechRuntimeOptions
} from "./providers/neural-speech/fixture-runtime.js";

/** Voice bundles and the Articulino pipeline over a `SpeechGraphExecutor`. */
export { parseSafetensors, type SafetensorsFile } from "./providers/neural-speech/safetensors.js";
export {
  createArticulinoRuntime,
  type ArticulinoRuntimeOptions
} from "./providers/neural-speech/articulino/runtime.js";
export type { NoiseSource } from "./providers/neural-speech/articulino/math.js";
export {
  parseArticulinoConfig,
  type ArticulinoConfig
} from "./providers/neural-speech/articulino/config.js";

/** The ONNX Runtime executor (onnxruntime-web, an optional peer) and the runtime composed on it. */
export {
  createOnnxWebSpeechGraphExecutor,
  type OnnxRuntimeWebModule,
  type OnnxWebSpeechGraphExecutorOptions
} from "./providers/neural-speech/ort-executor.js";
export {
  createOnnxNeuralSpeechRuntime,
  createUrlPackageFiles,
  type OnnxNeuralSpeechRuntimeOptions
} from "./providers/neural-speech/onnx-runtime.js";

/** The text frontend and WAV encoder runtimes build on. */
export { GraphemeTokenizer, splitSentences } from "./providers/neural-speech/frontend.js";
export { encodeWav } from "./providers/neural-speech/wav.js";

/**
 * The model-description contract types this entry point's options take. Re-exported for the same
 * reason as the contract types on the SDK index.
 */
export type { ModelPackage, ModelSourceType } from "@independo/inderun-contracts";
