import type { TaskRequest } from "@independo/inderun-contracts";
import { describe, expect, it } from "vitest";
import {
  IndeRun,
  IndeRunException,
  OpenAIResponsesProvider,
  ProviderRegistry,
  createIndeRunWeb,
  type HostServices,
  type HttpClientService,
  type HttpRequest,
  type HttpResponse,
  type SecureStorageService
} from "./index.js";

class MockSecureStorage implements SecureStorageService {
  constructor(private readonly slots: Record<string, string> = {}) {}

  async getSecret(slotId: string): Promise<string | null> {
    return this.slots[slotId] ?? null;
  }

  async setSecret(slotId: string, secret: string): Promise<void> {
    this.slots[slotId] = secret;
  }

  async deleteSecret(slotId: string): Promise<void> {
    delete this.slots[slotId];
  }
}

class MockHttpClient implements HttpClientService {
  readonly requests: HttpRequest[] = [];

  constructor(private readonly responses: HttpResponse[]) {}

  async send(request: HttpRequest): Promise<HttpResponse> {
    this.requests.push(request);
    const response = this.responses.shift();
    if (!response) {
      throw new Error("No mock HTTP response queued.");
    }

    return response;
  }
}

class ThrowingHttpClient implements HttpClientService {
  async send(): Promise<HttpResponse> {
    throw { name: "AbortError", message: "The operation was aborted." };
  }
}

function createHost(httpClient: HttpClientService, secureStorage?: SecureStorageService): HostServices {
  const host: HostServices = {
    connectivity: {
      async isOnline() {
        return true;
      }
    },
    clock: {
      now() {
        return 1000;
      }
    },
    httpClient
  };

  if (secureStorage) {
    host.secureStorage = secureStorage;
  }

  return host;
}

function createRequest(overrides: Partial<TaskRequest> = {}): TaskRequest {
  const request: TaskRequest = {
    schemaVersion: "1.0",
    task: { kind: "text_to_text" },
    prompt: "Say hello.",
    policy: { execution: "cloud" },
    authContextRef: "openai-dev"
  };

  for (const [key, value] of Object.entries(overrides)) {
    if (value === undefined) {
      delete (request as Record<string, unknown>)[key];
    } else {
      (request as Record<string, unknown>)[key] = value;
    }
  }

  return request;
}

function jsonResponse(body: unknown, status = 200, headers: Record<string, string> = {}): HttpResponse {
  return {
    status,
    statusText: status === 200 ? "OK" : "Error",
    headers,
    body: JSON.stringify(body)
  };
}

async function runWithProvider(
  request: TaskRequest,
  httpClient: HttpClientService,
  provider = new OpenAIResponsesProvider({ model: "gpt-5.2" }),
  secureStorage: SecureStorageService = new MockSecureStorage({ "openai-dev": "sk-from-slot" })
) {
  const registry = new ProviderRegistry();
  registry.register(provider);
  const engine = new IndeRun(registry, createHost(httpClient, secureStorage));
  return engine.run(request);
}

