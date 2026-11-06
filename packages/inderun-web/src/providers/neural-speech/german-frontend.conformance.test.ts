import { readFile } from "node:fs/promises";
import { normalizeSpeechText } from "@independo/inderun-route-core-wasm";
import { describe, expect, it } from "vitest";

interface GermanFrontendCase {
  id: string;
  locale: string;
  input: string;
  expected: string;
}

const FIXTURE_URL = new URL(
  "../../../../../contracts/fixtures/speech/german-frontend.json",
  import.meta.url
);
const fixture = JSON.parse(await readFile(FIXTURE_URL, "utf8")) as { cases: GermanFrontendCase[] };

// The Web runner of contracts/fixtures/speech/german-frontend.json: every case goes through the
// real WASM build of the shared Rust text frontend.
describe("German speech text frontend conformance (WASM)", () => {
  it("runs every fixture case", () => {
    expect(fixture.cases.length).toBeGreaterThan(0);
    expect(new Set(fixture.cases.map((c) => c.id)).size).toBe(fixture.cases.length);
  });

  for (const { id, locale, input, expected } of fixture.cases) {
    it(id, async () => {
      expect(await normalizeSpeechText(input, locale)).toBe(expected);
    });
  }
});
