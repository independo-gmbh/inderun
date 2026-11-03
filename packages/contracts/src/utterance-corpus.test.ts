import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import { getTaskRequestValidationIssues } from "./index.js";

// The shared real-audio corpus (#251). The Swift and Kotlin real-audio suites read it from this
// path; this test keeps it well-formed, so a broken entry fails here rather than as a skipped
// device run.
const corpusPath = fileURLToPath(
  new URL("../../../contracts/fixtures/speech/utterance-corpus.json", import.meta.url)
);

type Utterance = {
  id: string;
  locale: string;
  category: string;
  text: string;
  expect: "speak" | "refuse";
  errorClass?: string;
};

type BenchmarkScenario = {
  id: string;
  delivery: "playback" | "artifact";
  question: string;
  setup: string;
  utteranceIds: string[];
  trials: number;
  cancelAfterMs?: number;
};

type Corpus = {
  utterances: Utterance[];
  benchmark: { scenarios: BenchmarkScenario[] };
  scenarios: {
    repeat: { utteranceIds: string[]; count: number };
    cancelMidUtterance: { utteranceId: string; cancelAfterMs: number; followUpUtteranceId: string };
  };
};

const corpus = JSON.parse(readFileSync(corpusPath, "utf8")) as Corpus;
const ids = new Set(corpus.utterances.map((utterance) => utterance.id));

describe("utterance corpus", () => {
  it("has unique ids", () => {
    expect(ids.size).toBe(corpus.utterances.length);
  });

  it("covers the locales and categories #251 asks for", () => {
    const locales = new Set(corpus.utterances.map((utterance) => utterance.locale));
    for (const locale of ["de-AT", "de-DE", "en-US"]) expect(locales).toContain(locale);
    const categories = new Set(corpus.utterances.map((utterance) => utterance.category));
    for (const category of [
      "short",
      "punctuation",
      "numerals",
      "dates_times_currency",
      "long",
      "unsupported_locale"
    ]) {
      expect(categories).toContain(category);
    }
  });

  it("gives every refusal an error class", () => {
    for (const utterance of corpus.utterances.filter((entry) => entry.expect === "refuse")) {
      expect(utterance.errorClass, utterance.id).toBeDefined();
    }
  });

  it.each(corpus.utterances.map((utterance) => [utterance.id, utterance] as const))(
    "%s is a valid speech request for both deliveries",
    (_id, utterance) => {
      for (const mode of ["playback", "artifact"] as const) {
        const request = {
          schemaVersion: "1.0",
          task: { kind: "text_to_speech" },
          speech: { text: utterance.text, locale: utterance.locale },
          delivery: { mode }
        };
        expect(getTaskRequestValidationIssues(request)).toEqual([]);
      }
    }
  );

  it("names only utterances it has in its scenarios", () => {
    const { repeat, cancelMidUtterance } = corpus.scenarios;
    for (const id of [
      ...repeat.utteranceIds,
      cancelMidUtterance.utteranceId,
      cancelMidUtterance.followUpUtteranceId
    ]) {
      expect(ids, id).toContain(id);
    }
    expect(repeat.count).toBeGreaterThan(1);
  });

  it("gives every benchmark scenario a question, known utterances and trials", () => {
    const scenarioIds = corpus.benchmark.scenarios.map((scenario) => scenario.id);
    expect(new Set(scenarioIds).size).toBe(scenarioIds.length);
    for (const scenario of corpus.benchmark.scenarios) {
      expect(["playback", "artifact"], scenario.id).toContain(scenario.delivery);
      expect(scenario.question.length, scenario.id).toBeGreaterThan(0);
      expect(scenario.trials, scenario.id).toBeGreaterThan(0);
      expect(scenario.utteranceIds.length, scenario.id).toBeGreaterThan(0);
      for (const id of scenario.utteranceIds) expect(ids, `${scenario.id}: ${id}`).toContain(id);
      // A benchmark measures speech that plays, so it never uses an utterance that must be refused.
      for (const id of scenario.utteranceIds) {
        expect(corpus.utterances.find((entry) => entry.id === id)?.expect, id).toBe("speak");
      }
    }
  });
});
