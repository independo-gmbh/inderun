import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { localityOf } from "./provenance.js";
import type { ProviderDescriptor } from "./provider.js";
import type { BoundVoice } from "./task-profiles.js";

const fixture = JSON.parse(
  readFileSync(
    join(
      dirname(fileURLToPath(import.meta.url)),
      "../../../../contracts/fixtures/execution/voice-locality.json"
    ),
    "utf8"
  )
) as {
  cases: {
    id: string;
    providerType: ProviderDescriptor["type"];
    taskDataLeavesDevice?: boolean;
    voice?: BoundVoice;
    unverifiedVoice?: boolean;
    expected: string;
  }[];
};

describe("localityOf (shared voice vectors)", () => {
  for (const vector of fixture.cases) {
    it(vector.id, () => {
      const descriptor = {
        id: "p",
        type: vector.providerType,
        taskCapabilities: [
          {
            kind: "text_to_speech",
            ...(vector.taskDataLeavesDevice !== undefined
              ? { privacy: { dataLeavesDevice: vector.taskDataLeavesDevice } }
              : {})
          }
        ]
      } as unknown as ProviderDescriptor;
      const bound =
        vector.voice !== undefined
          ? { taskKind: "text_to_speech", voice: vector.voice }
          : vector.unverifiedVoice === true
            ? { taskKind: "text_to_speech" }
            : undefined;

      expect(localityOf(descriptor, bound)).toBe(vector.expected);
    });
  }
});
