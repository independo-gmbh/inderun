import type { TaskRequest, TaskResult } from "@independo/inderun-contracts";
import { describe, expect, it, vi } from "vitest";

import { IndeRun } from "./engine.js";
import type { ProviderAdapter, ProviderStreamContext, RunContext } from "./provider.js";
import { ProviderRegistry } from "./registry.js";
import { registerTaskProfile } from "./task-profiles.js";
import { createMockHostServices, drain } from "../test/stream-fakes.js";

/**
 * A third task through the unchanged engine (#245): a fake `text_to_image` task with a PNG
 * artifact. The 1.0 schemas do not admit the kind -- adding a task means adding its schema
 * branch (ADR 016) -- so the schema check is widened for this one kind; routing, the commit
 * rule, output normalization and the artifact store are the production code paths.
 */

vi.mock("@independo/inderun-contracts", async (importOriginal) => {
  const contracts = await importOriginal<typeof import("@independo/inderun-contracts")>();
  return {
    ...contracts,
    getTaskRequestValidationIssues: (request: TaskRequest) =>
      (request.task.kind as string) === "text_to_image"
        ? []
        : contracts.getTaskRequestValidationIssues(request)
  };
});

type ImageRequest = TaskRequest & { image: { prompt: string } };

registerTaskProfile({
  kind: "text_to_image",
  plannerTask: (request) => ({
    kind: "text_to_image",
    inputs: ["text"],
    delivery: { mode: "artifact", mediaTypes: [...request.delivery!.mediaTypes!] }
  }),
  delivery: () => "artifact"
});

const request = {
  schemaVersion: "1.0",
  task: { kind: "text_to_image" },
  image: { prompt: "A lift that is out of order" },
  delivery: { mode: "artifact", mediaTypes: ["image/png"] }
} as unknown as ImageRequest;

const PNG_SIGNATURE = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

function paint(context: RunContext) {
  const writer = context.artifacts.create({ mediaType: "image/png" });
  writer.write(PNG_SIGNATURE);
  return writer.finish();
}

const imageProvider: ProviderAdapter = {
  describe: () => ({
    id: "fake_image",
    type: "local",
    transport: "in_process",
    supports: {
      run: true,
      streaming: true,
      realtime: false,
      tools: false,
      reasoningEvents: false,
      structuredOutput: false,
      multimodal: false
    },
    cancel: "soft",
    tasks: ["text_to_image"],
    taskCapabilities: [
      {
        kind: "text_to_image",
        inputs: ["text"],
        interaction: { run: true, stream: true },
        cancel: "soft",
        outputs: [{ delivery: "artifact", mediaTypes: ["image/png"] }]
      }
    ]
  }),
  capabilities: async () => ({ available: true }),
  run: async (_request, context): Promise<TaskResult> => ({
    schemaVersion: "1.0",
    runId: context.runId,
    output: { type: "artifact", artifact: paint(context) },
    finishReason: "stop",
    telemetry: { providerUsed: "fake_image", totalMs: 0 }
  }),
  async *stream(_request, context: ProviderStreamContext) {
    yield {
      kind: "result" as const,
      output: { type: "artifact" as const, artifact: paint(context) }
    };
  }
};

function engine(): IndeRun {
  const registry = new ProviderRegistry();
  registry.register(imageProvider);
  return new IndeRun(registry, createMockHostServices());
}

describe("a third task through the unchanged engine", () => {
  it("runs an image artifact task and serves its bytes", async () => {
    const inderun = engine();
    const result = await inderun.run(request);

    expect(result.output.artifact).toMatchObject({
      mediaType: "image/png",
      owner: "engine",
      byteLength: PNG_SIGNATURE.byteLength
    });
    expect(result.provenance?.attempts).toEqual([
      { providerId: "fake_image", outcome: "succeeded", committed: true }
    ]);
    const chunk = await inderun.readArtifact({ artifactId: result.output.artifact!.id });
    expect(chunk.bytes).toEqual(PNG_SIGNATURE);
  });

  it("streams the same task to a terminal carrying the artifact", async () => {
    const events = await drain((await engine().stream(request)).events);

    expect(events.map((event) => event.type)).toEqual(["terminal"]);
    expect(events[0]!.payload).toMatchObject({
      outcome: "completed",
      output: { type: "artifact", artifact: { mediaType: "image/png" } }
    });
  });
});
