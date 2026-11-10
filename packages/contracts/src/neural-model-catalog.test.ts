import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import { getModelPackageValidationIssues } from "./index.js";

// The demo catalog of downloadable neural speech models (#260, Voices lab) and the mapping that
// turns an installed entry into a ModelPackage. The catalog shape is pinned here; the mapping is
// pinned by catalog-to-package.json, which each demo's own catalogEntryToModelPackage also runs.
const load = (name: string): unknown =>
  JSON.parse(
    readFileSync(
      fileURLToPath(new URL(`../../../contracts/fixtures/speech/${name}`, import.meta.url)),
      "utf8"
    )
  );

type CatalogFile = { role?: string; path: string; url: string; sha256: string; bytes: number };
type CatalogVoice = {
  id: string;
  name: string;
  locales: string[];
  gender?: string;
  file: CatalogFile;
  license: Record<string, unknown>;
};
type CatalogEntry = {
  id: string;
  version: string;
  variant: string;
  license: Record<string, unknown>;
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
};
type MappingCase = { id: string; entry: CatalogEntry; ref: string; expected: unknown };

// Shape only (language plus subtags); it does not check subtags against the IANA registry.
const BCP47 = /^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$/;
const REVIEW_STATUSES = ["benchmark_only", "admitted", "blocked", "manual_install"];

function catalogEntryToModelPackage(entry: CatalogEntry, ref: string): Record<string, unknown> {
  const files = entry.files ?? [];
  const voices = entry.voices ?? [];
  const checksums: Record<string, string> = {};
  for (const file of [...files, ...voices.map((v) => v.file)]) {
    checksums[file.path] = `sha256:${file.sha256}`;
  }
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
      voices: voices.map((v) => ({
        id: v.id,
        name: v.name,
        locales: v.locales,
        ...(v.gender === undefined ? {} : { gender: v.gender }),
        file: v.file.path,
        license: v.license
      }))
    },
    integrity: { checksums }
  };
}

describe("neural-model-catalog.json", () => {
  const catalog = load("neural-model-catalog.json") as { entries: CatalogEntry[] };

  it("has unique entry ids", () => {
    const ids = catalog.entries.map((e) => e.id);
    expect(ids.length).toBeGreaterThan(0);
    expect(new Set(ids).size).toBe(ids.length);
  });

  it("lists the exported Core AI asset from neural-speech-assets-2 under articulino.aimodel/", () => {
    const entry = catalog.entries.find((e) => e.id === "articulino-de-en-coreai")!;
    expect(entry.review.status).toBe("benchmark_only");
    expect(entry.runtime.platforms).toEqual(["ios", "macos"]);
    const asset = (entry.files ?? []).filter((f) => f.path.startsWith("articulino.aimodel/"));
    expect(asset.map((f) => f.path).sort()).toEqual([
      "articulino.aimodel/main.hash",
      "articulino.aimodel/main.mlirb",
      "articulino.aimodel/metadata.json"
    ]);
    for (const file of asset) {
      expect(file.url).toBe(
        `https://github.com/independo-gmbh/inderun/releases/download/neural-speech-assets-2/${file.path.split("/")[1]}`
      );
    }
    expect(entry.files?.map((f) => f.path)).toContain("config.json");
    const onnx = catalog.entries.find((e) => e.id === "articulino-de-en-int8")!;
    expect(entry.voices).toEqual(onnx.voices);
  });

  for (const entry of catalog.entries) {
    describe(entry.id, () => {
      const checkFile = (file: CatalogFile) => {
        expect(file.path, "path").not.toMatch(/^\//);
        expect(file.path.split("/"), file.path).not.toContain("..");
        expect(file.url, `${file.path} url`).toMatch(/^https:\/\//);
        expect(file.sha256, `${file.path} sha256`).toMatch(/^[0-9a-f]{64}$/);
        expect(file.bytes, `${file.path} bytes`).toBeGreaterThan(0);
      };

      it("has a known review status", () => {
        expect(REVIEW_STATUSES).toContain(entry.review.status);
      });

      it("has files and voices unless it is manual_install", () => {
        if (entry.review.status === "manual_install") return;
        expect(entry.files?.length ?? 0).toBeGreaterThan(0);
        expect(entry.voices?.length ?? 0).toBeGreaterThan(0);
      });

      it("has well-formed files with unique paths", () => {
        const files = entry.files ?? [];
        files.forEach(checkFile);
        (entry.voices ?? []).forEach((v) => checkFile(v.file));
        const paths = [...files, ...(entry.voices ?? []).map((v) => v.file)].map((f) => f.path);
        expect(new Set(paths).size).toBe(paths.length);
      });

      it("has unique voice ids and BCP 47 locales", () => {
        const voices = entry.voices ?? [];
        expect(new Set(voices.map((v) => v.id)).size).toBe(voices.length);
        for (const voice of voices) {
          expect(voice.locales.length, voice.id).toBeGreaterThan(0);
          for (const locale of voice.locales) expect(locale, voice.id).toMatch(BCP47);
        }
      });

      it("lists its graphs and frontend config among its files", () => {
        if (entry.review.status === "manual_install" && !entry.files) return;
        const paths = new Set((entry.files ?? []).map((f) => f.path));
        for (const [role, ref] of Object.entries(entry.speech.graphs)) {
          // A Core AI graph reference is `<asset>#<function>`; the asset is a directory of files.
          const [asset, fn] = ref.split("#");
          const listed =
            fn === undefined
              ? paths.has(asset!)
              : [...paths].some((path) => path.startsWith(`${asset}/`));
          expect(listed, `graph ${role}: ${ref}`).toBe(true);
        }
        expect(paths.has(entry.speech.frontend.assets.config)).toBe(true);
      });

      it("maps to a valid ModelPackage (an installable entry; manual_install has no voices)", () => {
        if (entry.review.status === "manual_install") return;
        const pkg = catalogEntryToModelPackage(entry, "voices-lab/x/1");
        expect(getModelPackageValidationIssues(pkg)).toEqual([]);
      });
    });
  }
});

describe("catalog-to-package.json", () => {
  const fixture = load("catalog-to-package.json") as { cases: MappingCase[] };
  const catalog = load("neural-model-catalog.json") as { entries: CatalogEntry[] };

  it("covers the full ONNX entry, a single-voice entry and the Core AI directory asset", () => {
    const ids = fixture.cases.map((c) => c.id);
    expect(new Set(ids).size).toBe(ids.length);
    expect(ids).toContain("onnx_entry_all_voices");
    expect(ids).toContain("single_voice_entry");
    expect(ids).toContain("coreai_directory_asset");
  });

  for (const c of fixture.cases) {
    const catalogEntry = catalog.entries.find((e) => e.id === c.entry.id);
    if (catalogEntry) {
      it(`${c.id}: its entry is the catalog entry verbatim`, () => {
        expect(c.entry).toEqual(catalogEntry);
      });
    }

    it(`${c.id}: expected is a valid ModelPackage`, () => {
      expect(getModelPackageValidationIssues(c.expected)).toEqual([]);
    });

    it(`${c.id}: the reference mapping produces expected`, () => {
      expect(catalogEntryToModelPackage(c.entry, c.ref)).toEqual(c.expected);
    });
  }
});
