import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import {
  getExecutionProvenanceValidationIssues,
  getIndeRunErrorValidationIssues,
  getStreamEventValidationIssues,
  getStreamRunHandleValidationIssues,
  getStreamTerminalOutcomeValidationIssues,
  getTaskRequestValidationIssues,
  getTaskResultValidationIssues,
  type ValidationIssue
} from "./index.js";

// ADR 025 section 5: every run-scoped document accepts exactly one schema version.
type Fixture = {
  accepted: string[];
  rejected: string[];
  rejectMissing: boolean;
  documents: Array<{ document: string; payload: Record<string, unknown> }>;
};

const fixture = JSON.parse(
  readFileSync(
    fileURLToPath(
      new URL("../../../contracts/fixtures/versioning/schema-versions.json", import.meta.url)
    ),
    "utf8"
  )
) as Fixture;

const validators: Record<string, (value: unknown) => ValidationIssue[]> = {
  TaskRequest: getTaskRequestValidationIssues,
  TaskResult: getTaskResultValidationIssues,
  IndeRunError: getIndeRunErrorValidationIssues,
  StreamRunHandle: getStreamRunHandleValidationIssues,
  StreamTerminalOutcome: getStreamTerminalOutcomeValidationIssues,
  StreamEvent: getStreamEventValidationIssues,
  ExecutionProvenance: getExecutionProvenanceValidationIssues
};

/** The payload with its version (and a nested terminal payload's version) replaced or removed. */
function withVersion(payload: Record<string, unknown>, version: string | undefined): unknown {
  const replace = (value: Record<string, unknown>): Record<string, unknown> => {
    const { schemaVersion: _previous, ...rest } = value;
    return version === undefined ? rest : { ...rest, schemaVersion: version };
  };
  const next = replace(payload);
  const nested = next.payload;
  if (typeof nested === "object" && nested !== null && "schemaVersion" in nested) {
    next.payload = replace(nested as Record<string, unknown>);
  }
  return next;
}

describe("schema version fixture", () => {
  it("covers every run-scoped document", () => {
    expect(fixture.documents.map(({ document }) => document).sort()).toEqual(
      Object.keys(validators).sort()
    );
  });

  for (const { document, payload } of fixture.documents) {
    const validate = validators[document]!;
    for (const version of fixture.accepted) {
      it(`${document} accepts "${version}"`, () => {
        expect(validate(withVersion(payload, version))).toEqual([]);
      });
    }
    for (const version of fixture.rejected) {
      it(`${document} rejects "${version}"`, () => {
        expect(validate(withVersion(payload, version))).not.toEqual([]);
      });
    }
    if (fixture.rejectMissing) {
      it(`${document} rejects a missing version`, () => {
        expect(validate(withVersion(payload, undefined))).not.toEqual([]);
      });
    }
  }
});
