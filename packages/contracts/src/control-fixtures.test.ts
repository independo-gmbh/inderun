import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import {
  getRoutePlanValidationIssues,
  getTaskOutputValidationIssues,
  getTaskRequestValidationIssues
} from "./index.js";

// The ADR 025 scenario catalogs for the engine's control checks. The SDK handlers land with
// Stage 2 of #311; until then this keeps every payload in them valid against the schemas, so a
// handler never tests a shape the contract does not admit.
function load(name: string): { cases: Array<Record<string, unknown> & { id: string }> } {
  return JSON.parse(
    readFileSync(
      fileURLToPath(new URL(`../../../contracts/fixtures/execution/${name}`, import.meta.url)),
      "utf8"
    )
  ) as { cases: Array<Record<string, unknown> & { id: string }> };
}

/** A one-candidate plan around the given controls, absent when they are null. */
function planWith(controls: unknown): unknown {
  return {
    selectedProviderId: "tts",
    fallbackProviderIds: [],
    candidates: [{ providerId: "tts", order: 0, ...(controls === null ? {} : { controls }) }],
    rejectedProviders: [],
    explanation: { summary: "fixture" }
  };
}

describe("control-plan-integrity fixture", () => {
  for (const entry of load("control-plan-integrity.json").cases) {
    it(`${entry.id}: request and plans are valid contract shapes`, () => {
      expect(getTaskRequestValidationIssues(entry.request)).toEqual([]);
      expect(getRoutePlanValidationIssues(planWith(entry.candidateControls))).toEqual([]);
      if ("fallbackCandidateControls" in entry) {
        expect(getRoutePlanValidationIssues(planWith(entry.fallbackCandidateControls))).toEqual([]);
      }
    });
  }
});

describe("control-outcomes fixture", () => {
  for (const entry of load("control-outcomes.json").cases) {
    it(`${entry.id}: request and expected records are valid contract shapes`, () => {
      expect(getTaskRequestValidationIssues(entry.request)).toEqual([]);
      const expected = entry.expected as { failed: boolean; controls?: unknown[] };
      if (!expected.failed) {
        expect(
          getTaskOutputValidationIssues({
            type: "playback",
            playback: {},
            speech: { locale: "de-AT", controls: expected.controls }
          })
        ).toEqual([]);
      }
    });
  }
});
