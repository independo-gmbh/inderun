import type { TaskRequest, TaskResult } from "@independo/inderun-contracts";
import { describe, it, expect, beforeEach } from "vitest";
import {
  IndeRun,
  ProviderRegistry,
  IndeRunException,
  type HostServices,
  type ProviderAdapter
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

function createMockHostServices(online = true): HostServices {
  let timeVal = 1000;
  return {
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
      // Timings: the mock clock is read only at start and end, so total elapsed time is one 50ms increment.
      expect(result.telemetry.totalMs).toBe(50);
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
      expect(result.telemetry.totalMs).toBe(50);
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
});
