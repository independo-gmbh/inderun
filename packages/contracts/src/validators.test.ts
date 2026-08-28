import { describe, expect, it } from "vitest";

import {
  getHttpRequestValidationIssues,
  getHttpResponseValidationIssues,
  getIndeRunErrorValidationIssues,
  getModelPackageValidationIssues,
  getStreamEventValidationIssues,
  getStreamRunHandleValidationIssues,
  getTaskRequestValidationIssues,
  getTelemetryEventValidationIssues,
  validateHttpRequest,
  validateHttpResponse,
  validateIndeRunError,
  validateModelPackage,
  validateStreamEvent,
  validateStreamRunHandle,
  validateStreamTerminalOutcome,
  validateTaskRequest,
  validateTaskResult,
  validateTelemetryEvent
} from "./index.js";

describe("TaskRequest validation", () => {
  it("accepts a minimal text-to-text prompt request", () => {
    expect(
      validateTaskRequest({
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "Summarize this.",
        constraints: { cloud: "allowed", privacy: "cloud_allowed" }
      })
    ).toBe(true);
  });

  it("accepts a fuller message request with forward-compatible fields", () => {
    expect(
      validateTaskRequest({
        schemaVersion: "1.0",
        requestId: "req_123",
        task: { kind: "text_to_text", futureTaskHint: "ignored" },
        messages: [{ role: "user", content: "Hello" }],
        generation: { maxOutputTokens: 128, temperature: 0.2 },
        constraints: {
          cloud: "forbidden",
          privacy: "local_required",
          futureRoutingHint: "ignored"
        },
        preferences: { optimizeFor: "privacy" },
        telemetry: { consent: true, level: "minimal", tags: { feature: "demo" } },
        authContextRef: "openai-dev",
        futureTopLevelField: true
      })
    ).toBe(true);
  });

  it("rejects unsupported schema versions", () => {
    expect(
      getTaskRequestValidationIssues({
        schemaVersion: "2.0",
        task: { kind: "text_to_text" },
        prompt: "Hello",
        constraints: { cloud: "allowed", privacy: "cloud_allowed" }
      }).some((issue) => issue.path === "/schemaVersion")
    ).toBe(true);
  });

  it("rejects contradictory routing constraints", () => {
    expect(
      getTaskRequestValidationIssues({
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "Hello",
        constraints: { privacy: "local_required", cloud: "required" }
      }).some((issue) => issue.keyword === "routingConstraintConflict")
    ).toBe(true);
  });

  it("rejects requests without prompt or messages", () => {
    expect(
      getTaskRequestValidationIssues({
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        constraints: { cloud: "allowed", privacy: "cloud_allowed" }
      }).some((issue) => issue.keyword === "anyOf")
    ).toBe(true);
  });

  it("rejects inline secret-like fields even when unknown fields are allowed", () => {
    expect(
      getTaskRequestValidationIssues({
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "Hello",
        constraints: { cloud: "allowed", privacy: "cloud_allowed" },
        apiKey: "sk-test"
      }).some((issue) => issue.keyword === "forbiddenSecretKey")
    ).toBe(true);
  });

  it("rejects common inline secret key variants", () => {
    const issues = getTaskRequestValidationIssues({
      schemaVersion: "1.0",
      task: { kind: "text_to_text" },
      prompt: "Hello",
      constraints: { cloud: "allowed", privacy: "cloud_allowed" },
      provider: {
        openaiApiKey: "sk-test",
        bearerToken: "bearer-test",
        client_secret: "secret-test"
      }
    });

    expect(issues.filter((issue) => issue.keyword === "forbiddenSecretKey")).toHaveLength(3);
  });

  it("does not reject token count fields as inline secrets", () => {
    expect(
      validateTaskRequest({
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "Hello",
        constraints: { cloud: "allowed", privacy: "cloud_allowed" },
        generation: { maxOutputTokens: 128 }
      })
    ).toBe(true);
  });
});

describe("TaskResult validation", () => {
  it("accepts a text result with required telemetry", () => {
    expect(
      validateTaskResult({
        schemaVersion: "1.0",
        runId: "run_123",
        output: { type: "text", text: "Done" },
        finishReason: "stop",
        usage: { inputTokens: 2, outputTokens: 1, totalTokens: 3 },
        telemetry: { providerUsed: "openai", totalMs: 123 }
      })
    ).toBe(true);
  });
});

