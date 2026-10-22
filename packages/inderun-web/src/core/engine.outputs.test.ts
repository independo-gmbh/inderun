import type { TaskOutput, TaskRequest, TaskResult } from "@independo/inderun-contracts";
import { describe, expect, it } from "vitest";

import { IndeRun } from "./engine.js";
import { createUnavailable, IndeRunException } from "./errors.js";
import type { ProviderAdapter, RunContext } from "./provider.js";
import { ProviderRegistry } from "./registry.js";
import { createMockHostServices, createSpeechRequest } from "../test/stream-fakes.js";

/**
 * Mode 1 (`run()`) half of the explicit commit rule (#245). The stream half is in the shared
 * conformance catalog. A text run never commits, so its fallback is exactly as before; a
 * playback run that committed owns its failure.
 */

type Behaviour = (context: RunContext) => Promise<TaskOutput>;

function speechProvider(id: string, behaviour: Behaviour, calls: string[]): ProviderAdapter {
  return {
    describe: () => ({
      id,
      type: "local",
      transport: "system_service",
      supports: {
        run: true,
        streaming: false,
        realtime: false,
        tools: false,
        reasoningEvents: false,
        structuredOutput: false,
        multimodal: false
      },
      cancel: "hard",
      tasks: ["text_to_speech"],
      taskCapabilities: [
        {
          kind: "text_to_speech",
          inputs: ["text"],
          interaction: { run: true, stream: false },
          cancel: "hard",
          outputs: [{ delivery: "playback" }],
          locales: ["de-AT"]
        }
      ]
    }),
    capabilities: async () => ({ available: true }),
    run: async (request: TaskRequest, context: RunContext): Promise<TaskResult> => {
      calls.push(id);
      return {
        schemaVersion: "1.0",
        runId: context.runId,
        output: await behaviour(context),
        finishReason: "stop",
        telemetry: { providerUsed: id, totalMs: 0 }
      };
    }
  };
}

const played: Behaviour = async (context) => {
  context.commit();
  return { type: "playback", playback: { durationMs: 900 } };
};

async function runWith(providers: Array<[string, Behaviour]>, request = createSpeechRequest()) {
  const calls: string[] = [];
  const registry = new ProviderRegistry();
  for (const [id, behaviour] of providers) registry.register(speechProvider(id, behaviour, calls));
  const engine = new IndeRun(registry, createMockHostServices());
  const outcome = await engine.run(request).then(
    (result) => ({ result }),
    (error: unknown) => ({ error: error as IndeRunException })
  );
  return { ...outcome, calls };
}

describe("run() commit rule", () => {
  it("returns a committed playback result with its provenance", async () => {
    const { result } = await runWith([["p1", played]]);

    expect(result?.output).toEqual({ type: "playback", playback: { durationMs: 900 } });
    expect(result?.provenance?.attempts).toEqual([
      { providerId: "p1", outcome: "succeeded", committed: true }
    ]);
  });

  it("falls back when playback fails before commit", async () => {
    const { result, calls } = await runWith([
      [
        "p1",
        async () => {
          throw createUnavailable("no audio session");
        }
      ],
      ["p2", played]
    ]);

    expect(calls).toEqual(["p1", "p2"]);
    expect(result?.provenance?.attempts).toEqual([
      { providerId: "p1", outcome: "failed", errorClass: "Unavailable" },
      { providerId: "p2", outcome: "succeeded", committed: true }
    ]);
  });

  it("never falls back once playback committed, and attributes the failure", async () => {
    const { error, calls } = await runWith([
      [
        "p1",
        async (context) => {
          context.commit();
          throw createUnavailable("audio device lost");
        }
      ],
      ["p2", played]
    ]);

    expect(calls).toEqual(["p1"]);
    expect(error).toBeInstanceOf(IndeRunException);
    expect(error?.errorClass).toBe("Unavailable");
    expect(error?.provenance).toMatchObject({
      providerId: "p1",
      attempts: [{ providerId: "p1", outcome: "failed", committed: true }]
    });
  });

  it("refuses a commit from an attempt the run has already left", async () => {
    let keptCommit: (() => boolean) | undefined;
    let lateCommit: boolean | undefined;
    const { result, calls } = await runWith([
      [
        "p1",
        async (context) => {
          keptCommit = context.commit;
          throw createUnavailable("no audio session");
        }
      ],
      [
        "p2",
        async (context) => {
          // p1's callback fires while p2 runs: p1 must not start audio now.
          lateCommit = keptCommit!();
          return played(context);
        }
      ]
    ]);

    expect(calls).toEqual(["p1", "p2"]);
    expect(lateCommit).toBe(false);
    expect(result?.provenance?.attempts).toEqual([
      { providerId: "p1", outcome: "failed", errorClass: "Unavailable" },
      { providerId: "p2", outcome: "succeeded", committed: true }
    ]);
  });

  it("treats an output of the wrong kind as a provider fault", async () => {
    const { error } = await runWith([["p1", async () => ({ type: "text", text: "Hallo" })]]);

    expect(error?.errorClass).toBe("Internal");
    expect(error?.details).toMatchObject({ code: "output_mismatch" });
  });

  it("rejects an artifact whose media type the request does not accept", async () => {
    const request = createSpeechRequest({
      delivery: { mode: "artifact", mediaTypes: ["audio/wav"] }
    });
    const artifact = {
      type: "artifact",
      artifact: {
        id: "art_1",
        mediaType: "audio/mpeg",
        owner: "engine",
        lifetime: "until_disposed"
      }
    } as const;
    const calls: string[] = [];
    const registry = new ProviderRegistry();
    const provider = speechProvider("p1", async () => artifact, calls);
    const descriptor = provider.describe();
    provider.describe = () => ({
      ...descriptor,
      taskCapabilities: [
        {
          ...descriptor.taskCapabilities![0]!,
          outputs: [{ delivery: "artifact", mediaTypes: ["audio/wav", "audio/mpeg"] }]
        }
      ]
    });
    registry.register(provider);

    const error = await new IndeRun(registry, createMockHostServices())
      .run(request)
      .catch((caught: unknown) => caught as IndeRunException);

    expect((error as IndeRunException).details).toMatchObject({ code: "output_mismatch" });
  });
});
