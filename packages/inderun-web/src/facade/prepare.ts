import type {
  ExecutionProvenance,
  PrepareRequest,
  StreamTerminalOutcome,
  TaskOutput
} from "@independo/inderun-contracts";
import { IndeRunException } from "../core/errors.js";
import type { IndeRunApi } from "../core/generated/inderun-api.js";
import { exceptionFromOutcome } from "./text.js";

/** What {@link prepare} reports for one provider and task. */
export type PreparationItem = NonNullable<TaskOutput["preparation"]>[number];

/** Options for {@link prepare}. Everything is optional. */
export interface PrepareOptions extends PrepareRequest {
  /** Called as an item advances, with a fraction from 0 to 1 when the platform has one. */
  onProgress?: (progress: { providerId: string; task: string; fractionCompleted?: number }) => void;
}

/** How a {@link prepare} run ended. One failed item does not fail the run. */
export interface PreparationResult {
  /** `"cancelled"` when it was stopped; otherwise `"stop"`. */
  finishReason: "stop" | "cancelled";
  items: PreparationItem[];
  runId: string;
  provenance?: ExecutionProvenance;
  outcome: StreamTerminalOutcome;
}

/** What {@link prepare} returns: a handle on a preparation in progress. */
export interface Preparation {
  runId: string;
  /** Resolves when done or stopped. Rejects only when the run itself fails. */
  result: Promise<PreparationResult>;
  /** Stops waiting; idempotent. A platform download already started may go on. */
  cancel(reason?: string): void;
}

/**
 * Makes registered providers ready ahead of a run. Optional, for applications that want the first
 * call to be fast or want to show progress: without it, the first run of a task waits for what is
 * loading by itself. A download starts only where `autoDownload` at registration or `allowDownload`
 * here permits it. See ADR 019.
 * @throws {IndeRunException} Exactly as `IndeRunApi.prepare()` does.
 */
export async function prepare(
  inderun: IndeRunApi,
  options: PrepareOptions = {}
): Promise<Preparation> {
  const { onProgress, ...request } = options;
  const run = await inderun.prepare(request);
  const runId = run.handle.runId;

  const result = (async (): Promise<PreparationResult> => {
    const events = run.events[Symbol.asyncIterator]();
    for (let next = await events.next(); next.done !== true; next = await events.next()) {
      const event = next.value;
      if (event.type === "preparation_progress") {
        onProgress?.(event.payload as Parameters<NonNullable<PrepareOptions["onProgress"]>>[0]);
      }
      if (event.type === "terminal") {
        void events.return?.()?.catch(() => undefined);
        const outcome = event.payload as unknown as StreamTerminalOutcome;
        if (outcome.outcome === "error") throw exceptionFromOutcome(outcome);
        return {
          finishReason: outcome.outcome === "cancelled" ? "cancelled" : "stop",
          items: outcome.output?.preparation ?? [],
          runId,
          ...(outcome.provenance !== undefined ? { provenance: outcome.provenance } : {}),
          outcome
        };
      }
    }
    throw new IndeRunException({
      errorClass: "Internal",
      message: `Run ${runId} ended without a terminal event.`,
      runId
    });
  })();
  // A caller that only ever cancels must not leave an unhandled rejection behind.
  result.catch(() => undefined);

  return { runId, result, cancel: (reason?: string) => run.cancel(reason) };
}
