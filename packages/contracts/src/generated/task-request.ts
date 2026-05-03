/* This file was generated from JSON Schema. Do not edit by hand. */

/**
 * Milestone-1 text-to-text request contract for Mode 1 run().
 */
export type TaskRequest = {
  [k: string]: unknown;
} & {
  schemaVersion: "1.0";
  requestId?: string;
  task: {
    kind: "text_to_text";
    [k: string]: unknown;
  };
  prompt?: string;
  /**
   * @minItems 1
   */
  messages?: [
    {
      role: "system" | "user" | "assistant";
      content: string;
      [k: string]: unknown;
    },
    ...{
      role: "system" | "user" | "assistant";
      content: string;
      [k: string]: unknown;
    }[]
  ];
  generation?: {
    maxOutputTokens?: number;
    temperature?: number;
    topP?: number;
    seed?: number;
    stop?: string[];
    [k: string]: unknown;
  };
  policy: {
    execution: "on_device" | "cloud";
    [k: string]: unknown;
  };
  telemetry?: {
    consent?: boolean;
    level?: "off" | "minimal" | "debug";
    tags?: {
      [k: string]: string;
    };
    [k: string]: unknown;
  };
  authContextRef?: string;
  [k: string]: unknown;
};
