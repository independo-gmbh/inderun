import { describe, it, expect } from "vitest";
import { EventGate } from "./event-gate.js";

function completedOutcome(text: string) {
  return {
    outcome: "completed" as const,
    runId: "run_1",
    schemaVersion: "1.0" as const,
    finalText: text
  };
}

function cancelledOutcome(partialText: string) {
  return {
    outcome: "cancelled" as const,
    runId: "run_1",
    schemaVersion: "1.0" as const,
    partialText
  };
}

describe("EventGate", () => {
  it("admits events before termination", () => {
    const gate = new EventGate("run_1");
    const event = gate.admit({ timestamp: 1, type: "content_delta", payload: { text: "hi" } });
    expect(event).not.toBeNull();
    expect(event?.sequence).toBe(0);
    expect(event?.runId).toBe("run_1");
  });

  it("first terminate() call wins; getOutcome() stays stable", () => {
    const gate = new EventGate("run_1");
    const first = gate.terminate(completedOutcome("hello"), 10);
    const second = gate.terminate(cancelledOutcome("h"), 20);

    expect(first).not.toBeNull();
    expect(second).toBeNull();
    expect(gate.getOutcome()).toEqual(completedOutcome("hello"));
    expect(gate.isTerminated()).toBe(true);
  });

  it("suppresses admit() after termination", () => {
    const gate = new EventGate("run_1");
    gate.terminate(completedOutcome("hello"), 10);
    const late = gate.admit({ timestamp: 11, type: "content_delta", payload: { text: "late" } });
    expect(late).toBeNull();
  });

  it("same-tick concurrent terminate() calls: exactly one succeeds", () => {
    const gate = new EventGate("run_1");
    const results = [
      gate.terminate(completedOutcome("a"), 1),
      gate.terminate(completedOutcome("b"), 2),
      gate.terminate(completedOutcome("c"), 3)
    ];
    const succeeded = results.filter((r) => r !== null);
    expect(succeeded).toHaveLength(1);
    expect(gate.getOutcome()).toEqual(completedOutcome("a"));
  });

  it("assigns strictly monotonic sequence numbers across interleaved admit/terminate", () => {
    const gate = new EventGate("run_1");
    const e0 = gate.admit({ timestamp: 1, type: "lifecycle" });
    const e1 = gate.admit({ timestamp: 2, type: "content_delta", payload: { text: "a" } });
    const e2 = gate.terminate(completedOutcome("a"), 3);

    expect([e0?.sequence, e1?.sequence, e2?.sequence]).toEqual([0, 1, 2]);
  });
});
