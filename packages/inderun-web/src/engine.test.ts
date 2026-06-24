import type { TaskRequest, TaskResult } from "@independo/inderun-contracts";
import { describe, it, expect, beforeEach } from "vitest";
import {
  IndeRun,
  ProviderRegistry,
  IndeRunException,
  createAuthError,
  createUnavailable,
  type HostServices,
  type HttpClientService,
  type HttpRequest,
  type HttpResponse,
  type ProviderAdapter,
  Router,
  type RoutePlanner
} from "./index.js";

function createMockLocalProvider(id: string, available = true): ProviderAdapter {
  return {
    describe() {
      return {
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
        cancel: "none",
        tasks: ["text_to_text"]
      };
    },
    async capabilities() {
      return { available };
    },
    async run(req: TaskRequest): Promise<TaskResult> {
      return {
        schemaVersion: "1.0",
        runId: req.requestId || "run-123",
        output: {
          type: "text",
          text: `Mock local response: ${req.prompt}`
        },
        finishReason: "stop",
        telemetry: {
          providerUsed: id,
          totalMs: 0
        }
      };
    }
  };
}

function createMockCloudProvider(id: string, available = true): ProviderAdapter {
  return {
    describe() {
      return {
        id,
        type: "cloud",
        transport: "http",
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
      };
    },
    async capabilities() {
      return { available };
    },
    async run(req: TaskRequest): Promise<TaskResult> {
      return {
        schemaVersion: "1.0",
        runId: req.requestId || "run-123",
        output: {
          type: "text",
          text: `Mock cloud response: ${req.prompt}`
        },
        finishReason: "stop",
        telemetry: {
          providerUsed: id,
          totalMs: 0
        }
      };
    }
  };
}

class MockSecureStorage {
  private slots = new Map<string, string>();

  constructor(initialSlots: Record<string, string> = {}) {
    for (const [slotId, secret] of Object.entries(initialSlots)) {
      this.slots.set(slotId, secret);
    }
  }

  async getSecret(slotId: string): Promise<string | null> {
    return this.slots.get(slotId) ?? null;
  }

  async setSecret(slotId: string, secret: string): Promise<void> {
    this.slots.set(slotId, secret);
  }

  async deleteSecret(slotId: string): Promise<void> {
    this.slots.delete(slotId);
  }
}

class MockHttpClient implements HttpClientService {
  public readonly requests: HttpRequest[] = [];

  async send(request: HttpRequest): Promise<HttpResponse> {
    this.requests.push(request);

    return {
      status: 200,
      statusText: "OK",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ outputText: "Mock authenticated cloud response" })
    };
  }
}

function createMockHostServices(
  online = true,
  services: Pick<Partial<HostServices>, "secureStorage" | "httpClient"> = {}
): HostServices {
  let timeVal = 1000;
  const host: HostServices = {
    connectivity: {
      async isOnline() {
        return online;
      }
    },
    clock: {
      now() {
        // Monotonically increments on every call for predictable time duration testing
        timeVal += 50;
        return timeVal;
      }
    }
  };

  if (services.secureStorage) {
    host.secureStorage = services.secureStorage;
  }

  if (services.httpClient) {
    host.httpClient = services.httpClient;
  }

  return host;
}