describe("IndeRunError validation", () => {
  it("accepts a normalized milestone error", () => {
    expect(
      validateIndeRunError({
        schemaVersion: "1.0",
        errorClass: "Offline",
        message: "Network unavailable",
        retryable: true
      })
    ).toBe(true);
  });

  it("rejects unsupported error classes", () => {
    expect(
      getIndeRunErrorValidationIssues({
        schemaVersion: "1.0",
        errorClass: "ProviderExploded",
        message: "Nope"
      }).some((issue) => issue.path === "/errorClass")
    ).toBe(true);
  });
});

describe("ModelPackage validation", () => {
  it("accepts a minimal model package", () => {
    expect(
      validateModelPackage({
        id: "phi-3-mini",
        format: "genai"
      })
    ).toBe(true);
  });

  it("accepts a fuller package with source, files, integrity, and forward-compatible fields", () => {
    expect(
      validateModelPackage({
        id: "phi-3-mini",
        version: "1.2.0",
        format: "onnx",
        tasks: ["text_to_text"],
        runtime: { minOpset: 17, platforms: ["web", "android"] },
        files: {
          required: ["model.onnx"],
          tokenizer: "tokenizer.json",
          external: ["model.onnx_data"]
        },
        integrity: { checksums: { "model.onnx": "sha256:abc" } },
        license: { spdx: "MIT" },
        source: { sourceType: "registry", ref: "org/phi-3-mini-onnx" },
        limits: { diskBytes: 2_000_000_000, memBytes: 4_000_000_000 },
        futureField: "ignored"
      })
    ).toBe(true);
  });

  it("rejects an unsupported model format", () => {
    expect(
      getModelPackageValidationIssues({
        id: "phi-3-mini",
        format: "gguf"
      }).some((issue) => issue.path === "/format")
    ).toBe(true);
  });

  it("rejects a package without an id", () => {
    expect(
      getModelPackageValidationIssues({
        format: "onnx"
      }).some((issue) => issue.path === "/" && issue.keyword === "required")
    ).toBe(true);
  });

  it("rejects an unsupported model source type", () => {
    expect(
      getModelPackageValidationIssues({
        id: "phi-3-mini",
        format: "onnx",
        source: { sourceType: "torrent" }
      }).some((issue) => issue.path === "/source/sourceType")
    ).toBe(true);
  });

  it("rejects inline secrets in a model source", () => {
    expect(
      getModelPackageValidationIssues({
        id: "phi-3-mini",
        format: "onnx",
        source: { sourceType: "remote", ref: "https://models.example", apiKey: "sk-test" }
      }).some((issue) => issue.keyword === "forbiddenSecretKey")
    ).toBe(true);
  });

  it("rejects URL userinfo credentials in a model source ref", () => {
    expect(
      getModelPackageValidationIssues({
        id: "phi-3-mini",
        format: "onnx",
        source: { sourceType: "registry", ref: "https://user:pass@models.example/org/model" }
      }).some((issue) => issue.path === "/source/ref" && issue.keyword === "pattern")
    ).toBe(true);
  });

  it("accepts credential-free source refs that contain '@' outside URL userinfo", () => {
    expect(
      validateModelPackage({
        id: "phi-3-mini",
        format: "onnx",
        source: { sourceType: "registry", ref: "https://models.example/org/model@v1" }
      })
    ).toBe(true);
  });
});

