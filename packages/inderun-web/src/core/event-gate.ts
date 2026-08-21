import type { StreamEvent, StreamTerminalOutcome } from "@independo/inderun-contracts";

/**
 * Per-run gatekeeper for Mode 2 streaming. Enforces the two structural guarantees
 * required by the streaming orchestrator: exactly one terminal outcome is ever
 * produced for a run, and no event is admitted after that terminal outcome fires.
 *
 * Correctness relies on `admit`/`terminate` performing their check-and-set
 * synchronously with no `await` in between — safe under JS's single-threaded,
 * run-to-completion semantics even with interleaved `await` resumption elsewhere
 * (e.g. a provider's async iterator and a caller's `cancel()` racing).
 */
export class EventGate {
  private sequence = 0;
  private terminated = false;
  private terminalOutcome: StreamTerminalOutcome | undefined;

  constructor(private readonly runId: string) {}

  /**
   * Admits a non-terminal StreamEvent, assigning it the next monotonic sequence
   * number. Returns null (suppressing the event) if the run has already terminated.
   */
  admit(event: {
    timestamp: number;
    type: string;
    payload?: StreamEvent["payload"];
  }): StreamEvent | null {
    if (this.terminated) {
      return null;
    }
    return {
      runId: this.runId,
      schemaVersion: "1.0",
      sequence: this.sequence++,
      timestamp: event.timestamp,
      type: event.type,
      ...(event.payload !== undefined ? { payload: event.payload } : {})
    };
  }

  /**
   * Terminates the run with the given outcome. First writer wins: only the first
   * call produces a terminal StreamEvent and stores the outcome; every subsequent
   * call (duplicate provider "done", late error after cancel, concurrent cancel()
   * calls) is a silent no-op that returns null, making repeated cancellation safe.
   */
  terminate(outcome: StreamTerminalOutcome, timestamp: number): StreamEvent | null {
    if (this.terminated) {
      return null;
    }
    this.terminated = true;
    this.terminalOutcome = outcome;
    return {
      runId: this.runId,
      schemaVersion: "1.0",
      sequence: this.sequence++,
      timestamp,
      type: "terminal",
      payload: outcome
    };
  }

  isTerminated(): boolean {
    return this.terminated;
  }

  getOutcome(): StreamTerminalOutcome | undefined {
    return this.terminalOutcome;
  }
}
