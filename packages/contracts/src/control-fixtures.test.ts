import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import {
  getRoutePlanValidationIssues,
  getTaskOutputValidationIssues,
  getTaskRequestValidationIssues
} from "./index.js";

// The ADR 025 scenario catalogs for the engine's control checks. Each SDK runs them through its
// own handlers (Stage 2 of #311); this keeps every payload in them valid against the schemas, so
// a handler never tests a shape the contract does not admit.
type Catalog = {
  cases: Array<Record<string, unknown> & { id: string }>;
  $scriptSteps?: Record<string, string>;
};

function load(name: string): Catalog {
  return JSON.parse(
    readFileSync(
      fileURLToPath(new URL(`../../../contracts/fixtures/execution/${name}`, import.meta.url)),
      "utf8"
    )
  ) as Catalog;
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

describe("control-execution fixture", () => {
  const catalog = load("control-execution.json");
  const steps = Object.keys(catalog.$scriptSteps ?? {});

  for (const entry of catalog.cases) {
    it(`${entry.id}: request, scripts, plans and outputs are valid contract shapes`, () => {
      expect(getTaskRequestValidationIssues(entry.request)).toEqual([]);
      const modes = entry.modes as string[];
      expect(modes.length).toBeGreaterThan(0);
      for (const mode of modes) expect(["run", "stream"]).toContain(mode);
      const providers = entry.providers as Array<{ id: string; script: string[] }>;
      for (const provider of providers) {
        for (const step of provider.script) expect(steps).toContain(step);
      }
      const expected = entry.expect as {
        receivedControls?: Record<string, unknown>;
        output?: unknown;
      };
      for (const [providerId, controls] of Object.entries(expected.receivedControls ?? {})) {
        expect(providers.map((provider) => provider.id)).toContain(providerId);
        expect(getRoutePlanValidationIssues(planWith(controls))).toEqual([]);
      }
      if (expected.output !== undefined) {
        expect(getTaskOutputValidationIssues(expected.output)).toEqual([]);
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