function createAuthenticatedMockCloudProvider(id: string): ProviderAdapter {
  return {
    describe() {
      return {
        id,
        type: "cloud",
        transport: "http",
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
        tasks: ["text_to_text"],
        privacy: { dataLeavesDevice: true }
      };
    },
    async capabilities(host) {
      if (host.secureStorage && host.httpClient) {
        return { available: true };
      }

      return {
        available: false,
        reason: "Secure storage and HTTP client host services are required."
      };
    },
    async run(req: TaskRequest, ctx): Promise<TaskResult> {
      if (!req.authContextRef) {
        throw createAuthError("AuthError: cloud provider requires authContextRef.");
      }

      const secret = await ctx.hostServices.secureStorage?.getSecret(req.authContextRef);
      if (!secret) {
        throw createAuthError(
          `AuthError: no credential found for authContextRef '${req.authContextRef}'.`
        );
      }

      const httpClient = ctx.hostServices.httpClient;
      if (!httpClient) {
        throw createUnavailable("Unavailable: HTTP client host service is not configured.");
      }

      const response = await httpClient.send({
        method: "POST",
        url: "https://api.example.test/v1/responses",
        headers: {
          Authorization: `Bearer ${secret}`,
          "Content-Type": "application/json"
        },
        body: JSON.stringify({
          input: req.prompt
        })
      });

      const body = JSON.parse(response.body) as { outputText: string };
      return {
        schemaVersion: "1.0",
        runId: ctx.runId,
        output: {
          type: "text",
          text: body.outputText
        },
        finishReason: "stop",
        telemetry: {
          providerUsed: id,
          totalMs: 0
        }
      };
    }
  };
}

function createRequest(overrides: Partial<TaskRequest> = {}): TaskRequest {
  return {
    schemaVersion: "1.0",
    task: { kind: "text_to_text" },
    prompt: "test prompt",
    policy: { execution: "on_device" },
    ...overrides
  };
}

