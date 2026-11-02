import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  generateSpeech,
  IndeRun,
  IndeRunException,
  listVoices,
  speak,
  toSpeechRequest,
  type GenerateSpeechOptions,
  type IndeRunApi,
  type MediaArtifact,
  type ProviderCapabilitySnapshot,
  type SpeakOptions,
  type StreamEvent,
  type StreamRun,
  type StreamTerminalOutcome,
  type TaskRequest,
  type TaskResult
} from "../index.js";
import { createBrowserHostServices } from "../core/browser-host.js";
import { ProviderRegistry } from "../provider.js";
import { createFakeStreamProvider } from "../test/stream-fakes.js";

const fixture = JSON.parse(
  readFileSync(
    join(
      dirname(fileURLToPath(import.meta.url)),
      "../../../../contracts/fixtures/facade/speech.json"
    ),
    "utf8"
  )
) as {
  cases: {
    id: string;
    call: "speak" | "generateSpeech";
    options: SpeakOptions & GenerateSpeechOptions;
    expected: TaskRequest;
  }[];
};

/** An `IndeRunApi` that records requests and answers with what the test scripted. */
function fakeApi(overrides: Partial<IndeRunApi>): IndeRunApi & { requests: TaskRequest[] } {
  const requests: TaskRequest[] = [];
  return {
    requests,
    run: async (request) => {
      requests.push(request);
      throw new Error("run not scripted");
    },
    stream: async (request) => {
      requests.push(request);
      throw new Error("stream not scripted");
    },
    checkCapabilities: async () => [],
    readArtifact: async () => {
      throw new Error("not scripted");
    },
    disposeArtifact: async () => undefined,
    ...overrides
  };
}

function runEnding(
  outcome: StreamTerminalOutcome,
  onCancel?: (reason?: string) => void
): StreamRun {
  const terminal = { type: "terminal", runId: outcome.runId, payload: outcome } as unknown;
  return {
    handle: { runId: outcome.runId },
    events: (async function* () {
      yield terminal as StreamEvent;
    })(),
    cancel: onCancel ?? (() => undefined)
  } as unknown as StreamRun;
}

const provenance = {
  schemaVersion: "1.0",
  modelProfile: "auto",
  providerId: "tts",
  locality: "on_device",
  attemptCount: 1,
  fallbackOccurred: false,
  attempts: [{ providerId: "tts", outcome: "succeeded", committed: true }],
  routeRejections: []
} as NonNullable<TaskResult["provenance"]>;

describe("speech facade translation (shared vectors)", () => {
  for (const vector of fixture.cases) {
    it(vector.id, async () => {
      const api = fakeApi({
        stream: async (request) => {
          api.requests.push(request);
          return runEnding({ outcome: "completed", runId: "r", output: { type: "playback" } });
        },
        run: async (request) => {
          api.requests.push(request);
          return {
            runId: "r",
            finishReason: "stop",
            output: {
              type: "artifact",
              artifact: { id: "art_1" } as MediaArtifact
            }
          } as unknown as TaskResult;
        }
      });

      if (vector.call === "speak") {
        await (
          await speak(api, vector.options)
        ).result;
      } else {
        await generateSpeech(api, vector.options);
      }

      expect(api.requests).toEqual([vector.expected]);
    });
  }

  it("takes a delivery object or a mode", () => {
    const options = { text: "x", locale: "de" };
    expect(toSpeechRequest(options, "playback").delivery).toEqual({ mode: "playback" });
    expect(toSpeechRequest(options, { mode: "artifact" }).delivery).toEqual({ mode: "artifact" });
  });
});

