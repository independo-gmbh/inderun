import type { ModelPackage } from "@independo/inderun-contracts";

import { createArticulinoRuntime } from "./articulino/runtime.js";
import type { NoiseSource } from "./articulino/math.js";
import { createOnnxWebSpeechGraphExecutor, type OnnxRuntimeWebModule } from "./ort-executor.js";
import {
  checkPackageFileName,
  NeuralSpeechRuntimeError,
  runtimeClosedError,
  type SpeechGraphExecutor,
  type NeuralSpeechAvailability,
  type NeuralSpeechRuntime,
  type NeuralSpeechSynthesisInput,
  type PcmChunk,
  type SpeechPackageFiles
} from "./runtime.js";

export interface OnnxNeuralSpeechRuntimeOptions {
  /** Resolves package files; default: `createUrlPackageFiles(source.ref)` for bundled/app_managed packages. */
  files?: SpeechPackageFiles;
  load?: () => Promise<OnnxRuntimeWebModule>;
  threads?: number;
  noise?: NoiseSource;
  speed?: number;
  pauseMs?: number;
}

/**
 * Reads package files over `fetch`, relative to `baseUrl`. Names that are empty, absolute (a path
 * or a URL) or contain a `..` component, written or percent-encoded, are refused, and the resolved
 * URL must stay under the base's origin and path, so a package cannot read outside its base.
 */
export function createUrlPackageFiles(baseUrl: string | URL): SpeechPackageFiles {
  const base = directoryUrl(baseUrl);
  return {
    async read(file) {
      checkPackageFileName(file);
      const url = new URL(file, base);
      if (url.origin !== base.origin || !url.pathname.startsWith(base.pathname)) {
        throw new NeuralSpeechRuntimeError("capability", `model file name invalid: ${file}`);
      }
      const response = await fetch(url);
      if (!response.ok) {
        throw new NeuralSpeechRuntimeError(
          "capability",
          `model files missing: ${file} (HTTP ${response.status})`
        );
      }
      return new Uint8Array(await response.arrayBuffer());
    }
  };
}

/**
 * Relative refs resolve against the page when there is one. The result always ends in a slash, so a
 * directory ref such as `/models/art` keeps its last segment when package files resolve against it.
 */
function directoryUrl(ref: string | URL): URL {
  let url: URL;
  if (typeof ref !== "string") {
    url = new URL(ref.href);
  } else {
    const documentBase = typeof document === "undefined" ? undefined : document.baseURI;
    url = new URL(ref, documentBase ?? "http://localhost/");
  }
  if (!url.pathname.endsWith("/")) url.pathname += "/";
  return url;
}

type Resolved = { runtime: NeuralSpeechRuntime } | { unavailable: NeuralSpeechAvailability };

/**
 * The default `NeuralSpeechRuntime` for the Web SDK: picks the pipeline from `speech.pipeline`
 * and runs its graphs through onnxruntime-web. One pipeline runtime is kept per package id and
 * version (`id@version`), so a new version of a package is prepared on its own graphs and files.
 * `limits.memBytes` is not enforced: the web has no host memory API.
 */
