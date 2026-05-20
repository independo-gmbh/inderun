/* This file was generated from JSON Schema. Do not edit by hand. */

/**
 * Milestone-1 text-to-text request contract for Mode 1 run().
 */
export type TaskRequest = {
  [k: string]: unknown;
} & {
  /**
   * Contract schema version used to interpret the request payload.
   */
  schemaVersion: "1.0";
  /**
   * Optional caller-provided idempotency/debug identifier for this request.
   */
  requestId?: string;
  /**
   * Task descriptor used by routing and provider capability matching.
   */
  task: {
    /**
     * Milestone-1 task kind for text input to text output.
     */
    kind: "text_to_text";
    [k: string]: unknown;
  };
  /**
   * Single text prompt input for simple text-to-text execution.
   */
  prompt?: string;
  /**
   * Conversation-style text input for chat-like text-to-text execution.
   *
   * @minItems 1
   */
  messages?: [
    {
      /**
       * Role of the message author.
       */
      role: "system" | "user" | "assistant";
      /**
       * Text content for this message.
       */
      content: string;
      [k: string]: unknown;
    },
    ...{
      /**
       * Role of the message author.
       */
      role: "system" | "user" | "assistant";
      /**
       * Text content for this message.
       */
      content: string;
      [k: string]: unknown;
    }[]
  ];
  /**
   * Optional provider-neutral generation hints.
   */
  generation?: {
    /**
     * Optional upper bound for generated output tokens.
     */
    maxOutputTokens?: number;
    /**
     * Optional randomness hint where 0 is most deterministic and 2 is highest supported variance.
     */
    temperature?: number;
    /**
     * Optional nucleus sampling probability hint.
     */
    topP?: number;
    /**
     * Optional deterministic generation seed when supported by the provider.
     */
    seed?: number;
    /**
     * Optional stop sequences that should end generation when matched.
     */
    stop?: string[];
    [k: string]: unknown;
  };
  /**
   * Execution policy constraints used by the router.
   */
  policy: {
    /**
     * Required execution target for milestone routing.
     */
    execution: "on_device" | "cloud";
    [k: string]: unknown;
  };
  /**
   * Caller telemetry preferences for this request.
   */
  telemetry?: {
    /**
     * Whether the caller consents to telemetry collection for this request.
     */
    consent?: boolean;
    /**
     * Requested telemetry detail level.
     */
    level?: "off" | "minimal" | "debug";
    /**
     * Optional caller-provided non-secret labels for telemetry correlation.
     */
    tags?: {
      [k: string]: string;
    };
    [k: string]: unknown;
  };
  /**
   * Reference to a secure credential slot. Raw credentials must not be placed in the request.
   */
  authContextRef?: string;
  [k: string]: unknown;
};
