/* This file was generated from JSON Schema. Do not edit by hand. */

/**
 * Milestone-1 text-to-text result contract for Mode 1 run().
 */
export interface TaskResult {
  /**
   * Contract schema version used to interpret the result payload.
   */
  schemaVersion: "1.0";
  /**
   * Opaque run identifier assigned or normalized by the engine.
   */
  runId: string;
  /**
   * Normalized text output returned by the selected provider.
   */
  output: {
    /**
     * Output payload kind for milestone text-to-text execution.
     */
    type: "text";
    /**
     * Generated text returned to the caller.
     */
    text: string;
    [k: string]: unknown;
  };
  /**
   * Normalized reason why generation ended.
   */
  finishReason: "stop" | "length" | "cancelled" | "error";
  /**
   * Optional normalized token usage information reported by the provider.
   */
  usage?: {
    /**
     * Number of input tokens consumed, when reported by the provider.
     */
    inputTokens?: number;
    /**
     * Number of output tokens generated, when reported by the provider.
     */
    outputTokens?: number;
    /**
     * Total token count, when reported by the provider.
     */
    totalTokens?: number;
    [k: string]: unknown;
  };
  /**
   * Required minimal telemetry summary attached to every result.
   */
  telemetry: {
    /**
     * Identifier of the provider selected for the completed attempt.
     */
    providerUsed: string;
    /**
     * Total measured execution duration in milliseconds.
     */
    totalMs: number;
    /**
     * Optional normalized error class if the result represents a provider-level error outcome.
     */
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
