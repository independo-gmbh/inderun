import { describe, expect, it } from "vitest";
import {
  catalogEntryToModelPackage,
  entryTotalBytes,
  isInstallable,
  unavailableReason,
  type CatalogEntry
} from "./neural-catalog";
import { catalog, loadFixture } from "./fixtures.test-support";

type Case = { id: string; entry: CatalogEntry; ref: string; expected: unknown };

describe("catalogEntryToModelPackage", () => {
  const fixture = loadFixture<{ cases: Case[] }>("catalog-to-package.json");

  for (const c of fixture.cases) {
    it(`maps the fixture case ${c.id}`, () => {
      expect(catalogEntryToModelPackage(c.entry, c.ref)).toEqual(c.expected);
    });
  }

  it("maps every installable catalog entry with its checksums keyed by package path", () => {
    for (const entry of catalog().entries.filter((e) => e.review.status !== "manual_install")) {
      const pkg = catalogEntryToModelPackage(entry, "voices-lab/x/1");
      const paths = [...(entry.files ?? []), ...(entry.voices ?? []).map((v) => v.file)].map(
        (f) => f.path
      );
      expect(Object.keys(pkg.integrity?.checksums ?? {}).sort()).toEqual([...paths].sort());
    }
  });
});

describe("entryTotalBytes", () => {
  it("sums the weights and every voice", () => {
    const entry = catalog().entries.find((e) => e.id === "articulino-de-en-int8")!;
    const expected = [...entry.files!, ...entry.voices!.map((v) => v.file)].reduce(
      (n, f) => n + f.bytes,
      0
    );
    expect(entryTotalBytes(entry)).toBe(expected);
    expect(expected).toBeGreaterThan(80_000_000);
  });
});

describe("isInstallable", () => {
  it("offers the ONNX entry and keeps the Core AI entry unavailable in the browser, files or not", () => {
    const entries = catalog().entries;
    expect(isInstallable(entries.find((e) => e.id === "articulino-de-en-int8")!)).toBe(true);
    const coreAi = entries.find((e) => e.id === "articulino-de-en-coreai")!;
    expect(coreAi.files?.length).toBeGreaterThan(0);
    expect(isInstallable(coreAi)).toBe(false);
    expect(unavailableReason(coreAi)).toContain("coreai runtime is not available in this browser");
  });
});
