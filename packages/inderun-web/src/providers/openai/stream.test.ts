import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { TaskRequest } from "@independo/inderun-contracts";
import { describe, expect, it } from "vitest";
import type {
  HostServices,
  HttpRequest,
  HttpStreamResponse,
  HttpStreamingClientService,
  ProviderStreamEvent,
  SecureStorageService
} from "../../index.js";
import { IndeRunException } from "../../index.js";
import { OpenAIResponsesProvider } from "../../openai.js";

interface TranscriptCase {
  name: string;
  description: string;
  sse: string;
  expected: Array<Record<string, unknown>>;
}

const fixture = JSON.parse(
  readFileSync(
    join(
      dirname(fileURLToPath(import.meta.url)),
      "../../../../../contracts/fixtures/streaming/openai-responses-transcript.json"
    ),
    "utf8"
  )
) as { cases: TranscriptCase[] };

class ScriptedStreamingClient implements HttpStreamingClientService {
  readonly requests: HttpRequest[] = [];

  constructor(
    private readonly response: {
      status?: number;
      statusText?: string;
      headers?: Record<string, string>;
      chunks: string[];
    }
  ) {}

  async stream(request: HttpRequest, signal?: AbortSignal): Promise<HttpStreamResponse> {
    this.requests.push(request);
    const chunks = this.response.chunks;
    return {
      status: this.response.status ?? 200,
      statusText: this.response.statusText ?? "OK",
      headers: this.response.headers ?? { "content-type": "text/event-stream" },
      body: (async function* () {
        for (const chunk of chunks) {
          if (signal?.aborted) return;
          yield new TextEncoder().encode(chunk);
        }
      })()
    };
  }
}

class ThrowingStreamingClient implements HttpStreamingClientService {
  constructor(private readonly error: unknown) {}

  async stream(): Promise<HttpStreamResponse> {
    throw this.error;
  }
}

const secureStorage: SecureStorageService = {
  async getSecret() {
    return "sk-test";
  },
  async setSecret() {},
  async deleteSecret() {}
};

function createHost(streamingHttpClient?: HttpStreamingClientService): HostServices {
  const host: HostServices = {
    connectivity: {
      async isOnline() {
        return true;
      }
    },
    secureStorage
  };
  if (streamingHttpClient) host.streamingHttpClient = streamingHttpClient;
  return host;
}

const request: TaskRequest = {
  schemaVersion: "1.0",
  task: { kind: "text_to_text" },
  prompt: "Hello",
  authContextRef: "openai_default"
};

function createProvider() {
  return new OpenAIResponsesProvider({
    model: "gpt-5.2",
    endpointUrl: "https://proxy.test/v1/responses"
  });
}

async function collect(
  provider: ReturnType<typeof createProvider>,
  host: HostServices
): Promise<ProviderStreamEvent[]> {
  const events: ProviderStreamEvent[] = [];
  const iterable = provider.stream(request, {
    runId: "run-1",
    hostServices: host,
    signal: new AbortController().signal
  });
  for await (const event of iterable) events.push(event);
  return events;
}

