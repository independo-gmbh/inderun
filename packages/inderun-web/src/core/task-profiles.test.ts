import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import type { TaskRequest, TaskResult } from "@independo/inderun-contracts";
import { describe, expect, it } from "vitest";

import { IndeRun } from "./engine.js";
import { IndeRunException } from "./errors.js";
import type { HostServices } from "./host.js";
import type { ProviderAdapter, ProviderDescriptor, RunContext } from "./provider.js";
import { ProviderRegistry } from "./registry.js";
import { buildSharedPlannerInput, type RoutePlanner } from "./route-planner.js";
import { Router } from "./router.js";
import { recheckBoundVoice } from "./task-profiles.js";

/**
 * The task-profile table (#245): every SDK projects a request onto the same planner task,
 * hands each attempt the voice the plan bound, and re-checks that voice against the
 * privacy policy immediately before the attempt.
 */

const fixturesDir = fileURLToPath(
  new URL("../../../../contracts/fixtures/task-contracts/", import.meta.url)
);

type FixtureFile = {
  task: string;
  status: "current" | "proposed" | "contract_only";
  cases: Array<{ id: string; request: TaskRequest; planner: unknown }>;
};

const currentFixtures = readdirSync(fixturesDir)
  .filter((name) => name.endsWith(".json"))
  .map((name) => JSON.parse(readFileSync(join(fixturesDir, name), "utf8")) as FixtureFile)
  .filter((fixture) => fixture.status === "current");

const host: HostServices = {
  connectivity: {
    async isOnline() {
      return true;
    }
  },
  clock: {
    now() {
      return 0;
    }
  }
};

const supports: ProviderDescriptor["supports"] = {
  run: true,
  streaming: false,
  realtime: false,
  tools: false,
  reasoningEvents: false,
  structuredOutput: false,
  multimodal: false
};

const speechRequest: TaskRequest = {
  schemaVersion: "1.0",
  task: { kind: "text_to_speech" },
  speech: { text: "Hallo", locale: "de-AT", voice: { gender: "female" } },
  delivery: { mode: "playback" },
  constraints: { privacy: "local_required" }
};

function speechProvider(
  id: string,
  voices: Array<{ locale: string; gender?: "female" | "male"; networkRequired?: boolean }>,
  contexts: RunContext[]
): ProviderAdapter {
  return {
    describe: () => ({
      id,
      type: "local",
      transport: "system_service",
      supports,
      cancel: "hard",
      tasks: ["text_to_speech"],
      taskCapabilities: [
        {
          kind: "text_to_speech",
          inputs: ["text"],
          interaction: { run: true, stream: false },
          cancel: "hard",
          outputs: [{ delivery: "playback" }],
          locales: ["de-AT", "de-DE"]
        }
      ],
      privacy: { dataLeavesDevice: false }
    }),
    capabilities: async () => ({
      available: true,
      taskCapabilities: [{ kind: "text_to_speech", voices }]
    }),
    run: async (request, context): Promise<TaskResult> => {
      contexts.push(context);
      return {
        schemaVersion: "1.0",
        runId: request.requestId ?? context.runId,
        output: { type: "playback", playback: {} },
        finishReason: "stop",
        telemetry: { providerUsed: id, totalMs: 0 }
      };
    }
  };
}

describe("task profiles", () => {
  for (const fixture of currentFixtures) {
    for (const fixtureCase of fixture.cases) {
      it(`${fixture.task}/${fixtureCase.id}: projects onto the fixture's planner task`, () => {
        expect(buildSharedPlannerInput(fixtureCase.request, [], true).task).toEqual(
          fixtureCase.planner
        );
      });
    }
  }

  it("hands each attempt the voice the plan bound for its provider", async () => {
    const contexts: RunContext[] = [];
    const registry = new ProviderRegistry();
    registry.register(
      speechProvider(
        "local_speech",
        [
          { locale: "de-DE", gender: "male" },
          { locale: "de-AT", gender: "female" }
        ],
        contexts
      )
    );

    await new IndeRun(registry, host).run(speechRequest);

    expect(contexts.map((context) => context.voice)).toEqual([
      { locale: "de-AT", gender: "female" }
    ]);
  });

  it("refuses a network voice under local_required before the attempt and falls back", async () => {
    const contexts: RunContext[] = [];
    const registry = new ProviderRegistry();
    registry.register(
      speechProvider("a_bound_to_network", [{ locale: "de-AT", networkRequired: true }], contexts)
    );
    registry.register(speechProvider("b_local", [{ locale: "de-AT" }], contexts));
    const engine = new IndeRun(registry, host);

    // The shared planner never binds a network voice under local_required, so a plan
    // that does is injected to exercise the engine's own pre-attempt check.
    const planner: RoutePlanner = {
      async planRoute(input) {
        return {
          routePlan: {
            selectedProviderId: "a_bound_to_network",
            candidates: input.providers.map((provider) => ({
              providerId: provider.descriptor.id,
              voice: provider.capabilities.taskCapabilities![0]!.voices![0]!
            })),
            rejectedProviders: [],
            explanation: { summary: "injected" }
          }
        } as Awaited<ReturnType<RoutePlanner["planRoute"]>>;
      }
    };
    Reflect.set(engine, "router", new Router(registry, planner));

    const result = await engine.run(speechRequest);

    expect(contexts.map((context) => context.voice)).toEqual([{ locale: "de-AT" }]);
    expect(result.provenance?.attempts).toEqual([
      { providerId: "a_bound_to_network", outcome: "failed", errorClass: "CapabilityMismatch" },
      { providerId: "b_local", outcome: "succeeded" }
    ]);
  });

  it("allows a network voice when the request does not require local execution", () => {
    const voice = { locale: "de-AT", networkRequired: true };
    expect(recheckBoundVoice(speechRequest, "p", voice)).toBeInstanceOf(IndeRunException);
    expect(
      recheckBoundVoice(
        { ...speechRequest, constraints: { privacy: "local_preferred" } },
        "p",
        voice
      )
    ).toBeUndefined();
    expect(recheckBoundVoice(speechRequest, "p", voice)?.details).toMatchObject({
      code: "privacy_recheck_failed"
    });
  });
});