export function createOnnxNeuralSpeechRuntime(
  options: OnnxNeuralSpeechRuntimeOptions = {}
): NeuralSpeechRuntime {
  const runtimes = new Map<string, NeuralSpeechRuntime>();
  const executors: SpeechGraphExecutor[] = [];
  /** Graph calls (load/run) not yet settled; an executor closes only after they all have. */
  const inFlight = new Set<Promise<unknown>>();
  /** Aborted on close, so a running synthesis ends at its next graph boundary. */
  const closing = new AbortController();
  let closePromise: Promise<void> | undefined;

  function track<T>(call: Promise<T>): Promise<T> {
    inFlight.add(call);
    const done = (): void => {
      inFlight.delete(call);
    };
    call.then(done, done);
    return call;
  }

  function guardedExecutor(inner: SpeechGraphExecutor): SpeechGraphExecutor {
    return {
      load: (graphs) => {
        if (closePromise !== undefined) return Promise.reject(runtimeClosedError());
        return track(inner.load(graphs));
      },
      run: (role, inputs) => {
        if (closePromise !== undefined) return Promise.reject(runtimeClosedError());
        return track(inner.run(role, inputs));
      },
      close: () => inner.close?.() ?? Promise.resolve()
    };
  }

  function resolve(pkg: ModelPackage): Resolved {
    if (closePromise !== undefined) {
      return { unavailable: { available: false, reason: "runtime closed" } };
    }
    const pipeline = pkg.speech?.pipeline;
    if (pipeline !== "articulino") {
      return {
        unavailable: { available: false, reason: `unsupported pipeline '${pipeline ?? ""}'` }
      };
    }
    const key = `${pkg.id}@${pkg.version ?? ""}`;
    const existing = runtimes.get(key);
    if (existing !== undefined) return { runtime: existing };
    const sourceType = pkg.source?.sourceType ?? "unspecified";
    const ref = pkg.source?.ref;
    let files = options.files;
    if (files === undefined) {
      if ((sourceType === "bundled" || sourceType === "app_managed") && ref !== undefined) {
        files = createUrlPackageFiles(ref);
      } else {
        return {
          unavailable: {
            available: false,
            reason: `model source unavailable: '${sourceType}' needs 'files'`
          }
        };
      }
    }
    const executor = guardedExecutor(
      createOnnxWebSpeechGraphExecutor({
        files,
        ...(options.load === undefined ? {} : { load: options.load }),
        ...(options.threads === undefined ? {} : { threads: options.threads })
      })
    );
    executors.push(executor);
    const runtime = createArticulinoRuntime({
      executor,
      files,
      ...(options.noise === undefined ? {} : { noise: options.noise }),
      ...(options.speed === undefined ? {} : { speed: options.speed }),
      ...(options.pauseMs === undefined ? {} : { pauseMs: options.pauseMs })
    });
    runtimes.set(key, runtime);
    return { runtime };
  }

  return {
    async availability(pkg) {
      if (closePromise !== undefined) return { available: false, reason: "runtime closed" };
      const r = resolve(pkg);
      return "runtime" in r ? r.runtime.availability(pkg) : r.unavailable;
    },
    async prepare(pkg) {
      if (closePromise !== undefined) throw runtimeClosedError();
      const r = resolve(pkg);
      return "runtime" in r ? r.runtime.prepare(pkg) : r.unavailable;
    },
    async normalizeText(pkg, text, locale) {
      if (closePromise !== undefined || pkg.speech?.pipeline !== "articulino") return text;
      const r = resolve(pkg);
      return "runtime" in r ? ((await r.runtime.normalizeText?.(pkg, text, locale)) ?? text) : text;
    },
    async *synthesize(input: NeuralSpeechSynthesisInput): AsyncIterable<PcmChunk> {
      if (closePromise !== undefined) throw runtimeClosedError();
      const r = resolve(input.modelPackage);
      if (!("runtime" in r)) {
        throw new NeuralSpeechRuntimeError("unavailable", r.unavailable.reason ?? "unavailable");
      }
      const signals = [closing.signal, ...(input.signal === undefined ? [] : [input.signal])];
      const signal = signals.length === 1 ? closing.signal : AbortSignal.any(signals);
      let finished = false;
      for await (const chunk of r.runtime.synthesize({ ...input, signal })) {
        finished = chunk.isLast;
        yield chunk;
      }
      // Ended early because of the close, not the caller's own abort: report it.
      if (!finished && closing.signal.aborted && input.signal?.aborted !== true) {
        throw runtimeClosedError();
      }
    },
    close() {
      closePromise ??= (async () => {
        closing.abort();
        while (inFlight.size > 0) {
          await Promise.allSettled([...inFlight]);
        }
        await Promise.allSettled(executors.map((executor) => executor.close?.()));
        // Nothing resolves a pipeline after close; drop them so their graphs and files can be freed.
        runtimes.clear();
        executors.length = 0;
      })();
      return closePromise;
    }
  };
}
