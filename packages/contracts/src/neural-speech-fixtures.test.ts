import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import { getModelPackageValidationIssues } from "./index.js";

// The shared neural speech fixtures (#260). The three neural speech providers read them from
// these paths; this test keeps them well-formed, so a broken entry fails here rather than as a
// confusing failure in one SDK.
const load = (name: string): unknown =>
  JSON.parse(
    readFileSync(
      fileURLToPath(new URL(`../../../contracts/fixtures/speech/${name}`, import.meta.url)),
      "utf8"
    )
  );

type FrontendCase = { id: string; text: string; sentences: string[]; tokens: number[][] };
type Frontend = { vocab: Record<string, number>; cases: FrontendCase[] };

type LifecycleCase = {
  id: string;
  description: string;
  setup: string;
  expect: Record<string, unknown>;
  timeoutMs: number;
};
type Lifecycle = {
  $expectKeys: Record<string, string>;
  package: unknown;
  format: unknown;
  cases: LifecycleCase[];
};

describe("neural-frontend.json", () => {
  const fixture = load("neural-frontend.json") as Frontend;
  const ids = new Set(Object.values(fixture.vocab));

  it("has unique case ids", () => {
    const caseIds = fixture.cases.map((c) => c.id);
    expect(new Set(caseIds).size).toBe(caseIds.length);
  });

  it("has one token array per sentence, over ids that exist in the vocab", () => {
    for (const c of fixture.cases) {
      expect(c.tokens.length, c.id).toBe(c.sentences.length);
      for (const sentence of c.tokens) {
        for (const id of sentence) {
          expect(ids.has(id), `${c.id}: ${id}`).toBe(true);
        }
      }
    }
  });
});

describe("neural-speech-lifecycle.json", () => {
  const fixture = load("neural-speech-lifecycle.json") as Lifecycle;

  it("has unique case ids", () => {
    const caseIds = fixture.cases.map((c) => c.id);
    expect(new Set(caseIds).size).toBe(caseIds.length);
  });

  it("gives every case a description, a setup, an expectation and a bounded wait", () => {
    for (const c of fixture.cases) {
      expect(c.description.length, c.id).toBeGreaterThan(0);
      expect(c.setup.length, c.id).toBeGreaterThan(0);
      expect(Object.keys(c.expect).length, c.id).toBeGreaterThan(0);
      expect(c.timeoutMs, c.id).toBeGreaterThan(0);
    }
  });

  it("uses only declared expectation keys", () => {
    const declared = new Set(Object.keys(fixture.$expectKeys));
    for (const c of fixture.cases) {
      for (const key of Object.keys(c.expect)) {
        expect(declared.has(key), `${c.id}: ${key}`).toBe(true);
      }
    }
  });

  it("carries a package that validates", () => {
    expect(getModelPackageValidationIssues(fixture.package)).toEqual([]);
  });
});