describe("OpenAIResponsesProvider", () => {
  it("reports unavailable capabilities when auth is enabled without secure storage", async () => {
    const provider = new OpenAIResponsesProvider({ model: "gpt-5.2" });

    await expect(
      provider.capabilities(createHost(new MockHttpClient([])))
    ).resolves.toEqual({
      available: false,
      reason: "OpenAI Responses provider requires a SecureStorageService when auth is enabled."
    });
  });

  it("reports available capabilities for proxy mode without secure storage", async () => {
    const provider = new OpenAIResponsesProvider({
      model: "gpt-5.2",
      auth: "none"
    });

    await expect(
      provider.capabilities(createHost(new MockHttpClient([])))
    ).resolves.toEqual({ available: true });
  });

  it("posts a Responses API request and maps output_text to TaskResult output text", async () => {
    const httpClient = new MockHttpClient([
      jsonResponse({
        output_text: "Hello from Responses.",
        status: "completed",
        usage: {
          input_tokens: 3,
          output_tokens: 4,
          total_tokens: 7
        }
      })
    ]);

    const result = await runWithProvider(
      createRequest({
        generation: {
          maxOutputTokens: 64,
          temperature: 0.2,
          topP: 0.9,
          stop: ["END"]
        }
      }),
      httpClient
    );

    expect(result.output.text).toBe("Hello from Responses.");
    expect(result.finishReason).toBe("stop");
    expect(result.usage).toMatchObject({
      inputTokens: 3,
      outputTokens: 4,
      totalTokens: 7
    });
    expect(httpClient.requests).toHaveLength(1);
    expect(httpClient.requests[0]?.url).toBe("https://api.openai.com/v1/responses");
    expect(httpClient.requests[0]?.headers?.Authorization).toBe("Bearer sk-from-slot");

    const body = JSON.parse(httpClient.requests[0]?.body ?? "{}") as Record<string, unknown>;
    expect(body).toMatchObject({
      model: "gpt-5.2",
      input: "Say hello.",
      max_output_tokens: 64,
      temperature: 0.2,
      top_p: 0.9,
      stop: ["END"]
    });
  });

  it("aggregates text from Responses output items when output_text is not present", async () => {
    const httpClient = new MockHttpClient([
      jsonResponse({
        output: [
          {
            type: "message",
            content: [
              { type: "output_text", text: "Hello " },
              { type: "output_text", text: "there." }
            ]
          }
        ]
      })
    ]);

    const result = await runWithProvider(createRequest(), httpClient);

    expect(result.output.text).toBe("Hello there.");
  });

  it("maps system messages to developer messages for Responses input arrays", async () => {
    const httpClient = new MockHttpClient([
      jsonResponse({ output_text: "Done." })
    ]);

    await runWithProvider(
      createRequest({
        prompt: undefined,
        messages: [
          { role: "system", content: "Be concise." },
          { role: "user", content: "Say hello." }
        ]
      }),
      httpClient
    );

    const body = JSON.parse(httpClient.requests[0]?.body ?? "{}") as {
      input: Array<{ role: string; content: string }>;
    };
    expect(body.input).toEqual([
      { role: "developer", content: "Be concise." },
      { role: "user", content: "Say hello." }
    ]);
  });

  it("supports proxy mode without sending an Authorization header", async () => {
    const httpClient = new MockHttpClient([
      jsonResponse({ output_text: "Proxy response." })
    ]);
    const engine = createIndeRunWeb({
      openAI: {
        model: "gpt-5.2",
        endpointUrl: "/api/inderun/openai-responses",
        auth: "none"
      },
      hostServices: {
        httpClient,
        connectivity: {
          async isOnline() {
            return true;
          }
        }
      }
    });

    const result = await engine.run(createRequest({ authContextRef: undefined }));

    expect(result.output.text).toBe("Proxy response.");
    expect(httpClient.requests[0]?.url).toBe("/api/inderun/openai-responses");
    expect(httpClient.requests[0]?.headers?.Authorization).toBeUndefined();
  });

  it("requires explicit opt-in before createIndeRunWeb uses the direct OpenAI endpoint with browser credentials", () => {
    const directEndpointVariants = [
      undefined,
      "https://api.openai.com/v1/responses/",
      "https://api.openai.com/v1/responses?trace=1",
      "https://API.OPENAI.COM/v1/responses"
    ];

    for (const endpointUrl of directEndpointVariants) {
      expect(() =>
        createIndeRunWeb({
          openAI: endpointUrl
            ? {
                model: "gpt-5.2",
                endpointUrl
              }
            : {
                model: "gpt-5.2"
              },
          hostServices: {
            httpClient: new MockHttpClient([])
          }
        })
      ).toThrowError(/proxy-first/);
    }
  });

  it("throws AuthError when authContextRef is required but missing", async () => {
    const httpClient = new MockHttpClient([]);

    await expect(
      runWithProvider(createRequest({ authContextRef: undefined }), httpClient)
    ).rejects.toMatchObject({
      errorClass: "AuthError"
    });
    expect(httpClient.requests).toHaveLength(0);
  });

  it("throws AuthError with a precise message when secure storage is missing at runtime", async () => {
    const httpClient = new MockHttpClient([]);
    const provider = new OpenAIResponsesProvider({ model: "gpt-5.2" });
    const registry = new ProviderRegistry();
    registry.register(provider);

    await expect(
      provider.run(createRequest(), {
        runId: "run_missing_storage",
        hostServices: createHost(httpClient)
      })
    ).rejects.toMatchObject({
      errorClass: "AuthError",
      message: "OpenAI Responses provider requires a SecureStorageService when auth is enabled."
    });
    expect(httpClient.requests).toHaveLength(0);
  });

  it("maps DOM-style abort errors to Timeout", async () => {
    await expect(
      runWithProvider(createRequest(), new ThrowingHttpClient())
    ).rejects.toMatchObject({
      errorClass: "Timeout"
    });
  });

  it("maps OpenAI HTTP auth, rate limit, timeout, unavailable, and internal errors", async () => {
    const cases: Array<{
      status: number;
      headers?: Record<string, string>;
      expected: IndeRunException["errorClass"];
    }> = [
      { status: 401, expected: "AuthError" },
      { status: 429, headers: { "retry-after": "2" }, expected: "RateLimited" },
      { status: 408, expected: "Timeout" },
      { status: 503, expected: "Unavailable" },
      { status: 400, expected: "Internal" }
    ];

    for (const testCase of cases) {
      const httpClient = new MockHttpClient([
        jsonResponse(
          { error: { message: `OpenAI failed with ${testCase.status}` } },
          testCase.status,
          testCase.headers
        )
      ]);

      try {
        await runWithProvider(createRequest(), httpClient);
        throw new Error(`Expected ${testCase.expected}`);
      } catch (err) {
        expect(err).toBeInstanceOf(IndeRunException);
        expect((err as IndeRunException).errorClass).toBe(testCase.expected);
        if (testCase.status === 429) {
          expect((err as IndeRunException).retryAfterMs).toBe(2000);
        }
      }
    }
  });
});
