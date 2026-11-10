import { readFile } from "node:fs/promises";
import { normalizeSpeechText } from "@independo/inderun-route-core-wasm";
import { describe, expect, it } from "vitest";

interface SpeechTextFrontendCase {
  id: string;
  locale: string;
  input: string;
  expected: string;
}

// Each fixture with its case count, which guards against a fixture that silently lost cases.
const FIXTURES: [name: string, expectedCaseCount: number][] = [
  ["german-frontend.json", 83],
  ["english-frontend.json", 37]
];

const fixtures = await Promise.all(
  FIXTURES.map(async ([name, expectedCaseCount]) => {
    const url = new URL(`../../../../../contracts/fixtures/speech/${name}`, import.meta.url);
    const fixture = JSON.parse(await readFile(url, "utf8")) as { cases: SpeechTextFrontendCase[] };
    return { name, expectedCaseCount, cases: fixture.cases };
  })
);

// The Web runner of contracts/fixtures/speech/german-frontend.json and english-frontend.json: every
// case goes through the real WASM build of the shared Rust text frontend.
describe("Speech text frontend conformance (WASM)", () => {
  for (const { name, expectedCaseCount, cases } of fixtures) {
    describe(name, () => {
      it("runs every fixture case", () => {
        expect(cases.length).toBe(expectedCaseCount);
        expect(new Set(cases.map((c) => c.id)).size).toBe(cases.length);
      });

      for (const { id, locale, input, expected } of cases) {
        it(id, async () => {
          expect(await normalizeSpeechText(input, locale)).toBe(expected);
        });
      }
    });
  }
});
