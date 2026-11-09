import type { ModelPackage } from "@independo/inderun-contracts";

import { createArticulinoRuntime } from "./articulino/runtime.js";
import type { NoiseSource } from "./articulino/math.js";
import { createOnnxWebSpeechGraphExecutor, type OnnxRuntimeWebModule } from "./ort-executor.js";
import {
  checkPackageFileName,
  NeuralSpeechRuntimeError,
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

  function resolve(pkg: ModelPackage): Resolved {
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
    const runtime = createArticulinoRuntime({
      executor: createOnnxWebSpeechGraphExecutor({
        files,
        ...(options.load === undefined ? {} : { load: options.load }),
        ...(options.threads === undefined ? {} : { threads: options.threads })
      }),
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
      const r = resolve(pkg);
      return "runtime" in r ? r.runtime.availability(pkg) : r.unavailable;
    },
    async prepare(pkg) {
      const r = resolve(pkg);
      return "runtime" in r ? r.runtime.prepare(pkg) : r.unavailable;
    },
    async normalizeText(pkg, text, locale) {
      if (pkg.speech?.pipeline !== "articulino") return text;
      const r = resolve(pkg);
      return "runtime" in r ? ((await r.runtime.normalizeText?.(pkg, text, locale)) ?? text) : text;
    },
    async *synthesize(input: NeuralSpeechSynthesisInput): AsyncIterable<PcmChunk> {
      const r = resolve(input.modelPackage);
      if (!("runtime" in r)) {
        throw new NeuralSpeechRuntimeError("unavailable", r.unavailable.reason ?? "unavailable");
      }
      yield* r.runtime.synthesize(input);
    }
  };
}
