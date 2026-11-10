import {
  checkPackageFileName,
  NeuralSpeechRuntimeError,
  type SpeechGraphExecutor,
  type SpeechPackageFiles,
  type SpeechTensor
} from "./runtime.js";

/** Structural view of the onnxruntime-web entry points the executor uses; a real module satisfies it. */
export interface OnnxRuntimeWebModule {
  InferenceSession: {
    create(model: Uint8Array, options?: Record<string, unknown>): Promise<OnnxRuntimeWebSession>;
  };
  Tensor: new (
    type: "float32" | "int64",
    data: Float32Array | BigInt64Array,
    dims: readonly number[]
  ) => OnnxRuntimeWebTensor;
  env?: { wasm?: Record<string, unknown> };
}

/** The part of an onnxruntime-web tensor the executor reads. */
export interface OnnxRuntimeWebTensor {
  readonly type: string;
  readonly data: ArrayBufferView;
  readonly dims: readonly number[];
}

/** The part of an onnxruntime-web inference session the executor uses. */
export interface OnnxRuntimeWebSession {
  run(feeds: Record<string, OnnxRuntimeWebTensor>): Promise<Record<string, OnnxRuntimeWebTensor>>;
  release(): Promise<void>;
}

export interface OnnxWebSpeechGraphExecutorOptions {
  files: SpeechPackageFiles;
  /** Defaults to a lazy `import("onnxruntime-web")`; tests inject a fake. */
  load?: () => Promise<OnnxRuntimeWebModule>;
  /**
   * `env.wasm.numThreads`; default min(4, navigator.hardwareConcurrency ?? 1). In onnxruntime-web
   * this setting is process-global: an explicit value overwrites it, the default only applies when
   * nothing has set it yet.
   */
  threads?: number;
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function defaultThreads(): number {
  const cores = typeof navigator === "undefined" ? undefined : navigator.hardwareConcurrency;
  return Math.min(4, cores ?? 1);
}

async function importOnnxRuntimeWeb(): Promise<OnnxRuntimeWebModule> {
  // The specifier is a variable-typed string so TypeScript does not resolve the optional peer at
  // build time; apps that do not install onnxruntime-web pass their own `load`.
  return (await import("onnxruntime-web" as string)) as OnnxRuntimeWebModule;
}

/**
 * A `SpeechGraphExecutor` over onnxruntime-web's wasm backend. This file and `onnx-runtime.ts` are
 * the only ONNX Runtime-aware code of the neural speech family. Tensors are float32 or int64 only.
 * `load` replaces: it creates a session for every graph given, then releases the previous ones.
 */
export function createOnnxWebSpeechGraphExecutor(
  options: OnnxWebSpeechGraphExecutorOptions
): SpeechGraphExecutor {
  const sessions = new Map<string, OnnxRuntimeWebSession>();
  let modulePromise: Promise<OnnxRuntimeWebModule> | undefined;

  function loadModule(): Promise<OnnxRuntimeWebModule> {
    modulePromise ??= (async () => {
      let module: OnnxRuntimeWebModule;
      try {
        module = await (options.load ?? importOnnxRuntimeWeb)();
      } catch (error) {
        throw new NeuralSpeechRuntimeError(
          "unavailable",
          `onnxruntime-web is not installed: ${messageOf(error)}`,
          error
        );
      }
      const wasm = module.env?.wasm;
      if (
        wasm !== undefined &&
        (options.threads !== undefined || wasm["numThreads"] === undefined)
      ) {
        wasm["numThreads"] = options.threads ?? defaultThreads();
      }
      return module;
    })();
    // A failed import is not cached, so installing the package later can succeed.
    modulePromise.catch(() => {
      modulePromise = undefined;
    });
    return modulePromise;
  }

  return {
    async load(graphs) {
      const module = await loadModule();
      const loaded = new Map<string, OnnxRuntimeWebSession>();
      try {
        for (const [role, file] of Object.entries(graphs)) {
          try {
            checkPackageFileName(file);
            const bytes = await options.files.read(file);
            loaded.set(
              role,
              await module.InferenceSession.create(bytes, {
                executionProviders: ["wasm"],
                graphOptimizationLevel: "all"
              })
            );
          } catch (error) {
            throw new NeuralSpeechRuntimeError(
              "unavailable",
              `graph failed to load: ${role}: ${messageOf(error)}`,
              error
            );
          }
        }
      } catch (error) {
        await Promise.allSettled([...loaded.values()].map((session) => session.release()));
        throw error;
      }
      const previous = [...sessions.values()];
      sessions.clear();
      for (const [role, session] of loaded) sessions.set(role, session);
      await Promise.allSettled(previous.map((session) => session.release()));
    },

    async run(role, inputs) {
      const session = sessions.get(role);
      if (session === undefined) {
        throw new NeuralSpeechRuntimeError("internal", `graph not loaded: ${role}`);
      }
      const module = await loadModule();
      const feeds: Record<string, OnnxRuntimeWebTensor> = {};
      for (const [name, tensor] of Object.entries(inputs)) {
        if (tensor.data instanceof Float32Array) {
          feeds[name] = new module.Tensor("float32", tensor.data, tensor.shape);
        } else if (tensor.data instanceof BigInt64Array) {
          feeds[name] = new module.Tensor("int64", tensor.data, tensor.shape);
        } else {
          throw new NeuralSpeechRuntimeError(
            "internal",
            `graph input unsupported: ${role}.${name}`
          );
        }
      }
      let raw: Record<string, OnnxRuntimeWebTensor>;
      try {
        raw = await session.run(feeds);
      } catch (error) {
        throw new NeuralSpeechRuntimeError(
          "unavailable",
          `graph failed: ${role}: ${messageOf(error)}`,
          error
        );
      }
      const outputs: Record<string, SpeechTensor> = {};
      for (const [name, tensor] of Object.entries(raw)) {
        if (tensor.type === "float32" && tensor.data instanceof Float32Array) {
          outputs[name] = { shape: [...tensor.dims], data: tensor.data };
        } else if (tensor.type === "int64" && tensor.data instanceof BigInt64Array) {
          outputs[name] = { shape: [...tensor.dims], data: tensor.data };
        } else {
          throw new NeuralSpeechRuntimeError(
            "internal",
            `graph output unsupported: ${role}.${name} ${tensor.type}`
          );
        }
      }
      return outputs;
    },

    async close() {
      const open = [...sessions.values()];
      sessions.clear();
      await Promise.all(open.map((session) => session.release()));
    }
  };
}
