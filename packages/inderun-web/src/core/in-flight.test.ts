import type { StreamEvent } from "@independo/inderun-contracts";
import { describe, expect, it } from "vitest";

import { InFlight } from "./in-flight.js";
import type { StreamRun } from "./provider.js";

function runYielding(events: StreamEvent[], cancel: (reason: string) => void): StreamRun {
  async function* generate(): AsyncGenerator<StreamEvent> {
    yield* events;
  }
  return { handle: {} as StreamRun["handle"], events: generate(), cancel };
}

const terminal = { type: "terminal", payload: { outcome: "completed" } } as unknown as StreamEvent;
const delta = { type: "delta" } as unknown as StreamEvent;

describe("InFlight", () => {
  it("drops a stream's cancel hook once its iterator has yielded the terminal event", async () => {
    const reasons: string[] = [];
    const flight = new InFlight();
    const tracked = flight.trackRun(runYielding([delta, terminal], (r) => reasons.push(r)));
    const iterator = tracked.events[Symbol.asyncIterator]();
    await iterator.next();
    await iterator.next();

    // The terminal has been delivered but the iterator is not yet done: nothing left to cancel.
    flight.cancelAll("closing");

    expect(reasons).toEqual([]);
  });

  it("still cancels a stream that has not yet delivered its terminal event", async () => {
    const reasons: string[] = [];
    const flight = new InFlight();
    const tracked = flight.trackRun(runYielding([delta, terminal], (r) => reasons.push(r)));
    await tracked.events[Symbol.asyncIterator]().next();

    flight.cancelAll("closing");

    expect(reasons).toEqual(["closing"]);
  });
});