describe("Host-adjacent data validation", () => {
  it("accepts a normalized HTTP request with Authorization after secure storage resolution", () => {
    expect(
      validateHttpRequest({
        method: "POST",
        url: "https://api.example.test/v1/responses",
        headers: {
          Authorization: "Bearer resolved-secret"
        },
        body: "{}",
        timeoutMs: 1000
      })
    ).toBe(true);
  });

  it("rejects unsupported HTTP methods", () => {
    expect(
      getHttpRequestValidationIssues({
        method: "TRACE",
        url: "https://api.example.test"
      }).some((issue) => issue.path === "/method")
    ).toBe(true);
  });

  it("accepts a normalized HTTP response", () => {
    expect(
      validateHttpResponse({
        status: 200,
        statusText: "OK",
        headers: { "content-type": "application/json" },
        body: "{}"
      })
    ).toBe(true);
  });

  it("rejects invalid HTTP status codes", () => {
    expect(
      getHttpResponseValidationIssues({
        status: 99,
        statusText: "Invalid",
        headers: {},
        body: ""
      }).some((issue) => issue.path === "/status")
    ).toBe(true);
  });

  it("accepts a normalized telemetry event", () => {
    expect(
      validateTelemetryEvent({
        type: "route_decided",
        runId: "run_123",
        timestamp: 123,
        payload: { selectedProviderId: "openai" }
      })
    ).toBe(true);
  });

  it("rejects unsupported telemetry event types", () => {
    expect(
      getTelemetryEventValidationIssues({
        type: "unknown_event",
        runId: "run_123",
        timestamp: 123,
        payload: {}
      }).some((issue) => issue.path === "/type")
    ).toBe(true);
  });
});

describe("StreamRunHandle validation", () => {
  it("accepts a minimal handle", () => {
    expect(
      validateStreamRunHandle({
        schemaVersion: "1.0",
        runId: "run_123",
        startedAt: 1000
      })
    ).toBe(true);
  });

  it("accepts a handle with a resolved providerId", () => {
    expect(
      validateStreamRunHandle({
        schemaVersion: "1.0",
        runId: "run_123",
        startedAt: 1000,
        providerId: "openai_compatible_cloud"
      })
    ).toBe(true);
  });

  it("rejects a handle missing runId", () => {
    expect(
      getStreamRunHandleValidationIssues({
        schemaVersion: "1.0",
        startedAt: 1000
      }).some((issue) => issue.path === "/" && issue.keyword === "required")
    ).toBe(true);
  });
});

describe("StreamEvent validation", () => {
  it("accepts a minimal content_delta event", () => {
    expect(
      validateStreamEvent({
        schemaVersion: "1.0",
        runId: "run_123",
        sequence: 0,
        timestamp: 1000,
        type: "content_delta",
        payload: { text: "Hel" }
      })
    ).toBe(true);
  });

  it("accepts a content_snapshot event", () => {
    expect(
      validateStreamEvent({
        schemaVersion: "1.0",
        runId: "run_123",
        sequence: 1,
        timestamp: 1001,
        type: "content_snapshot",
        payload: { text: "Hello" }
      })
    ).toBe(true);
  });

  it("accepts a lifecycle event", () => {
    expect(
      validateStreamEvent({
        schemaVersion: "1.0",
        runId: "run_123",
        sequence: 0,
        timestamp: 999,
        type: "lifecycle",
        payload: { phase: "provider_selected" }
      })
    ).toBe(true);
  });

  it("accepts a terminal event with a completed outcome", () => {
    expect(
      validateStreamEvent({
        schemaVersion: "1.0",
        runId: "run_123",
        sequence: 2,
        timestamp: 1002,
        type: "terminal",
        payload: {
          schemaVersion: "1.0",
          runId: "run_123",
          outcome: "completed",
          finalText: "Hello",
          telemetry: { providerUsed: "openai", totalMs: 42 }
        }
      })
    ).toBe(true);
  });

  it("accepts a terminal event whose completed payload carries finishReason", () => {
    expect(
      validateStreamEvent({
        schemaVersion: "1.0",
        runId: "run_123",
        sequence: 2,
        timestamp: 1002,
        type: "terminal",
        payload: {
          schemaVersion: "1.0",
          runId: "run_123",
          outcome: "completed",
          finalText: "Hello",
          finishReason: "stop",
          telemetry: { providerUsed: "openai", totalMs: 42 }
        }
      })
    ).toBe(true);
  });

  it("accepts an event with an unrecognized type (forward-compatible)", () => {
    expect(
      validateStreamEvent({
        schemaVersion: "1.0",
        runId: "run_123",
        sequence: 3,
        timestamp: 1003,
        type: "some_future_event",
        payload: { anything: true }
      })
    ).toBe(true);
  });

  it("rejects an event missing sequence, runId, or schemaVersion", () => {
    expect(
      getStreamEventValidationIssues({
        timestamp: 1000,
        type: "content_delta",
        payload: { text: "Hi" }
      }).some((issue) => issue.path === "/" && issue.keyword === "required")
    ).toBe(true);
  });

  it("rejects a content_delta event missing the required payload.text field", () => {
    expect(
      getStreamEventValidationIssues({
        schemaVersion: "1.0",
        runId: "run_123",
        sequence: 0,
        timestamp: 1000,
        type: "content_delta",
        payload: {}
      }).length
    ).toBeGreaterThan(0);
  });
});

