import type {
  ProviderDescriptor,
  ProviderDynamicCapabilities,
  SharedRoutePlan,
  StreamEvent,
  StreamRunHandle,
  TaskOutput,
  TaskRequest,
  TaskResult
} from "@independo/inderun-contracts";
import type { HostServices } from "./host.js";

/**
 * A provider's static declaration, live capability check, and the pair as
 * `checkCapabilities()` returns it. All three are schema-backed contracts
 * (`contracts/schemas/provider-*.schema.json`), shared with the Swift and Kotlin
 * SDKs and with the route planner, so they are re-exported here rather than
 * declared.
 */
export type {
  ProviderCapabilitySnapshot,
  ProviderDescriptor,
  ProviderDynamicCapabilities
} from "@independo/inderun-contracts";

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
  /**
   * The voice the route plan bound this provider to for a speech task: provider-neutral
   * traits the provider must honour when it picks the voice that speaks. Absent for tasks
   * without a voice and for providers that do not list their voices, which then choose
   * under the same rule (ADR 016 §4). The engine has re-checked it against the request's
   * privacy policy immediately before the attempt.
   */
  voice?: NonNullable<SharedRoutePlan["candidates"][number]["voice"]>;
  /**
   * Commits the run to this provider. Call it immediately before the attempt's first
   * externally observable effect — for managed playback, no later than the first moment
   * sound may reach the user. After commit, a failure ends the run instead of falling back
   * to another provider, because a second provider would repeat what the user may already
   * have heard.
   *
   * Returns `false` when the run can no longer commit (it was cancelled or has already
   * ended) and when this attempt is over, e.g. a late callback after the engine fell back to
   * another provider; the provider must then not start the effect and should end the attempt.
   * Idempotent: calling it again after a successful commit returns `true`.
   *
   * Providers whose output is only delivered at the end (text from `run()`) need not call
   * it. Text streams commit implicitly on their first content event.
   */
  commit(): boolean;
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
  | {
      kind: "done";
      finalText: string;
      /**
       * How generation ended, when the provider reports it. Mirrors
       * `TaskResult.finishReason` for Mode 1 and surfaces on the `completed`
       * terminal outcome; omit when the provider gives no signal.
       */
      finishReason?: TaskResult["finishReason"];
      usage?: TaskResult["usage"];
      /**
       * The model identifier the provider's backend reported for this run, when it reports
       * one. Carried into the terminal outcome's provenance; never inferred from configuration.
       */
      reportedModel?: string;
    }
  | {
      /**
       * The run's normalized output, for tasks whose output is not streamed text
       * (playback completion, a media artifact). Ends the stream like `done`; handing it
       * over commits the run if the provider has not already called `commit()`.
       */
      kind: "result";
      output: TaskOutput;
      finishReason?: TaskResult["finishReason"];
      reportedModel?: string;
    }
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

/**
 * What `IndeRun.stream()` returns: the run's identity, its canonical event
 * sequence, and a cancel hook.
 *
 * `events` terminates in exactly one terminal `StreamEvent`, per the Event
 * Gate's guarantee, and is single-use — the run is driven once, not restarted
 * per consumer. `cancel()` is idempotent: repeated or concurrent calls produce
 * exactly one `cancelled` terminal outcome.
 */
export interface StreamRun {
  handle: StreamRunHandle;
  events: AsyncIterable<StreamEvent>;
  cancel(reason?: string): void;
}