describe("OpenAIResponsesProvider.stream", () => {
  it("declares streaming and a token streaming style", () => {
    expect(createProvider().describe()).toMatchObject({
      supports: { streaming: true },
      streamingStyle: "tokens",
      cancel: "hard"
    });
  });

  it("reports streaming as unavailable when the host cannot stream", async () => {
    const host = createHost();
    host.httpClient = {
      async send() {
        return { status: 200, statusText: "OK", headers: {}, body: "{}" };
      }
    };

    expect(await createProvider().capabilities(host)).toMatchObject({
      available: true,
      streamingAvailable: false,
      streamingUnavailableReason:
        "Host does not provide an HttpStreamingClientService, which OpenAI streaming requires."
    });
  });

  it("does not report a streaming restriction when the host can stream", async () => {
    const host = createHost(new ScriptedStreamingClient({ chunks: [] }));
    host.httpClient = {
      async send() {
        return { status: 200, statusText: "OK", headers: {}, body: "{}" };
      }
    };

    const capabilities = await createProvider().capabilities(host);
    expect(capabilities.available).toBe(true);
    expect(capabilities.streamingAvailable).toBeUndefined();
  });

  it("asks the endpoint to stream and authenticates with the resolved credential", async () => {
    const client = new ScriptedStreamingClient({
      chunks: ['data: {"type":"response.completed","response":{"output_text":"hi"}}\n\n']
    });
    await collect(createProvider(), createHost(client));

    const sent = client.requests[0]!;
    expect(JSON.parse(sent.body!)).toMatchObject({ model: "gpt-5.2", stream: true });
    expect(sent.headers?.Authorization).toBe("Bearer sk-test");
    expect(sent.headers?.Accept).toBe("text/event-stream");
  });

  for (const transcript of fixture.cases) {
    it(`${transcript.name}: ${transcript.description}`, async () => {
      const events = await collect(
        createProvider(),
        createHost(new ScriptedStreamingClient({ chunks: [transcript.sse] }))
      );

      expect(events).toHaveLength(transcript.expected.length);
      transcript.expected.forEach((expected, index) => {
        const actual = events[index]!;
        if (expected.kind === "error") {
          expect(actual.kind).toBe("error");
          const error = (actual as { error: IndeRunException }).error;
          expect(error).toBeInstanceOf(IndeRunException);
          expect(error.errorClass).toBe(expected.errorClass);
          expect(error.message).toBe(expected.message);
          return;
        }
        expect(actual).toEqual(expected);
      });
    });
  }

  it("is unaffected by how the event stream is chunked", async () => {
    const raw = fixture.cases[0]!.sse;
    const client = new ScriptedStreamingClient({ chunks: raw.split("") });

    const events = await collect(createProvider(), createHost(client));

    expect(events.map((event) => event.kind)).toEqual(["delta", "delta", "done"]);
  });

  it("classifies a non-2xx response before reading the body as an event stream", async () => {
    const client = new ScriptedStreamingClient({
      status: 429,
      statusText: "Too Many Requests",
      headers: { "retry-after": "3" },
      chunks: ['{"error":{"message":"Rate limit reached","code":"rate_limit_exceeded"}}']
    });

    await expect(collect(createProvider(), createHost(client))).rejects.toMatchObject({
      errorClass: "RateLimited",
      retryable: true,
      retryAfterMs: 3000
    });
  });

  it("maps a pre-response abort to a timeout", async () => {
    const client = new ThrowingStreamingClient({ name: "AbortError", message: "aborted" });

    await expect(collect(createProvider(), createHost(client))).rejects.toMatchObject({
      errorClass: "Timeout"
    });
  });

  it("refuses to stream when the host has no streaming client", async () => {
    await expect(collect(createProvider(), createHost())).rejects.toMatchObject({
      errorClass: "Unavailable"
    });
  });

  it("stops reading once the caller's signal aborts", async () => {
    const controller = new AbortController();
    const client = new ScriptedStreamingClient({
      chunks: [
        'data: {"type":"response.output_text.delta","delta":"one"}\n\n',
        'data: {"type":"response.output_text.delta","delta":"two"}\n\n'
      ]
    });

    const events: ProviderStreamEvent[] = [];
    for await (const event of createProvider().stream(request, {
      runId: "run-1",
      hostServices: createHost(client),
      signal: controller.signal
    })) {
      events.push(event);
      controller.abort();
    }

    expect(events).toEqual([{ kind: "delta", text: "one" }]);
  });

  it("ends without a terminal event when the stream is cut short", async () => {
    const client = new ScriptedStreamingClient({
      chunks: ['data: {"type":"response.output_text.delta","delta":"one"}\n\n']
    });

    // The engine turns this into its own provider-fault error; the adapter must
    // not invent a completion out of the deltas it happened to receive.
    expect(await collect(createProvider(), createHost(client))).toEqual([
      { kind: "delta", text: "one" }
    ]);
  });
});