describe("IndeRun Engine Core Skeleton Tests", () => {
  let registry: ProviderRegistry;

  beforeEach(() => {
    registry = new ProviderRegistry();
  });

  describe("ProviderRegistry", () => {
    it("throws an error when registering a provider with a duplicate ID", () => {
      const p1 = createMockLocalProvider("mock-local-1");
      const p2 = createMockLocalProvider("mock-local-1");
      registry.register(p1);
      expect(() => registry.register(p2)).toThrowError(
        /Provider with ID "mock-local-1" is already registered/
      );
    });
  });

  it("selects a provider from shared planner output when available", async () => {
    registry.register(createMockLocalProvider("provider-a", true));
    registry.register(createMockLocalProvider("provider-b", true));

    const planner: RoutePlanner = {
      async planRoute() {
        return {
          selectedProviderId: "provider-b",
          fallbackProviderIds: ["provider-a"],
          candidates: [
            { providerId: "provider-b", order: 0 },
            { providerId: "provider-a", order: 1 }
          ],
          rejectedProviders: [],
          failureCode: null,
          explanation: {
            summary: "Selected provider 'provider-b' from shared Rust planner."
          }
        };
      }
    };

    const selection = await new Router(registry, planner).selectRoute(
      createRequest(),
      createMockHostServices(true)
    );

    expect(selection.provider.describe().id).toBe("provider-b");
    expect(selection.explanation).toContain("shared Rust planner");
  });

  describe("Request Validation", () => {
    it("fails early with Internal error if request payload is invalid", async () => {
      const host = createMockHostServices(true);
      const engine = new IndeRun(registry, host);

      // Prompt is missing and task format is invalid
      const invalidRequest = {
        schemaVersion: "1.0",
        task: { kind: "invalid_task" },
        policy: { execution: "cloud" }
      } as unknown as TaskRequest;

      await expect(engine.run(invalidRequest)).rejects.toThrowError(
        /Validation failed for TaskRequest/
      );

      try {
        await engine.run(invalidRequest);
      } catch (err) {
        expect(err).toBeInstanceOf(IndeRunException);
        const exception = err as IndeRunException;
        expect(exception.errorClass).toBe("Internal");
        expect(exception.details?.validationIssues).toBeDefined();
        // Timing should be populated
        expect(exception.details?.totalMs).toBe(50);
      }
    });

    it("fails with Internal error if secrets are present in the request", async () => {
      const host = createMockHostServices(true);
      const engine = new IndeRun(registry, host);

      const invalidRequest = {
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "Hello",
        policy: { execution: "cloud" },
        apiKey: "sk-should-not-be-here" // forbidden key
      } as unknown as TaskRequest;

      await expect(engine.run(invalidRequest)).rejects.toThrowError(
        /Inline secrets are not allowed/
      );
    });
  });

  describe("Routing execution = on_device", () => {
    it("routes successfully to a local provider when execution is on_device and local provider is available", async () => {
      const provider = createMockLocalProvider("mock-local-1", true);
      registry.register(provider);

      const host = createMockHostServices(true);
      const engine = new IndeRun(registry, host);

      const req: TaskRequest = {
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "test prompt",
        policy: { execution: "on_device" }
      };

      const result = await engine.run(req);
      expect(result.output.text).toBe("Mock local response: test prompt");
      expect(result.telemetry.providerUsed).toBe("mock-local-1");
      // Timings: mock clock is read at start, route_decided emission, and end telemetry (total 3 reads).
      expect(result.telemetry.totalMs).toBe(100);
    });

    it("ensures the result runId matches the engine's runId", async () => {
      const provider = createMockLocalProvider("mock-local-1", true);
      registry.register(provider);

      const host = createMockHostServices(true);
      const engine = new IndeRun(registry, host);

      const req: TaskRequest = {
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "test prompt",
        policy: { execution: "on_device" },
        requestId: "orchestrator-run-999"
      };

      const result = await engine.run(req);
      expect(result.runId).toBe("orchestrator-run-999");
    });

    it("throws CapabilityMismatch if on_device execution selected but no local providers are registered", async () => {
      const host = createMockHostServices(true);
      const engine = new IndeRun(registry, host);

      const req: TaskRequest = {
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "test prompt",
        policy: { execution: "on_device" }
      };

      await expect(engine.run(req)).rejects.toThrowError(
        /no on-device provider found/
      );

      try {
        await engine.run(req);
      } catch (err) {
        expect(err).toBeInstanceOf(IndeRunException);
        const exception = err as IndeRunException;
        expect(exception.errorClass).toBe("CapabilityMismatch");
        expect(exception.details?.totalMs).toBeDefined();
      }
    });

    it("throws CapabilityMismatch if on_device selected but registered local provider is unavailable", async () => {
      const provider = createMockLocalProvider("mock-local-unavailable", false);
      registry.register(provider);

      const host = createMockHostServices(true);
      const engine = new IndeRun(registry, host);

      const req: TaskRequest = {
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "test prompt",
        policy: { execution: "on_device" }
      };

      await expect(engine.run(req)).rejects.toThrowError(
        /on-device provider is currently unavailable/
      );

      try {
        await engine.run(req);
      } catch (err) {
        expect(err).toBeInstanceOf(IndeRunException);
        const exception = err as IndeRunException;
        expect(exception.errorClass).toBe("CapabilityMismatch");
      }
    });
  });

  describe("Routing execution = cloud", () => {
    it("routes successfully to a cloud provider when execution is cloud, network is online and provider available", async () => {
      const provider = createMockCloudProvider("mock-cloud-1", true);
      registry.register(provider);

      const host = createMockHostServices(true);
      const engine = new IndeRun(registry, host);

      const req: TaskRequest = {
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "test prompt",
        policy: { execution: "cloud" }
      };

      const result = await engine.run(req);
      expect(result.output.text).toBe("Mock cloud response: test prompt");
      expect(result.telemetry.providerUsed).toBe("mock-cloud-1");
      expect(result.telemetry.totalMs).toBe(100);
    });

    it("throws Offline if cloud execution is selected but the device is offline", async () => {
      const provider = createMockCloudProvider("mock-cloud-1", true);
      registry.register(provider);

      const host = createMockHostServices(false); // offline
      const engine = new IndeRun(registry, host);

      const req: TaskRequest = {
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "test prompt",
        policy: { execution: "cloud" }
      };

      await expect(engine.run(req)).rejects.toThrowError(
        /no network connection is available/
      );

      try {
        await engine.run(req);
      } catch (err) {
        expect(err).toBeInstanceOf(IndeRunException);
        const exception = err as IndeRunException;
        expect(exception.errorClass).toBe("Offline");
        expect(exception.details?.totalMs).toBeDefined();
      }
    });

    it("throws Unavailable if cloud selected, online, but no cloud providers are registered", async () => {
      const host = createMockHostServices(true);
      const engine = new IndeRun(registry, host);

      const req: TaskRequest = {
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "test prompt",
        policy: { execution: "cloud" }
      };

      await expect(engine.run(req)).rejects.toThrowError(
        /no cloud provider found/
      );

      try {
        await engine.run(req);
      } catch (err) {
        expect(err).toBeInstanceOf(IndeRunException);
        const exception = err as IndeRunException;
        expect(exception.errorClass).toBe("Unavailable");
      }
    });

    it("throws Unavailable if cloud selected, online, but cloud provider is unavailable", async () => {
      const provider = createMockCloudProvider("mock-cloud-unavailable", false);
      registry.register(provider);

      const host = createMockHostServices(true);
      const engine = new IndeRun(registry, host);

      const req: TaskRequest = {
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "test prompt",
        policy: { execution: "cloud" }
      };

      await expect(engine.run(req)).rejects.toThrowError(
        /no cloud provider is currently available/
      );

      try {
        await engine.run(req);
      } catch (err) {
        expect(err).toBeInstanceOf(IndeRunException);
        const exception = err as IndeRunException;
        expect(exception.errorClass).toBe("Unavailable");
      }
    });
  });

  describe("No secrets in requests via authContextRef", () => {
    it("resolves authContextRef through SecureStorage and sends the HTTP Authorization header", async () => {
      const provider = createAuthenticatedMockCloudProvider("mock-auth-cloud");
      registry.register(provider);

      const secureStorage = new MockSecureStorage({
        "openai-dev": "sk-test-from-secure-storage"
      });
      const httpClient = new MockHttpClient();
      const host = createMockHostServices(true, {
        secureStorage,
        httpClient
      });
      const engine = new IndeRun(registry, host);

      const req: TaskRequest = {
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "test prompt",
        policy: { execution: "cloud" },
        authContextRef: "openai-dev"
      };

      const result = await engine.run(req);

      expect(result.output.text).toBe("Mock authenticated cloud response");
      expect(result.telemetry.providerUsed).toBe("mock-auth-cloud");
      expect(httpClient.requests).toHaveLength(1);
      expect(httpClient.requests[0]?.headers?.Authorization).toBe(
        "Bearer sk-test-from-secure-storage"
      );
      expect(httpClient.requests[0]?.body).not.toContain("sk-test-from-secure-storage");
      expect(req).not.toHaveProperty("apiKey");
      expect(req).not.toHaveProperty("token");
    });

    it("throws AuthError when authContextRef is missing", async () => {
      const provider = createAuthenticatedMockCloudProvider("mock-auth-cloud");
      registry.register(provider);

      const host = createMockHostServices(true, {
        secureStorage: new MockSecureStorage({
          "openai-dev": "sk-test-from-secure-storage"
        }),
        httpClient: new MockHttpClient()
      });
      const engine = new IndeRun(registry, host);

      const req: TaskRequest = {
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "test prompt",
        policy: { execution: "cloud" }
      };

      await expect(engine.run(req)).rejects.toThrowError(/requires authContextRef/);

      try {
        await engine.run(req);
      } catch (err) {
        expect(err).toBeInstanceOf(IndeRunException);
        expect((err as IndeRunException).errorClass).toBe("AuthError");
      }
    });

    it("throws AuthError when authContextRef points to an empty SecureStorage slot", async () => {
      const provider = createAuthenticatedMockCloudProvider("mock-auth-cloud");
      registry.register(provider);

      const host = createMockHostServices(true, {
        secureStorage: new MockSecureStorage(),
        httpClient: new MockHttpClient()
      });
      const engine = new IndeRun(registry, host);

      const req: TaskRequest = {
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "test prompt",
        policy: { execution: "cloud" },
        authContextRef: "missing-slot"
      };

      await expect(engine.run(req)).rejects.toThrowError(/no credential found/);

      try {
        await engine.run(req);
      } catch (err) {
        expect(err).toBeInstanceOf(IndeRunException);
        expect((err as IndeRunException).errorClass).toBe("AuthError");
      }
    });
  });

  describe("Telemetry Event Emission", () => {
    class MockTelemetryService {
      public events: any[] = [];
      emit(event: any) {
        this.events.push(event);
      }
    }

    it("emits route_decided and attempt_succeeded on successful run", async () => {
      const provider = createMockLocalProvider("mock-local-1", true);
      registry.register(provider);

      const host = createMockHostServices(true);
      const telemetry = new MockTelemetryService();
      const engine = new IndeRun(registry, host, telemetry);

      const req: TaskRequest = {
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "hello telemetry",
        policy: { execution: "on_device" },
        requestId: "test-run-1"
      };

      await engine.run(req);

      expect(telemetry.events).toHaveLength(2);
      expect(telemetry.events[0]).toMatchObject({
        type: "route_decided",
        runId: "test-run-1",
        payload: {
          selectedProviderId: "mock-local-1",
          executionPolicy: "on_device",
          taskKind: "text_to_text"
        }
      });
      expect(telemetry.events[1]).toMatchObject({
        type: "attempt_succeeded",
        runId: "test-run-1",
        payload: {
          providerId: "mock-local-1",
          durationMs: 100
        }
      });
    });

    it("emits attempt_failed on routing failure (e.g. offline)", async () => {
      const provider = createMockCloudProvider("mock-cloud-1", true);
      registry.register(provider);

      const host = createMockHostServices(false); // offline
      const telemetry = new MockTelemetryService();
      const engine = new IndeRun(registry, host, telemetry);

      const req: TaskRequest = {
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "hello telemetry fail",
        policy: { execution: "cloud" },
        requestId: "test-run-fail"
      };

      await expect(engine.run(req)).rejects.toThrow();

      expect(telemetry.events).toHaveLength(1);
      expect(telemetry.events[0]).toMatchObject({
        type: "attempt_failed",
        runId: "test-run-fail",
        payload: {
          providerId: null, // no provider selected since offline routing failed early
          durationMs: 50,
          errorClass: "Offline",
          message: "Device is offline."
        }
      });
    });

    it("emits route_decided and attempt_failed if provider execution throws", async () => {
      const failingProvider: ProviderAdapter = {
        describe() {
          return {
            id: "failing-provider",
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
            cancel: "none",
            tasks: ["text_to_text"]
          };
        },
        async capabilities() {
          return { available: true };
        },
        async run() {
          throw new Error("Simulated provider failure");
        }
      };
      registry.register(failingProvider);

      const host = createMockHostServices(true);
      const telemetry = new MockTelemetryService();
      const engine = new IndeRun(registry, host, telemetry);

      const req: TaskRequest = {
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "hello provider fail",
        policy: { execution: "on_device" },
        requestId: "test-run-provider-fail"
      };

      await expect(engine.run(req)).rejects.toThrow();

      expect(telemetry.events).toHaveLength(2);
      expect(telemetry.events[0]).toMatchObject({
        type: "route_decided",
        runId: "test-run-provider-fail",
        payload: {
          selectedProviderId: "failing-provider"
        }
      });
      expect(telemetry.events[1]).toMatchObject({
        type: "attempt_failed",
        runId: "test-run-provider-fail",
        payload: {
          providerId: "failing-provider",
          durationMs: 100,
          errorClass: "Internal",
          message: "An internal engine error occurred."
        }
      });
    });

    it("does not fail execution if the telemetry service emit throws an error", async () => {
      const provider = createMockLocalProvider("mock-local-1", true);
      registry.register(provider);

      const host = createMockHostServices(true);
      const throwingTelemetry = {
        emit() {
          throw new Error("Simulated telemetry service failure");
        }
      };
      const engine = new IndeRun(registry, host, throwingTelemetry);

      const req: TaskRequest = {
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "hello telemetry throw",
        policy: { execution: "on_device" }
      };

      // Execution should complete successfully even if emit throws
      const result = await engine.run(req);
      expect(result.output.text).toBe("Mock local response: hello telemetry throw");
    });
  });
});
