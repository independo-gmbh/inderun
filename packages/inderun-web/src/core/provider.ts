import type { TaskRequest, TaskResult } from "@independo/inderun-contracts";
import type { HostServices } from "./host.js";

/**
 * Static metadata descriptor defining the capabilities, requirements, and constraints
 * of a provider. This is used by the routing engine and Router to select candidate providers.
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
  /**
   * Whether the provider can stream (Mode 2) right now on this host. Leave
   * undefined to inherit the static `descriptor.supports.streaming` value —
   * only set it when the runtime environment can take streaming away from a
   * provider that otherwise declares it (e.g. the host has no chunked HTTP
   * capability).
   */
  streamingAvailable?: boolean;
  /**
   * Detail message used when `streamingAvailable` is false. Omit to let the
   * route planner synthesize a generic message.
   */
  streamingUnavailableReason?: string;
  /**
   * Whether cancellation is honored right now on this host. Leave undefined to
   * inherit the static `descriptor.cancel` value (anything other than `"none"`
   * means available).
   */
  cancellationAvailable?: boolean;
}

/**
 * One registered provider's identity, fixed capabilities, and live availability,
 * as of the moment checkCapabilities() was called.
 */
export interface ProviderCapabilitySnapshot {
  /**
   * Stable identifier for this provider, matching the value used in routing
   * preferences/constraints.
   */
  providerId: string;
  /**
   * The provider's static, unchanging capability declaration (supported modes,
   * privacy posture, model info).
   */
  descriptor: ProviderDescriptor;
  /**
   * The provider's current dynamic availability (e.g. whether it's reachable/loaded
   * right now) — this is the part that can change between calls.
   */
  capabilities: ProviderDynamicCapabilities;
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
 * Execution context passed to provider stream commands. Extends RunContext with the
 * caller-driven cancellation signal; the Engine core owns the AbortController and
 * threads its signal here, so providers never need to construct their own.
 */
export interface ProviderStreamContext extends RunContext {
  /**
   * Signals caller-driven cancellation of this stream. Providers with `cancel: "hard"`
   * should tear down their connection immediately on abort; `cancel: "soft"` providers
   * may stop relaying events without interrupting underlying local work; `cancel:
   * "none"` providers may ignore it entirely; the engine enforces the caller-visible
   * cancellation guarantee at the consumer loop regardless of what the provider does.
   */
  signal: AbortSignal;
}

/**
 * A raw, provider-shaped streaming event yielded by ProviderAdapter.stream(). This is
 * intentionally distinct from the canonical StreamEvent contract: providers emit
 * provider-shaped deltas here, and the Engine core's Event Gate normalizes these into
 * StreamEvent/StreamTerminalOutcome, keeping provider-specific mechanics from leaking
 * through the public API.
 */
export type ProviderStreamEvent =
  | { kind: "delta"; text: string }
  | { kind: "snapshot"; text: string }
  | { kind: "done"; finalText: string; usage?: TaskResult["usage"] }
  | { kind: "error"; error: unknown };

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
  /**
   * Executes a task request in Mode 2 (streaming). Optional: only providers declaring
   * `describe().supports.streaming === true` are expected to implement this.
   */
  stream?(req: TaskRequest, ctx: ProviderStreamContext): AsyncIterable<ProviderStreamEvent>;
}
