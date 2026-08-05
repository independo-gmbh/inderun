import type { ModelPackage } from "@independo/inderun-contracts";
import {
  OnnxRuntimeError,
  type OnnxGenerationInput,
  type OnnxGenerationOutput,
  type OnnxRuntimeAvailability,
  type OnnxTextGenerationRuntime
} from "./onnx-runtime.js";

/**
 * Structural view of the `@huggingface/transformers` entry points this runtime uses.
 *
 * The dependency is optional, so the module is typed structurally instead of imported for types.
 */
export interface TransformersModule {
  /** Builds a task pipeline, downloading or loading model assets as needed. */
  pipeline: (
    task: string,
    model?: string,
    options?: Record<string, unknown>
  ) => Promise<TransformersTextGenerator>;
  /** Global Transformers.js environment used to point the loader at local model assets. */
  env?: Record<string, unknown>;
}

/**
 * Structural view of a Transformers.js `text-generation` pipeline.
 */
export type TransformersTextGenerator = (
  input: unknown,
  options?: Record<string, unknown>
) => Promise<unknown>;

/**
 * Configuration for the Transformers.js-backed ONNX runtime.
 */
export interface TransformersJsRuntimeOptions {
  /**
   * Overrides how the `@huggingface/transformers` module is loaded. Tests inject a fake module;
   * production uses a lazy dynamic import so the dependency stays optional.
   */
  load?: () => Promise<TransformersModule>;
  /**
   * Execution backend passed to Transformers.js. Defaults to `webgpu` when `navigator.gpu`
   * exists and `wasm` otherwise. This is an ONNX Runtime execution backend, not an IndeRun
   * routing concept.
   */
  device?: string;
  /**
   * Weight quantization passed to Transformers.js (for example `q4`, `q4f16`, `q8`, `fp16`,
   * `fp32`).
   *
   * Defaults to a quantized variant (`q4f16` on WebGPU, `q4` otherwise) because Transformers.js
   * would otherwise load full `fp32` weights, which exhausts browser memory for all but the
   * smallest models. Set explicitly when the model does not publish the default variant.
   */
  dtype?: string;
  /** Base path or URL for locally served model assets (`bundled` / `app_managed` sources). */
  localModelPath?: string;
  /** Extra options merged into the Transformers.js `pipeline()` call. */
  pipelineOptions?: Record<string, unknown>;
  /**
   * Supplies a pre-built generator instead of letting this runtime construct one. Required for
   * `programmatic` model sources, where the application owns model resolution.
   */
  createGenerator?: (context: {
    modelPackage: ModelPackage;
    module: TransformersModule;
    device: string;
  }) => Promise<TransformersTextGenerator>;
}

const TEXT_GENERATION_TASK = "text-generation";

/**
 * Creates the default Web ONNX runtime, backed by Transformers.js (which runs ONNX models through
 * `onnxruntime-web`).
 *
 * ONNX Runtime GenAI has no browser build, so Transformers.js fills the generative-loop role
 * (tokenization, sampling, KV cache) behind the `OnnxTextGenerationRuntime` seam. Applications that
 * need a different runtime implement the seam themselves and pass it to the provider.
 *
 * `@huggingface/transformers` is an optional dependency the application installs: when it is absent
 * the runtime
 * reports itself unavailable instead of throwing, so routing degrades to an explainable
 * `capability_unavailable` rejection.
 *
 * @param options - Loader, backend, and model-resolution overrides.
 */
export function createTransformersJsRuntime(
  options: TransformersJsRuntimeOptions = {}
): OnnxTextGenerationRuntime {
  let modulePromise: Promise<TransformersModule> | undefined;
  let generatorPromise: Promise<TransformersTextGenerator> | undefined;

  async function loadModule(): Promise<TransformersModule> {
    modulePromise ??= (options.load ?? loadTransformersModule)();
    return modulePromise;
  }

  async function loadGenerator(modelPackage: ModelPackage): Promise<TransformersTextGenerator> {
    generatorPromise ??= (async () => {
      const module = await loadModule();
      const device = resolveDevice(options.device);

      if (options.createGenerator) {
        return options.createGenerator({ modelPackage, module, device });
      }

      const modelRef = getModelRef(modelPackage);
      if (!modelRef) {
        throw new OnnxRuntimeError(
          "capability",
          "model source unavailable: the model package does not declare source.ref."
        );
      }

      applyEnvironment(module, modelPackage, options.localModelPath);

      const pipelineOptions: Record<string, unknown> = {
        device,
        dtype: options.dtype ?? defaultDtype(device),
        ...(options.pipelineOptions ?? {})
      };

      return module.pipeline(TEXT_GENERATION_TASK, modelRef, pipelineOptions);
    })();

    return generatorPromise;
  }

  return {
    async prepare(modelPackage: ModelPackage): Promise<OnnxRuntimeAvailability> {
      let module: TransformersModule;
      try {
        module = await loadModule();
      } catch (err) {
        modulePromise = undefined;
        return {
          available: false,
          reason: `runtime package unavailable: install the optional dependency @huggingface/transformers (${getErrorMessage(err)}).`
        };
      }

      if (typeof module.pipeline !== "function") {
        return {
          available: false,
          reason:
            "runtime initialization failed: @huggingface/transformers did not expose pipeline()."
        };
      }

      if (modelPackage.format !== "onnx") {
        return {
          available: false,
          reason: `unsupported model format: the Transformers.js runtime consumes ONNX weights, received '${modelPackage.format}'.`
        };
      }

      const sourceType = modelPackage.source?.sourceType;
      if (sourceType === "programmatic" && !options.createGenerator) {
        return {
          available: false,
          reason:
            "model source unavailable: programmatic model packages require a createGenerator option."
        };
      }

      if (!options.createGenerator && !getModelRef(modelPackage)) {
        return {
          available: false,
          reason: "model source unavailable: the model package does not declare source.ref."
        };
      }

      return { available: true };
    },

    async generate(
      input: OnnxGenerationInput,
      signal?: AbortSignal
    ): Promise<OnnxGenerationOutput> {
      let generator: TransformersTextGenerator;
      try {
        generator = await loadGenerator(input.modelPackage);
      } catch (err) {
        generatorPromise = undefined;
        if (err instanceof OnnxRuntimeError) throw err;
        if (isResourceExhaustion(err)) {
          throw new OnnxRuntimeError(
            "unavailable",
            `insufficient memory to load the model: ${getErrorMessage(err)}. Try a smaller model or a more aggressive dtype (for example 'q4').`,
            err
          );
        }
        throw new OnnxRuntimeError(
          "capability",
          `model files missing or unreadable: ${getErrorMessage(err)}`,
          err
        );
      }

      if (signal?.aborted) {
        throw new OnnxRuntimeError("timeout", "ONNX generation was aborted before it started.");
      }

      let raw: unknown;
      try {
        raw = await generator(input.messages, createGenerationOptions(input, signal));
      } catch (err) {
        throw new OnnxRuntimeError(
          "internal",
          `ONNX generation failed: ${getErrorMessage(err)}`,
          err
        );
      }

      const text = extractGeneratedText(raw);
      if (text === undefined) {
        throw new OnnxRuntimeError(
          "internal",
          "model output malformed: the Transformers.js pipeline returned no text."
        );
      }

      return { text };
    }
  };
}

