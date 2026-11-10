import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import { GraphemeTokenizer, splitSentences } from "./frontend.js";

interface FrontendCase {
  id: string;
  text: string;
  sentences: string[];
  tokens: number[][];
}

const fixture = JSON.parse(
  readFileSync(
    join(
      dirname(fileURLToPath(import.meta.url)),
      "../../../../../contracts/fixtures/speech/neural-frontend.json"
    ),
    "utf8"
  )
) as { vocab: Record<string, number>; cases: FrontendCase[] };

describe("neural speech text frontend fixture", () => {
  it("has unique, non-empty case ids", () => {
    const ids = fixture.cases.map((c) => c.id);
    expect(ids.length).toBeGreaterThan(0);
    expect(ids.every((id) => id.length > 0)).toBe(true);
    expect(new Set(ids).size).toBe(ids.length);
  });

  const tokenizer = new GraphemeTokenizer(fixture.vocab);
  for (const c of fixture.cases) {
    it(`splits and tokenizes: ${c.id}`, () => {
      const sentences = splitSentences(c.text);
      expect(sentences).toEqual(c.sentences);
      expect(sentences.map((s) => tokenizer.encode(s))).toEqual(c.tokens);
    });
  }
});

describe("splitSentences", () => {
  // A long run of terminators not followed by whitespace made the old boundary regex
  // backtrack quadratically (CodeQL js/polynomial-redos).
  it("scans a long terminator run in linear time", () => {
    const run = "!".repeat(100_000);
    expect(splitSentences(`a${run}x`)).toEqual([`a${run}x`]);
    expect(splitSentences(`a${run} b`)).toEqual([`a${run}`, "b"]);
  });
});
