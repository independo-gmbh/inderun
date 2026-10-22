import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type {
  ExecutionProvenance,
  StreamEvent,
  StreamTerminalOutcome,
  TaskRequest,
  TaskResult
} from "@independo/inderun-contracts";
import { describe, expect, it } from "vitest";
import {
  generateText,
  IndeRun,
  IndeRunException,
  streamText,
  TextStreamRetractedError,
  toTaskRequest,
  type IndeRunApi,
  type StreamRun,
  type TextGenerationOptions
} from "../index.js";
import { ProviderRegistry, type ProviderAdapter } from "../provider.js";

const fixture = JSON.parse(
  readFileSync(
    join(
      dirname(fileURLToPath(import.meta.url)),
      "../../../../contracts/fixtures/facade/text-generation.json"
    ),
    "utf8"
  )
) as { cases: { id: string; options: TextGenerationOptions; expected: TaskRequest }[] };

describe("toTaskRequest (shared facade vectors)", () => {
  for (const vector of fixture.cases) {
    it(vector.id, () => {
      expect(toTaskRequest(vector.options)).toEqual(vector.expected);
    });
  }
});

const provenance: ExecutionProvenance = {
  schemaVersion: "1.0",
  modelProfile: "auto",
  providerId: "p1",
  locality: "on_device",
  attemptCount: 1,
  fallbackOccurred: false,
  attempts: [{ providerId: "p1", outcome: "succeeded" }],
  routeRejections: []
};

/**
 * An `IndeRunApi` that records the request it was given and answers with a fixed result or a
 * scripted event sequence -- the facade is tested against the interface, not an engine.
 */
function fakeApi(script: { result?: TaskResult; events?: StreamEvent[] }): IndeRunApi & {
  requests: TaskRequest[];
  cancelledWith: (string | undefined)[];
} {
  const requests: TaskRequest[] = [];
  const cancelledWith: (string | undefined)[] = [];
  return {
    requests,
    cancelledWith,
    async run(request) {
      requests.push(request);
      return script.result!;
    },
    async stream(request): Promise<StreamRun> {
      requests.push(request);
      const events = script.events ?? [];
      return {
        handle: { schemaVersion: "1.0", runId: "run_1", startedAt: 0, providerId: "p1" },
        events: (async function* () {
          yield* events;
        })(),
        cancel: (reason?: string) => cancelledWith.push(reason)
      };
    },
    async checkCapabilities() {
      return [];
    }
  };
}

let sequence = 0;
function event(type: string, payload: unknown): StreamEvent {
  return {
    schemaVersion: "1.0",
    runId: "run_1",
    sequence: sequence++,
    timestamp: 0,
    type,
    payload
  } as unknown as StreamEvent;
}

function terminal(outcome: Omit<StreamTerminalOutcome, "schemaVersion" | "runId">): StreamEvent {
  return event("terminal", { schemaVersion: "1.0", runId: "run_1", ...outcome });
}

async function collect<T>(iterable: AsyncIterable<T>): Promise<T[]> {
  const items: T[] = [];
  for await (const item of iterable) items.push(item);
  return items;
}

describe("generateText", () => {
  it("runs the canonical request and summarizes the result", async () => {
    const taskResult: TaskResult = {
      schemaVersion: "1.0",
      runId: "run_1",
      output: { type: "text", text: "Hello" },
      finishReason: "stop",
      usage: { totalTokens: 3 },
      telemetry: { providerUsed: "p1", totalMs: 5 },
      provenance
    };
    const api = fakeApi({ result: taskResult });

    const generated = await generateText(api, { prompt: "Hi", model: "smart" });

    expect(api.requests).toEqual([toTaskRequest({ prompt: "Hi", model: "smart" })]);
    expect(generated).toEqual({
      text: "Hello",
      finishReason: "stop",
      usage: { totalTokens: 3 },
      runId: "run_1",
      provenance,
      taskResult
    });
  });

  it("produces the same canonical outcome as a direct run() on a real engine", async () => {
    const registry = new ProviderRegistry();
    registry.register(localProvider("local-a"));
    const engine = new IndeRun(registry, {
      connectivity: { isOnline: async () => true }
    });
    const options: TextGenerationOptions = { prompt: "Hi", requestId: "req-1" };

    const viaFacade = await generateText(engine, options);
    const direct = await engine.run(toTaskRequest(options));

    expect({ ...viaFacade.taskResult, telemetry: undefined }).toEqual({
      ...direct,
      telemetry: undefined
    });
    expect(viaFacade.provenance).toEqual(direct.provenance);
  });

  it("rejects exactly as run() does", async () => {
    const engine = new IndeRun(new ProviderRegistry(), {
      connectivity: { isOnline: async () => true }
    });

    await expect(generateText(engine, { prompt: "Hi", model: "unknown" })).rejects.toBeInstanceOf(
      IndeRunException
    );
  });
});