async function loadTransformersModule(): Promise<TransformersModule> {
  // The specifier stays a literal so bundlers and dev servers resolve the bare package name; the
  // `as string` cast keeps TypeScript from requiring the optional dependency's types here. Apps that
  // do not install Transformers.js should pass their own `load` (or a different runtime) rather than
  // relying on this default, which their bundler will fail to resolve.
  return (await import("@huggingface/transformers" as string)) as TransformersModule;
}

/**
 * Browser-viable weight variant. Transformers.js defaults to `fp32`, which makes ONNX Runtime
 * allocate the full-precision model and fail session creation with an allocation error for
 * anything but tiny models.
 */
function defaultDtype(device: string): string {
  return device === "webgpu" ? "q4f16" : "q4";
}

function resolveDevice(configured?: string): string {
  if (configured !== undefined) return configured;
  const gpu = (globalThis as { navigator?: { gpu?: unknown } }).navigator?.gpu;
  return gpu ? "webgpu" : "wasm";
}

function getModelRef(modelPackage: ModelPackage): string | undefined {
  const ref = modelPackage.source?.ref;
  return typeof ref === "string" && ref.length > 0 ? ref : undefined;
}

function applyEnvironment(
  module: TransformersModule,
  modelPackage: ModelPackage,
  localModelPath?: string
): void {
  const env = module.env;
  if (!env) return;

  const sourceType = modelPackage.source?.sourceType;
  if (sourceType === "bundled" || sourceType === "app_managed") {
    env.allowLocalModels = true;
    env.allowRemoteModels = false;
    if (localModelPath !== undefined) {
      env.localModelPath = localModelPath;
    }
  }
}

function createGenerationOptions(
  input: OnnxGenerationInput,
  signal?: AbortSignal
): Record<string, unknown> {
  const generation = input.generation;
  const generationOptions: Record<string, unknown> = {};

  if (generation?.maxOutputTokens !== undefined) {
    generationOptions.max_new_tokens = generation.maxOutputTokens;
  }
  if (generation?.temperature !== undefined) {
    generationOptions.temperature = generation.temperature;
    generationOptions.do_sample = generation.temperature > 0;
  }
  if (generation?.topP !== undefined) {
    generationOptions.top_p = generation.topP;
  }
  if (generation?.stop !== undefined && generation.stop.length > 0) {
    generationOptions.stop_strings = generation.stop;
  }
  if (signal !== undefined) {
    generationOptions.signal = signal;
  }

  return generationOptions;
}

function extractGeneratedText(raw: unknown): string | undefined {
  const first = Array.isArray(raw) ? raw[0] : raw;
  if (!isRecord(first)) {
    return typeof first === "string" ? first : undefined;
  }

  const generated = first.generated_text;
  if (typeof generated === "string") {
    return generated;
  }

  if (Array.isArray(generated)) {
    const last = generated[generated.length - 1];
    if (isRecord(last) && typeof last.content === "string") {
      return last.content;
    }
  }

  return undefined;
}

/**
 * Detects out-of-memory failures surfaced by ONNX Runtime session creation, which arrive as
 * allocation errors from the WASM/native layer rather than as typed errors.
 */
function isResourceExhaustion(error: unknown): boolean {
  const message = getErrorMessage(error).toLowerCase();
  return (
    message.includes("bad_alloc") ||
    message.includes("out of memory") ||
    message.includes("failed to allocate") ||
    message.includes("allocation failed")
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function getErrorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
