import { readFileSync } from "node:fs";

import { describe, expect, it } from "vitest";

import {
  getExecutionProvenanceValidationIssues,
  getHttpRequestValidationIssues,
  getHttpResponseValidationIssues,
  getIndeRunErrorValidationIssues,
  getModelPackageValidationIssues,
  getProviderCapabilitySnapshotValidationIssues,
  getStreamEventValidationIssues,
  getStreamRunHandleValidationIssues,
  getStreamTerminalOutcomeValidationIssues,
  getTaskOutputValidationIssues,
  getTaskRequestValidationIssues,
  getTelemetryEventValidationIssues,
  validateExecutionProvenance,
  validateHttpRequest,
  validateHttpResponse,
  validateIndeRunError,
  validateModelPackage,
  validateProviderCapabilitySnapshot,
  validateProviderDescriptor,
  validateProviderDynamicCapabilities,
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

describe("TaskRequest per-task requirements (ADR 016)", () => {
  const speech = {
    schemaVersion: "1.0",
    task: { kind: "text_to_speech" },
    speech: { text: "Hallo", locale: "de-AT" },
    delivery: { mode: "playback" }
  };

  it("accepts a text_to_speech request with speech and delivery", () => {
    expect(getTaskRequestValidationIssues(speech)).toEqual([]);
  });

  it("requires speech and delivery for text_to_speech", () => {
    const issues = getTaskRequestValidationIssues({
      schemaVersion: "1.0",
      task: { kind: "text_to_speech" }
    });
    expect(issues.filter((issue) => issue.keyword === "required").map((i) => i.message)).toEqual(
      expect.arrayContaining([
        "must have required property 'speech'",
        "must have required property 'delivery'"
      ])
    );
  });

  it.each([
    ["prompt", { prompt: "Hello" }],
    ["messages", { messages: [{ role: "user", content: "Hello" }] }],
    ["generation", { generation: { temperature: 0.2 } }]
  ])("forbids %s on a text_to_speech request", (_name, extra) => {
    expect(validateTaskRequest({ ...speech, ...extra })).toBe(false);
  });

  it.each([
    ["speech", { speech: { text: "Hallo", locale: "de-AT" } }],
    ["delivery", { delivery: { mode: "playback" } }]
  ])("forbids %s on a text_to_text request", (_name, extra) => {
    expect(
      validateTaskRequest({
        schemaVersion: "1.0",
        task: { kind: "text_to_text" },
        prompt: "Hello",
        ...extra
      })
    ).toBe(false);
  });

  it("rejects inline delivery for text_to_speech", () => {
    expect(validateTaskRequest({ ...speech, delivery: { mode: "inline" } })).toBe(false);
  });

  it("accepts mediaTypes only with artifact delivery", () => {
    expect(
      validateTaskRequest({ ...speech, delivery: { mode: "artifact", mediaTypes: ["audio/wav"] } })
    ).toBe(true);
    expect(
      validateTaskRequest({ ...speech, delivery: { mode: "playback", mediaTypes: ["audio/wav"] } })
    ).toBe(false);
  });

  it("requires a trait on a required voice but not on a preferred one", () => {
    const withVoice = (voice: object) => ({ ...speech, speech: { ...speech.speech, voice } });
    expect(validateTaskRequest(withVoice({ requirement: "required" }))).toBe(false);
    expect(validateTaskRequest(withVoice({ requirement: "required", gender: "female" }))).toBe(
      true
    );
    expect(validateTaskRequest(withVoice({ requirement: "preferred" }))).toBe(true);
  });

  it("rejects an unknown task kind at /task/kind", () => {
    const issues = getTaskRequestValidationIssues({
      schemaVersion: "1.0",
      task: { kind: "text_to_video" },
      prompt: "A cat"
    });
    expect(issues.map((issue) => issue.path)).toContain("/task/kind");
  });
});

describe("TaskOutput validation", () => {
  it.each([
    ["text", { type: "text" }],
    ["playback", { type: "playback" }],
    ["artifact", { type: "artifact" }]
  ])("requires the %s payload for its type", (_name, output) => {
    expect(getTaskOutputValidationIssues(output).map((issue) => issue.keyword)).toContain(
      "required"
    );
  });

  it("accepts a playback output with the speech actually used", () => {
    expect(
      getTaskOutputValidationIssues({
        type: "playback",
        playback: { durationMs: 1200 },
        speech: { locale: "de-DE", voice: { gender: "female" } }
      })
    ).toEqual([]);
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

  it("rejects a completed outcome missing both finalText and output", () => {
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

  it("accepts a cancelled outcome carrying neither partialText nor output", () => {
    // An artifact run cancelled before handoff produced nothing to report.
    expect(
      validateStreamTerminalOutcome({
        schemaVersion: "1.0",
        runId: "run_123",
        outcome: "cancelled"
      })
    ).toBe(true);
  });

  it.each([
    [
      "completed",
      {
        output: {
          type: "artifact",
          artifact: {
            id: "art_1",
            mediaType: "audio/wav",
            owner: "engine",
            lifetime: "until_disposed",
            byteLength: 10
          }
        }
      }
    ],
    ["cancelled", { output: { type: "playback", playback: { durationMs: 640 } } }]
  ])(
    "accepts a %s outcome that carries a non-text output in both terminal copies",
    (outcome, payload) => {
      const terminal = { schemaVersion: "1.0", runId: "run_123", outcome, ...payload };
      expect(getStreamTerminalOutcomeValidationIssues(terminal)).toEqual([]);
      expect(
        getStreamEventValidationIssues({
          schemaVersion: "1.0",
          runId: "run_123",
          sequence: 3,
          timestamp: 1,
          type: "terminal",
          payload: terminal
        })
      ).toEqual([]);
    }
  );

  it("rejects a terminal output whose type lacks its payload in both copies", () => {
    const terminal = {
      schemaVersion: "1.0",
      runId: "run_123",
      outcome: "completed",
      output: { type: "playback" }
    };
    expect(validateStreamTerminalOutcome(terminal)).toBe(false);
    expect(
      validateStreamEvent({
        schemaVersion: "1.0",
        runId: "run_123",
        sequence: 0,
        timestamp: 1,
        type: "terminal",
        payload: terminal
      })
    ).toBe(false);
  });

  it("accepts the partialText an error outcome carries after commit", () => {
    expect(
      validateStreamTerminalOutcome({
        schemaVersion: "1.0",
        runId: "run_123",
        outcome: "error",
        partialText: "Hel",
        error: { schemaVersion: "1.0", errorClass: "Unavailable", message: "Provider failed" }
      })
    ).toBe(true);
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

describe("ExecutionProvenance validation", () => {
  const provenance = {
    schemaVersion: "1.0" as const,
    modelProfile: "auto",
    providerId: "openai:gpt-5.2",
    locality: "cloud" as const,
    configuredModel: "gpt-5.2",
    reportedModel: "gpt-5.2-2026-08-01",
    attemptCount: 2,
    fallbackOccurred: true,
    attempts: [
      {
        providerId: "local.onnx.genai.web",
        outcome: "failed" as const,
        errorClass: "Unavailable" as const
      },
      { providerId: "openai:gpt-5.2", outcome: "succeeded" as const }
    ],
    routeRejections: [
      { providerId: "local.system-model.web", codes: ["capability_unavailable" as const] }
    ]
  };

  it("accepts a fallback record with rejections", () => {
    expect(getExecutionProvenanceValidationIssues(provenance)).toEqual([]);
  });

  it("accepts the unknown-locality record of a run that reached no provider", () => {
    expect(
      validateExecutionProvenance({
        schemaVersion: "1.0",
        modelProfile: "smart",
        locality: "unknown",
        attemptCount: 0,
        fallbackOccurred: false,
        attempts: [],
        routeRejections: [{ providerId: "local_a", codes: ["not_in_model_profile"] }]
      })
    ).toBe(true);
  });

  it("rejects a locality outside the closed vocabulary", () => {
    expect(validateExecutionProvenance({ ...provenance, locality: "local" })).toBe(false);
  });

  it("rejects a record missing the attempt list", () => {
    const { attempts: _attempts, ...withoutAttempts } = provenance;
    expect(validateExecutionProvenance(withoutAttempts)).toBe(false);
  });

  it("is the same shape on every payload that carries it", () => {
    const invalid = { ...provenance, locality: "local" };
    const result = (value: object) => ({
      schemaVersion: "1.0" as const,
      runId: "run_123",
      output: { type: "text" as const, text: "Hi" },
      finishReason: "stop" as const,
      telemetry: { providerUsed: "openai:gpt-5.2", totalMs: 10 },
      provenance: value
    });
    const error = (value: object) => ({
      schemaVersion: "1.0" as const,
      errorClass: "Unavailable" as const,
      message: "All eligible providers failed.",
      provenance: value
    });
    const outcomes = (value: object) => [
      {
        schemaVersion: "1.0",
        runId: "run_123",
        outcome: "completed",
        finalText: "Hi",
        provenance: value
      },
      {
        schemaVersion: "1.0",
        runId: "run_123",
        outcome: "error",
        error: error(value),
        provenance: value
      },
      {
        schemaVersion: "1.0",
        runId: "run_123",
        outcome: "cancelled",
        partialText: "",
        provenance: value
      }
    ];
    const terminalEvent = (payload: object) => ({
      schemaVersion: "1.0",
      runId: "run_123",
      sequence: 0,
      timestamp: 1,
      type: "terminal",
      payload
    });

    expect(validateTaskResult(result(provenance))).toBe(true);
    expect(validateTaskResult(result(invalid))).toBe(false);
    expect(validateIndeRunError(error(provenance))).toBe(true);
    expect(validateIndeRunError(error(invalid))).toBe(false);
    for (const [valid, broken] of outcomes(provenance).map((outcome, index) => [
      outcome,
      outcomes(invalid)[index]!
    ])) {
      expect(validateStreamTerminalOutcome(valid)).toBe(true);
      expect(validateStreamTerminalOutcome(broken)).toBe(false);
      expect(validateStreamEvent(terminalEvent(valid!))).toBe(true);
      expect(validateStreamEvent(terminalEvent(broken!))).toBe(false);
    }
  });
});

type SnapshotFixtures = {
  valid: Array<{ id: string; snapshot: unknown }>;
  invalid: Array<{ id: string; path: string; snapshot: unknown }>;
};

const snapshotFixtures = JSON.parse(
  readFileSync(
    new URL("../../../contracts/fixtures/provider/capability-snapshots.json", import.meta.url),
    "utf8"
  )
) as SnapshotFixtures;

describe("ProviderCapabilitySnapshot validation", () => {
  for (const { id, snapshot } of snapshotFixtures.valid) {
    it(`accepts ${id}`, () => {
      expect(getProviderCapabilitySnapshotValidationIssues(snapshot)).toEqual([]);
    });
  }

  for (const { id, path, snapshot } of snapshotFixtures.invalid) {
    it(`rejects ${id} at ${path}`, () => {
      expect(validateProviderCapabilitySnapshot(snapshot)).toBe(false);
      expect(
        getProviderCapabilitySnapshotValidationIssues(snapshot).map((issue) => issue.path)
      ).toContain(path);
    });
  }

  it("validates the descriptor and dynamic capabilities on their own", () => {
    const [first] = snapshotFixtures.valid;
    const { descriptor, capabilities } = first!.snapshot as {
      descriptor: unknown;
      capabilities: unknown;
    };
    expect(validateProviderDescriptor(descriptor)).toBe(true);
    expect(validateProviderDynamicCapabilities(capabilities)).toBe(true);
    expect(
      validateProviderDynamicCapabilities({ available: true, cancellationAvailable: null })
    ).toBe(false);
  });
});
