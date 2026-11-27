import { readFileSync } from "node:fs";

import { describe, expect, it } from "vitest";

import { getRoutePlannerInputValidationIssues, getRoutePlanValidationIssues } from "./index.js";

// The shared planner vectors are run through the planner by every SDK; here they are held
// to the schemas, so a vector cannot drift into a shape no SDK would produce. A case marked
// `schemaInvalid` feeds the planner an input that typed SDK values can carry through serde but
// the schema refuses (a contradictory control declaration): its input must fail validation, and
// only in its control metadata, so the mark cannot hide drift in a case that is meant to be valid.
const fixture = JSON.parse(
  readFileSync(
    new URL("../../../contracts/fixtures/routing/planner-conformance.json", import.meta.url),
    "utf8"
  )
) as { cases: Array<{ id: string; schemaInvalid?: boolean; input: unknown; expected: unknown }> };

describe("route-planner conformance vectors", () => {
  it("are not empty", () => {
    expect(fixture.cases.length).toBeGreaterThan(0);
  });

  for (const { id, schemaInvalid, input, expected } of fixture.cases) {
    it(`${id}: input and plan validate`, () => {
      if (schemaInvalid === true) {
        const issues = getRoutePlannerInputValidationIssues(input);
        expect(issues).not.toEqual([]);
        // Only a provider's control metadata may be invalid; the rest is held to the schema.
        for (const issue of issues) {
          expect(issue.path).toMatch(/\/taskCapabilities\/\d+\/(controls|controlStates)(\/|$)/);
        }
      } else {
        expect(getRoutePlannerInputValidationIssues(input)).toEqual([]);
      }
      expect(getRoutePlanValidationIssues(expected)).toEqual([]);
    });
  }
});
