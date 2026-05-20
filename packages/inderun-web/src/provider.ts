import type { TaskRequest, TaskResult } from "@independo/inderun-contracts";
import type { HostServices } from "./host.js";

/**
 * Static metadata descriptor defining the capabilities, requirements, and constraints
 * of a provider. This is used by the PolicyEngine and Router to select candidate providers.
 */
export interface ProviderDescriptor {
  /**
   * Unique identifier of the provider (e.g., 'openai', 'apple-foundation-models').
   */
  id: string;
  /**
   * Execution target type: 'local' (on-device), 'edge', or 'cloud'.
   */
  type: "local" | "edge" | "cloud";
  /**
   * Connection transport layer protocol.
   */
  transport: "in_process" | "system_service" | "http" | "sse" | "realtime";
  /**
   * Optional streaming style, if token or chunk streaming is supported.
   */
  streamingStyle?: "tokens" | "chunks" | "snapshots";

  /**
   * Flags representing the features and modes supported by this provider.
   */
  supports: {
    /** Whether the provider supports Mode 1 run (request/response). */
    run: boolean;
    /** Whether the provider supports Mode 2 stream. */
    streaming: boolean;
    /** Whether the provider supports Mode 3 realtime session. */
    realtime: boolean;
    /** Whether the provider supports tool calling definition. */
    tools: boolean;
    /** Whether the provider outputs reasoning events alongside contents. */
    reasoningEvents: boolean;
    /** Whether the provider supports structured outputs (JSON schema constraints). */
    structuredOutput: boolean;
    /** Whether the provider supports multimodal inputs (images, audio, etc.). */
    multimodal: boolean;
  };

  /**
   * Cancellation capabilities support:
   * - 'hard': fully stops processing and interrupts remote operations.
   * - 'soft': stops reading the stream locally, but the remote execution continues.
   * - 'none': cancellation is unsupported.
   */
  cancel: "hard" | "soft" | "none";

  /**
   * List of supported task kinds (e.g., 'text_to_text', 'embeddings').
   */
  tasks: string[];

  /**
   * Optional input/output resource boundaries.
   */
  limits?: {
    maxInputTokens?: number;
    maxOutputTokens?: number;
    maxImageBytes?: number;
    maxAudioSeconds?: number;
  };

  /**
   * Privacy settings regarding data egress.
   */
  privacy?: {
    /** Set to true if the model input leaves the host device. */
    dataLeavesDevice: boolean;
    /** Geographic regions where the cloud service executes. */
    regions?: string[];
  };
}

/**
 * Dynamic capability snapshot evaluated at runtime.
 */
export interface ProviderDynamicCapabilities {
  /**
   * Whether the provider is available and functional on the host device now.
   */
  available: boolean;
  /**
   * Detail message if availability check fails.
   */
  reason?: string;
}

/**
 * Execution context passed to provider run commands.
 */
export interface RunContext {
  /**
   * Unique execution run ID.
   */
  runId: string;
  /**
   * Host service boundary for provider adapters. Cloud adapters use this to
   * resolve authContextRef through secure storage and dispatch HTTP requests.
   */
  hostServices: HostServices;
}

/**
 * Pluggable execution adapter contract that wraps a specific model runtime
 * (system frameworks, local runtimes, or cloud APIs) and exposes normalized APIs.
 */
export interface ProviderAdapter {
  /**
   * Returns static provider descriptor metadata.
   */
  describe(): ProviderDescriptor;
  /**
   * Performs dynamic capability check to determine if the provider can execute now.
   */
  capabilities(host: HostServices): Promise<ProviderDynamicCapabilities>;
  /**
   * Executes a task request in Mode 1 (request/response).
   */
  run(req: TaskRequest, ctx: RunContext): Promise<TaskResult>;
}