describe("StreamTerminalOutcome validation", () => {
  it("accepts a completed outcome", () => {
    expect(
      validateStreamTerminalOutcome({
        schemaVersion: "1.0",
        runId: "run_123",
        outcome: "completed",
        finalText: "Hello",
        usage: { inputTokens: 2, outputTokens: 1, totalTokens: 3 },
        telemetry: { providerUsed: "openai", totalMs: 42 }
      })
    ).toBe(true);
  });

  it("accepts a completed outcome carrying finishReason", () => {
    expect(
      validateStreamTerminalOutcome({
        schemaVersion: "1.0",
        runId: "run_123",
        outcome: "completed",
        finalText: "Hello",
        finishReason: "length",
        telemetry: { providerUsed: "openai", totalMs: 42 }
      })
    ).toBe(true);
  });

  it("rejects a completed outcome with an unknown finishReason", () => {
    expect(
      validateStreamTerminalOutcome({
        schemaVersion: "1.0",
        runId: "run_123",
        outcome: "completed",
        finalText: "Hello",
        finishReason: "truncated",
        telemetry: { providerUsed: "openai", totalMs: 42 }
      })
    ).toBe(false);
  });

  it("accepts an error outcome", () => {
    expect(
      validateStreamTerminalOutcome({
        schemaVersion: "1.0",
        runId: "run_123",
        outcome: "error",
        error: {
          schemaVersion: "1.0",
          errorClass: "Timeout",
          message: "Provider timed out"
        }
      })
    ).toBe(true);
  });

  it("accepts a cancelled outcome", () => {
    expect(
      validateStreamTerminalOutcome({
        schemaVersion: "1.0",
        runId: "run_123",
        outcome: "cancelled",
        partialText: "Hel",
        reason: "caller aborted"
      })
    ).toBe(true);
  });

  it("accepts a cancelled outcome with empty partialText", () => {
    expect(
      validateStreamTerminalOutcome({
        schemaVersion: "1.0",
        runId: "run_123",
        outcome: "cancelled",
        partialText: ""
      })
    ).toBe(true);
  });

  it("rejects a completed outcome missing finalText", () => {
    expect(
      validateStreamTerminalOutcome({
        schemaVersion: "1.0",
        runId: "run_123",
        outcome: "completed",
        telemetry: { providerUsed: "openai", totalMs: 42 }
      })
    ).toBe(false);
  });

  it("rejects an error outcome missing the required error field", () => {
    expect(
      validateStreamTerminalOutcome({
        schemaVersion: "1.0",
        runId: "run_123",
        outcome: "error"
      })
    ).toBe(false);
  });

  it("rejects a cancelled outcome missing the required partialText field", () => {
    expect(
      validateStreamTerminalOutcome({
        schemaVersion: "1.0",
        runId: "run_123",
        outcome: "cancelled"
      })
    ).toBe(false);
  });

  it("rejects an unrecognized outcome value", () => {
    expect(
      validateStreamTerminalOutcome({
        schemaVersion: "1.0",
        runId: "run_123",
        outcome: "partial_success",
        finalText: "Hello"
      })
    ).toBe(false);
  });

  it("keeps the error branch structurally identical to IndeRunError (cross-check)", () => {
    const errorFixture = {
      schemaVersion: "1.0" as const,
      errorClass: "RateLimited" as const,
      message: "Too many requests",
      retryable: true,
      retryAfterMs: 500
    };

    expect(validateIndeRunError(errorFixture)).toBe(true);
    expect(
      validateStreamTerminalOutcome({
        schemaVersion: "1.0",
        runId: "run_123",
        outcome: "error",
        error: errorFixture
      })
    ).toBe(true);
  });
});
