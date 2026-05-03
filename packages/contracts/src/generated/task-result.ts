/* This file was generated from JSON Schema. Do not edit by hand. */

/**
 * Milestone-1 text-to-text result contract for Mode 1 run().
 */
export interface TaskResult {
  schemaVersion: "1.0";
  runId: string;
  output: {
    type: "text";
    text: string;
    [k: string]: unknown;
  };
  finishReason: "stop" | "length" | "cancelled" | "error";
  usage?: {
    inputTokens?: number;
    outputTokens?: number;
    totalTokens?: number;
    [k: string]: unknown;
  };
  telemetry: {
    providerUsed: string;
    totalMs: number;
    errorClass?:
      | "CapabilityMismatch"
      | "Offline"
      | "AuthError"
      | "RateLimited"
      | "Timeout"
      | "Unavailable"
      | "Internal";
    [k: string]: unknown;
  };
  [k: string]: unknown;
}
