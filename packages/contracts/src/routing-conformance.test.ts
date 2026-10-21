import { readFileSync } from "node:fs";

import { describe, expect, it } from "vitest";

import { getRoutePlannerInputValidationIssues, getRoutePlanValidationIssues } from "./index.js";

// The shared planner vectors are run through the planner by every SDK; here they are held
// to the schemas, so a vector cannot drift into a shape no SDK would produce.
const fixture = JSON.parse(
  readFileSync(
    new URL("../../../contracts/fixtures/routing/planner-conformance.json", import.meta.url),
    "utf8"
  )
) as { cases: Array<{ id: string; input: unknown; expected: unknown }> };

describe("route-planner conformance vectors", () => {
  it("are not empty", () => {
    expect(fixture.cases.length).toBeGreaterThan(0);
  });

  for (const { id, input, expected } of fixture.cases) {
    it(`${id}: input and plan validate`, () => {
      expect(getRoutePlannerInputValidationIssues(input)).toEqual([]);
      expect(getRoutePlanValidationIssues(expected)).toEqual([]);
    });
  }
});
