import {
  DEFAULT_NEURAL_SPEECH_WEB_PROVIDER_ID,
  type ModelPackage,
  type SpeechPackageFiles
} from "@independo/inderun-web/neural-speech";

// The demo's view of contracts/fixtures/speech/neural-model-catalog.json (#260). The shape is pinned
// by packages/contracts/src/neural-model-catalog.test.ts; the mapping below is pinned by the shared
// catalog-to-package.json fixture, which neural-catalog.test.ts runs against this implementation.

export interface CatalogFile {
  role?: string;
  path: string;
  url: string;
  sha256: string;
  bytes: number;
}

export interface CatalogVoice {
  id: string;
  name: string;
  locales: string[];
  gender?: string;
  file: CatalogFile;
  license: Record<string, unknown>;
}

export interface CatalogEntry {
  id: string;
  family: string;
  version: string;
  variant: string;
  license: { spdx?: string; url?: string; restrictions?: string; attribution?: string } & Record<
    string,
    unknown
  >;
  review: { status: string; notes?: string };
  runtime: { format: string; platforms: string[]; minOsVersion: string | null };
  speech: {
    pipeline: string;
    sampleRate: number;
    channels: number;
    graphs: Record<string, string>;
    frontend: { kind: string; assets: { config: string } };
  };
  files?: CatalogFile[];
  voices?: CatalogVoice[];
}

export interface NeuralCatalog {
  entries: CatalogEntry[];
}

/** The runtime formats this demo ships a runtime for: Core AI is Apple-only, so not here. */
const DEMO_RUNTIME_FORMATS = ["onnx"];

/**
 * An entry the demo can download: it has files, is not left to a manual install, and its runtime
 * format is one this demo ships.
 */
export function isInstallable(entry: CatalogEntry): boolean {
  return (
    entry.review.status !== "manual_install" &&
    (entry.files?.length ?? 0) > 0 &&
    DEMO_RUNTIME_FORMATS.includes(entry.runtime.format)
  );
}

/** Why an entry that is not installable cannot be downloaded here. */
export function unavailableReason(entry: CatalogEntry): string {
  if (
    entry.review.status !== "manual_install" &&
    !DEMO_RUNTIME_FORMATS.includes(entry.runtime.format)
  ) {
    return `the ${entry.runtime.format} runtime is not available in this browser (${entry.runtime.platforms.join(", ")} only)`;
  }
  return entry.review.notes ?? entry.review.status;
}

/** Every file of an entry, weights first, then each voice bundle. */
export function entryFiles(entry: CatalogEntry): CatalogFile[] {
  return [...(entry.files ?? []), ...(entry.voices ?? []).map((voice) => voice.file)];
}

export function entryTotalBytes(entry: CatalogEntry): number {
  return entryFiles(entry).reduce((total, file) => total + file.bytes, 0);
}

/** The package-relative storage directory of an entry: `voices-lab/<id>/<version>`. */
export function entryRef(entry: CatalogEntry): string {
  return `voices-lab/${entry.id}/${entry.version}`;
}

/**
 * Turns an installed entry into the `ModelPackage` the neural speech provider takes: `app_managed`
 * at `ref`, with `integrity.checksums` keyed by package path.
 */
export function catalogEntryToModelPackage(entry: CatalogEntry, ref: string): ModelPackage {
  const checksums: Record<string, string> = {};
  for (const file of entryFiles(entry)) checksums[file.path] = `sha256:${file.sha256}`;
  return {
    id: entry.id,
    version: entry.version,
    format: entry.runtime.format,
    variant: entry.variant,
    tasks: ["text_to_speech"],
    ...(entry.runtime.minOsVersion === null
      ? {}
      : { runtime: { minOsVersion: entry.runtime.minOsVersion } }),
    license: entry.license,
    source: { sourceType: "app_managed", ref },
    speech: {
      ...entry.speech,
      voices: (entry.voices ?? []).map((voice) => ({
        id: voice.id,
        name: voice.name,
        locales: voice.locales,
        ...(voice.gender === undefined ? {} : { gender: voice.gender }),
        file: voice.file.path,
        license: voice.license
      }))
    },
    integrity: { checksums }
  } as unknown as ModelPackage;
}

/** Provider id the Web neural speech provider takes for a package: `<default id>:<package id>`. */
export function neuralProviderId(entryId: string): string {
  return `${DEFAULT_NEURAL_SPEECH_WEB_PROVIDER_ID}:${entryId}`;
}

/** The model profile requests name to reach an installed entry (never a model id). */
export function labProfileName(entryId: string): string {
  return `voices-lab:${entryId}`;
}

/** A downloaded entry, ready to be registered. */
export interface InstalledModel {
  entry: CatalogEntry;
  modelPackage: ModelPackage;
  files: SpeechPackageFiles;
}
