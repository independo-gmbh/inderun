import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import {
  getMediaArtifactValidationIssues,
  getStreamEventValidationIssues,
  getStreamTerminalOutcomeValidationIssues,
  getTaskOutputValidationIssues,
  getTaskRequestValidationIssues,
  getTaskResultValidationIssues
} from "./index.js";

// The ADR 016 examples (docs/architecture/decisions/016-modality-extensible-task-contracts.md).
// A 'current' file must validate against the committed schemas. A 'proposed' or
// 'contract_only' file must be rejected at /task/kind — that is how a consumer built against
// today's schemas treats a task it does not know, and it keeps the examples from silently
// becoming valid before the schema change that is meant to admit them.
const fixturesDir = fileURLToPath(
  new URL("../../../contracts/fixtures/task-contracts/", import.meta.url)
);

type FixtureCase = {
  id: string;
  request: unknown;
  result?: unknown;
  terminal?: unknown;
  planner: { kind: string };
};

type FixtureFile = {
  task: string;
  status: "current" | "proposed" | "contract_only";
  cases: FixtureCase[];
  /** Requests the schema's per-kind rules reject; every SDK must reject them too. */
  invalidRequests?: Array<{ id: string; request: unknown }>;
};

const fixtureFiles = readdirSync(fixturesDir)
  .filter((name) => name.endsWith(".json"))
  .map((name) => ({
    name,
    fixture: JSON.parse(readFileSync(join(fixturesDir, name), "utf8")) as FixtureFile
  }));

describe("task-contract fixtures", () => {
  it("cover the three ADR 016 examples", () => {
    expect(fixtureFiles.map(({ fixture }) => fixture.task).sort()).toEqual([
      "image_to_text",
      "text_to_speech",
      "text_to_text"
    ]);
  });

  for (const { name, fixture } of fixtureFiles) {
    describe(name, () => {
      for (const fixtureCase of fixture.cases) {
        it(`${fixtureCase.id}: request and planner projection name the file's task`, () => {
          expect(fixtureCase.request).toMatchObject({ task: { kind: fixture.task } });
          expect(fixtureCase.planner.kind).toBe(fixture.task);
        });

        if (fixture.status === "current") {
          it(`${fixtureCase.id}: validates against the committed schemas`, () => {
            expect(getTaskRequestValidationIssues(fixtureCase.request)).toEqual([]);
            if (fixtureCase.result !== undefined) {
              expect(getTaskResultValidationIssues(fixtureCase.result)).toEqual([]);
            }
            if (fixtureCase.terminal !== undefined) {
              expect(getStreamTerminalOutcomeValidationIssues(fixtureCase.terminal)).toEqual([]);
              // The terminal StreamEvent embeds its own copy of the outcome.
              expect(
                getStreamEventValidationIssues({
                  schemaVersion: "1.0",
                  runId: "run_fixture",
                  sequence: 0,
                  timestamp: 0,
                  type: "terminal",
                  payload: fixtureCase.terminal
                })
              ).toEqual([]);
            }
          });
        } else {
          it(`${fixtureCase.id}: is rejected at /task/kind until its schema change lands`, () => {
            const issues = getTaskRequestValidationIssues(fixtureCase.request);
            expect(issues.map((issue) => issue.path)).toContain("/task/kind");
          });
        }
      }

      for (const invalid of fixture.invalidRequests ?? []) {
        it(`${invalid.id}: is rejected by the schema`, () => {
          expect(getTaskRequestValidationIssues(invalid.request)).not.toEqual([]);
        });
      }
    });
  }
});

// Shared MediaArtifact vectors (ADR 017), including the hypothetical image artifact.
const artifactFixtures = JSON.parse(
  readFileSync(
    fileURLToPath(
      new URL("../../../contracts/fixtures/artifacts/media-artifacts.json", import.meta.url)
    ),
    "utf8"
  )
) as {
  valid: Array<{ id: string; artifact: unknown }>;
  invalid: Array<{ id: string; artifact: unknown }>;
};

describe("media artifact fixtures", () => {
  for (const { id, artifact } of artifactFixtures.valid) {
    it(`${id}: validates as a reference and as an artifact output`, () => {
      expect(getMediaArtifactValidationIssues(artifact)).toEqual([]);
      expect(getTaskOutputValidationIssues({ type: "artifact", artifact })).toEqual([]);
    });
  }

  for (const { id, artifact } of artifactFixtures.invalid) {
    it(`${id}: is rejected`, () => {
      expect(getMediaArtifactValidationIssues(artifact)).not.toEqual([]);
      expect(getTaskOutputValidationIssues({ type: "artifact", artifact })).not.toEqual([]);
    });
  }
});
