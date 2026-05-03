import { describe, expect, it } from "vitest";

import {
  getIndeRunErrorValidationIssues,
  getTaskRequestValidationIssues,
  validateIndeRunError,
  validateTaskRequest,
  validateTaskResult
} from "./index.js";

describe("TaskRequest validation", () => {
  it("accepts a minimal text-to-text prompt request", () => {
    expect(
      validateTaskRequest({
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "Summarize this.",
        policy: { execution: "cloud" }
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
        policy: { execution: "on_device", futurePolicyHint: "ignored" },
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
        policy: { execution: "cloud" }
      }).some((issue) => issue.path === "/schemaVersion")
    ).toBe(true);
  });

  it("rejects unsupported policy execution values", () => {
    expect(
      getTaskRequestValidationIssues({
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "Hello",
        policy: { execution: "edge" }
      }).some((issue) => issue.path === "/policy/execution")
    ).toBe(true);
  });

  it("rejects requests without prompt or messages", () => {
    expect(
      getTaskRequestValidationIssues({
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        policy: { execution: "cloud" }
      }).some((issue) => issue.keyword === "anyOf")
    ).toBe(true);
  });

  it("rejects inline secret-like fields even when unknown fields are allowed", () => {
    expect(
      getTaskRequestValidationIssues({
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "Hello",
        policy: { execution: "cloud" },
        apiKey: "sk-test"
      }).some((issue) => issue.keyword === "forbiddenSecretKey")
    ).toBe(true);
  });

  it("rejects common inline secret key variants", () => {
    const issues = getTaskRequestValidationIssues({
      schemaVersion: "1.0",
      task: { kind: "text_to_text" },
      prompt: "Hello",
      policy: { execution: "cloud" },
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
        policy: { execution: "cloud" },
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
