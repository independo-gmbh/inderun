import type { StreamEvent } from "@independo/inderun-contracts";

import type { StreamRun } from "./provider.js";

/**
 * Tracks what an engine has in flight so `close()` can stop and await it.
 *
 * Streams and prepares are tracked through their event iterators: a run is busy exactly while
 * a `next()` call is pending, which is when its provider is doing work. A stream that nobody is
 * pulling is idle; its cancel flag is already set, so the next pull ends it with the standard
 * cancelled terminal, and close does not wait for a consumer that has stopped reading.
 */
export class InFlight {
  private readonly cancels = new Set<(reason: string) => void>();
  private readonly busy = new Set<Promise<void>>();
  private readonly work = new Set<Promise<unknown>>();

  /** Tracks a Mode 1 call (or a stream/prepare still routing) until it settles. */
  track<T>(promise: Promise<T>): Promise<T> {
    const settled = promise.then(
      () => undefined,
      () => undefined
    );
    this.work.add(settled);
    void settled.then(() => this.work.delete(settled));
    return promise;
  }

  /** Wraps a stream or prepare handle so close can cancel it and wait for pending pulls. */
  trackRun(run: StreamRun): StreamRun {
    const inner = run.events[Symbol.asyncIterator]();
    const cancel = (reason: string) => run.cancel(reason);
    this.cancels.add(cancel);
    const pull = <R>(call: () => Promise<R>): Promise<R> => {
      const pending = call();
      const settled = pending.then(
        () => undefined,
        () => undefined
      );
      this.busy.add(settled);
      void settled.then(() => this.busy.delete(settled));
      return pending;
    };
    const finish = (result: IteratorResult<StreamEvent>): IteratorResult<StreamEvent> => {
      // The terminal event ends the stream: nothing is left to cancel once it has been yielded.
      if (result.done === true || result.value.type === "terminal") this.cancels.delete(cancel);
      return result;
    };
    const events: AsyncGenerator<StreamEvent> = {
      next: (...args) => pull(() => inner.next(...args)).then(finish),
      return: (value) =>
        pull(() => inner.return!(value)).then((result) => {
          this.cancels.delete(cancel);
          return result;
        }),
      throw: (error) =>
        pull(() => inner.throw!(error)).then(finish, (thrown: unknown) => {
          this.cancels.delete(cancel);
          throw thrown;
        }),
      [Symbol.asyncIterator]() {
        return events;
      },
      [Symbol.asyncDispose]: async () => {
        await events.return(undefined);
      }
    };
    return { handle: run.handle, events, cancel: run.cancel };
  }

  /** Cancels every tracked stream and prepare. */
  cancelAll(reason: string): void {
    for (const cancel of [...this.cancels]) cancel(reason);
  }

  /** Resolves once no tracked call is pending. Looks again, because settling can start more. */
  async settled(): Promise<void> {
    while (this.work.size > 0 || this.busy.size > 0) {
      await Promise.all([...this.work, ...this.busy]);
    }
  }
}