describe("speak", () => {
  it("resolves with what played and the provenance", async () => {
    const api = fakeApi({
      stream: async () =>
        runEnding({
          outcome: "completed",
          runId: "r1",
          finishReason: "stop",
          output: {
            type: "playback",
            playback: { durationMs: 1200 },
            speech: { locale: "de-DE" }
          },
          provenance
        })
    });

    const playback = await speak(api, { text: "Hallo", locale: "de-AT" });

    expect(playback.runId).toBe("r1");
    await expect(playback.result).resolves.toMatchObject({
      finishReason: "stop",
      durationMs: 1200,
      speech: { locale: "de-DE" },
      runId: "r1",
      provenance
    });
  });

  it("resolves a cancelled run rather than rejecting", async () => {
    const api = fakeApi({
      stream: async () =>
        runEnding({
          outcome: "cancelled",
          runId: "r2",
          output: { type: "playback", playback: {} }
        })
    });

    const { result } = await speak(api, { text: "Hallo", locale: "de" });

    await expect(result).resolves.toMatchObject({ finishReason: "cancelled", runId: "r2" });
  });

  it("forwards cancel to the run", async () => {
    const reasons: (string | undefined)[] = [];
    const api = fakeApi({
      stream: async () =>
        runEnding({ outcome: "cancelled", runId: "r3" }, (reason) => reasons.push(reason))
    });

    const playback = await speak(api, { text: "Hallo", locale: "de" });
    playback.cancel("user");

    expect(reasons).toEqual(["user"]);
  });

  it("rejects with the run's exception and its provenance", async () => {
    const api = fakeApi({
      stream: async () =>
        runEnding({
          outcome: "error",
          runId: "r4",
          error: { errorClass: "Unavailable", message: "gone", retryable: false },
          provenance
        })
    });

    const { result } = await speak(api, { text: "Hallo", locale: "de" });

    await expect(result).rejects.toBeInstanceOf(IndeRunException);
    await expect(result).rejects.toMatchObject({ errorClass: "Unavailable", provenance });
  });

  it("rejects when a source ends without a terminal event", async () => {
    const api = fakeApi({
      stream: async () =>
        ({
          handle: { runId: "r5" },
          events: (async function* () {})(),
          cancel: () => undefined
        }) as unknown as StreamRun
    });

    const { result } = await speak(api, { text: "Hallo", locale: "de" });

    await expect(result).rejects.toMatchObject({ errorClass: "Internal", runId: "r5" });
  });

  it("stops real playback through the engine with one terminal outcome", async () => {
    const registry = new ProviderRegistry();
    registry.register(
      createFakeStreamProvider("tts", {
        task: "text_to_speech",
        script: [{ commit: true }, { waitForCancellation: true }]
      })
    );
    const inderun = new IndeRun(registry, createBrowserHostServices());

    const playback = await speak(inderun, { text: "Hallo", locale: "de-AT" });
    // Let the attempt reach its commit, so the cancel stops audio rather than preventing it.
    await new Promise((resolve) => setTimeout(resolve, 5));
    playback.cancel("stop");
    const ending = await playback.result;

    expect(ending.finishReason).toBe("cancelled");
    expect(ending.outcome.outcome).toBe("cancelled");
    expect(ending.outcome.output).toEqual({ type: "playback", playback: {} });
    expect(ending.provenance?.attempts[0]?.committed).toBe(true);
  });
});

describe("generateSpeech", () => {
  it("returns the artifact reference with what was used", async () => {
    const artifact: MediaArtifact = {
      id: "art_1",
      mediaType: "audio/wav",
      owner: "engine",
      lifetime: "until_disposed",
      byteLength: 44
    };
    const taskResult = {
      runId: "r6",
      finishReason: "stop",
      output: { type: "artifact", artifact, speech: { locale: "de-DE" } },
      provenance
    } as unknown as TaskResult;
    const api = fakeApi({ run: async () => taskResult });

    await expect(generateSpeech(api, { text: "Hallo", locale: "de-AT" })).resolves.toEqual({
      artifact,
      speech: { locale: "de-DE" },
      finishReason: "stop",
      runId: "r6",
      provenance,
      taskResult
    });
  });
});

describe("listVoices", () => {
  const snapshots = [
    {
      providerId: "text_only",
      capabilities: { available: true }
    },
    {
      providerId: "off",
      capabilities: {
        available: false,
        taskCapabilities: [{ kind: "text_to_speech", voices: [{ locale: "de-DE" }] }]
      }
    },
    {
      providerId: "task_off",
      capabilities: {
        available: true,
        taskCapabilities: [
          { kind: "text_to_speech", available: false, voices: [{ locale: "de-DE" }] }
        ]
      }
    },
    {
      providerId: "tts",
      capabilities: {
        available: true,
        taskCapabilities: [
          {
            kind: "text_to_speech",
            voices: [
              { locale: "de-DE", gender: "female", networkRequired: false },
              { locale: "de_AT" },
              { locale: "en-GB", networkRequired: true }
            ]
          }
        ]
      }
    }
  ] as unknown as ProviderCapabilitySnapshot[];
  const api = fakeApi({ checkCapabilities: async () => snapshots });

  it("lists the voices of available providers, in order", async () => {
    await expect(listVoices(api)).resolves.toEqual([
      { providerId: "tts", locale: "de-DE", gender: "female", networkRequired: false },
      { providerId: "tts", locale: "de_AT" },
      { providerId: "tts", locale: "en-GB", networkRequired: true }
    ]);
  });

  it("matches a locale by language by default", async () => {
    const voices = await listVoices(api, { locale: "de-AT" });
    expect(voices.map((voice) => voice.locale)).toEqual(["de-DE", "de_AT"]);
  });

  it("matches the whole tag when asked to", async () => {
    const voices = await listVoices(api, { locale: "DE-de", localeMatch: "exact" });
    expect(voices.map((voice) => voice.locale)).toEqual(["de-DE"]);
  });
});