describe("streamText", () => {
  it("exposes text increments, the canonical events, and the result in any order", async () => {
    const events = [
      event("content_delta", { text: "Hel" }),
      event("content_delta", { text: "lo" }),
      terminal({ outcome: "completed", finalText: "Hello", finishReason: "stop", provenance })
    ];
    const stream = await streamText(fakeApi({ events }), { prompt: "Hi" });

    const result = await stream.result;
    expect(await collect(stream.textStream)).toEqual(["Hel", "lo"]);
    expect(await collect(stream.fullStream)).toEqual(events);
    expect(result).toMatchObject({
      text: "Hello",
      finishReason: "stop",
      runId: "run_1",
      provenance
    });
  });

  it("turns an extending snapshot into the new suffix", async () => {
    const stream = await streamText(
      fakeApi({
        events: [
          event("content_snapshot", { text: "Loc" }),
          event("content_snapshot", { text: "Local first" }),
          terminal({ outcome: "completed", finalText: "Local first" })
        ]
      }),
      { prompt: "Hi" }
    );

    expect(await collect(stream.textStream)).toEqual(["Loc", "al first"]);
  });

  it("ends the text view with a typed error when delivered text is retracted", async () => {
    const stream = await streamText(
      fakeApi({
        events: [
          event("content_snapshot", { text: "Draft" }),
          event("content_snapshot", { text: "" }),
          terminal({ outcome: "completed", finalText: "" })
        ]
      }),
      { prompt: "Hi" }
    );

    await expect(collect(stream.textStream)).rejects.toBeInstanceOf(TextStreamRetractedError);
    await expect(stream.result).resolves.toMatchObject({ text: "" });
  });

  it("rejects the result and the text view with the run's error and provenance", async () => {
    const failed = { ...provenance, attempts: [{ providerId: "p1", outcome: "failed" as const }] };
    const stream = await streamText(
      fakeApi({
        events: [
          event("content_delta", { text: "partial" }),
          terminal({
            outcome: "error",
            partialText: "partial",
            error: { schemaVersion: "1.0", errorClass: "RateLimited", message: "Slow down" },
            provenance: failed
          })
        ]
      }),
      { prompt: "Hi" }
    );

    const error = await stream.result.catch((caught: unknown) => caught as IndeRunException);
    expect(error).toBeInstanceOf(IndeRunException);
    expect(error).toMatchObject({ errorClass: "RateLimited", runId: "run_1", provenance: failed });
    await expect(collect(stream.textStream)).rejects.toMatchObject({ errorClass: "RateLimited" });
  });

  it("resolves a cancelled run with its partial text and forwards cancel()", async () => {
    const api = fakeApi({
      events: [
        event("content_delta", { text: "one" }),
        terminal({ outcome: "cancelled", partialText: "one", reason: "user stopped" })
      ]
    });
    const stream = await streamText(api, { prompt: "Hi" });
    stream.cancel("user stopped");

    await expect(stream.result).resolves.toMatchObject({ text: "one", finishReason: "cancelled" });
    expect(await collect(stream.textStream)).toEqual(["one"]);
    expect(api.cancelledWith).toEqual(["user stopped"]);
  });

  it("settles on the terminal event even when the source stays open after it", async () => {
    let released = false;
    const events = [
      event("content_delta", { text: "Hi" }),
      terminal({ outcome: "completed", finalText: "Hi", provenance })
    ];
    const openSource: AsyncIterator<StreamEvent> = {
      next: async () => {
        const value = events.shift();
        return value !== undefined
          ? { done: false, value }
          : new Promise<IteratorResult<StreamEvent>>(() => undefined);
      },
      return: async () => {
        released = true;
        return { done: true, value: undefined };
      }
    };
    const api: IndeRunApi = {
      ...fakeApi({}),
      async stream(): Promise<StreamRun> {
        return {
          handle: { schemaVersion: "1.0", runId: "run_1", startedAt: 0, providerId: "p1" },
          events: { [Symbol.asyncIterator]: () => openSource },
          cancel: () => undefined
        };
      }
    };
    const stream = await streamText(api, { prompt: "Hi" });

    await expect(stream.result).resolves.toMatchObject({ text: "Hi", provenance });
    expect(await collect(stream.textStream)).toEqual(["Hi"]);
    expect((await collect(stream.fullStream)).map((item) => item.type)).toEqual([
      "content_delta",
      "terminal"
    ]);
    expect(released).toBe(true);
  });

  it("rejects before there is a run exactly as stream() does", async () => {
    const engine = new IndeRun(new ProviderRegistry(), {
      connectivity: { isOnline: async () => true }
    });

    await expect(streamText(engine, { prompt: "Hi", model: "unknown" })).rejects.toBeInstanceOf(
      IndeRunException
    );
  });
});

function localProvider(id: string): ProviderAdapter {
  return {
    describe: () => ({
      id,
      type: "local",
      transport: "in_process",
      supports: {
        run: true,
        streaming: false,
        realtime: false,
        tools: false,
        reasoningEvents: false,
        structuredOutput: false,
        multimodal: false
      },
      cancel: "none",
      tasks: ["text_to_text"]
    }),
    capabilities: async () => ({ available: true }),
    run: async (request, context) => ({
      schemaVersion: "1.0",
      runId: context.runId,
      output: { type: "text", text: `Echo: ${request.prompt}` },
      finishReason: "stop",
      telemetry: { providerUsed: id, totalMs: 0 }
    })
  };
}

const forwardCompat = JSON.parse(
  readFileSync(
    join(
      dirname(fileURLToPath(import.meta.url)),
      "../../../../contracts/fixtures/streaming/forward-compat-events.json"
    ),
    "utf8"
  )
) as {
  cases: {
    id: string;
    events: StreamEvent[];
    expect: { textIncrements: string[]; text: string; fullStreamTypes: string[] };
  }[];
};

describe("streamText (shared forward-compatibility vectors)", () => {
  for (const vector of forwardCompat.cases) {
    it(vector.id, async () => {
      const api = fakeApi({ events: vector.events });
      const stream = await streamText(api, { prompt: "Hello" });

      expect(await collect(stream.textStream)).toEqual(vector.expect.textIncrements);
      expect((await collect(stream.fullStream)).map((e) => e.type)).toEqual(
        vector.expect.fullStreamTypes
      );
      expect((await stream.result).text).toBe(vector.expect.text);
    });
  }
});
