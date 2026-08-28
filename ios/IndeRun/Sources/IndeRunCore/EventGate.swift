import Foundation
import IndeRunContracts

/// Per-run gatekeeper for Mode 2 streaming. Enforces the two structural
/// guarantees the streaming orchestrator depends on: exactly one terminal
/// outcome is ever produced for a run, and no event is admitted after it.
///
/// Unlike the Web SDK's gate, which relies on JavaScript's run-to-completion
/// semantics, this one is explicitly locked: a provider's production task and a
/// caller's `cancel()` genuinely run on different threads here, and first-writer-
/// wins termination is only meaningful if the check-and-set is atomic.
public final class EventGate: @unchecked Sendable {
    private let lock = NSLock()
    private let runId: String
    private var sequence = 0
    private var terminated = false
    private var terminalOutcome: StreamTerminalOutcome?

    public init(runId: String) {
        self.runId = runId
    }

    /// Admits a non-terminal event, assigning the next monotonic sequence number.
    /// Returns `nil` — suppressing the event — once the run has terminated.
    public func admit(timestamp: Double, type: String, payload: Payload?) -> StreamEvent? {
        lock.lock()
        defer { lock.unlock() }
        if terminated { return nil }

        let next = sequence
        sequence += 1
        return StreamEvent(
            payload: payload,
            runId: runId,
            schemaVersion: .the10,
            sequence: next,
            timestamp: timestamp,
            type: type
        )
    }

    /// Terminates the run. First writer wins: only the first call produces a
    /// terminal event and records the outcome. Every later call — a duplicate
    /// provider `done`, a late error after cancellation, concurrent `cancel()`
    /// calls — is a silent no-op, which is what makes repeated cancellation safe.
    public func terminate(outcome: StreamTerminalOutcome, timestamp: Double) -> StreamEvent? {
        lock.lock()
        defer { lock.unlock() }
        if terminated { return nil }

        terminated = true
        terminalOutcome = outcome

        let next = sequence
        sequence += 1
        return StreamEvent(
            payload: Payload(terminalOutcome: outcome),
            runId: runId,
            schemaVersion: .the10,
            sequence: next,
            timestamp: timestamp,
            type: "terminal"
        )
    }

    public var isTerminated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminated
    }

    public var outcome: StreamTerminalOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return terminalOutcome
    }
}
