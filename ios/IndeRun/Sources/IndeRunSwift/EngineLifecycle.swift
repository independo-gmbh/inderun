import Foundation
import IndeRunCore
import IndeRunContracts

/// What an engine has in flight, so `close()` can stop and await it (see `IndeRunApi.close`).
///
/// Every `run`, `stream` and `prepare` call holds one unit of work from entry until its work is
/// over: for a run, until it returns; for a stream or prepare, until the task driving it has
/// delivered its terminal event. A stream nobody is reading is still driven to that terminal event
/// (events buffer), so close never waits for a consumer. Streams and prepares also register a
/// cancel hook; runs register none, because Mode 1 has no cancel path and close adds none.
final class EngineLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var busy = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancels: [Int: @Sendable (String) -> Void] = [:]
    private var nextCancelId = 0
    private var closing: Task<Void, Never>?

    static let closedMessage = "The engine is closed."
    static let cancelReason = "The engine was closed."

    static func closedError(runId: String? = nil) -> IndeRunException {
        createUnavailable(
            message: closedMessage,
            runId: runId,
            retryable: false,
            details: ["code": JSONAny("engine_closed")]
        )
    }

    /// Whether `close()` has begun.
    var isClosed: Bool { lock.withLock { closed } }

    /// Starts one unit of work; `false` once the engine is closed, and the caller must then fail.
    func begin() -> Bool {
        lock.withLock {
            if closed { return false }
            busy += 1
            return true
        }
    }

    /// Ends one unit of work started with `begin()`.
    func end() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            busy -= 1
            guard busy == 0 else { return [] }
            defer { idleWaiters = [] }
            return idleWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Registers a stream or prepare's cancel hook. If close already began, the hook fires at
    /// once, so a stream that was still routing ends in one cancelled terminal.
    func register(cancel: @escaping @Sendable (String) -> Void) -> Int {
        let (id, alreadyClosed): (Int, Bool) = lock.withLock {
            let id = nextCancelId
            nextCancelId += 1
            if !closed { cancels[id] = cancel }
            return (id, closed)
        }
        if alreadyClosed { cancel(Self.cancelReason) }
        return id
    }

    func unregister(_ id: Int) {
        lock.withLock { _ = cancels.removeValue(forKey: id) }
    }

    /// Runs the close sequence once: the closed flag is set first, then streams and prepares are
    /// cancelled, then the call waits for all work to end, then `afterIdle` runs. A second or
    /// concurrent call awaits the first.
    func close(afterIdle: @escaping @Sendable () -> Void) async {
        let task: Task<Void, Never> = lock.withLock {
            if let closing { return closing }
            closed = true
            let hooks = Array(cancels.values)
            cancels = [:]
            let task = Task { [self] in
                for hook in hooks { hook(Self.cancelReason) }
                await waitUntilIdle()
                afterIdle()
            }
            closing = task
            return task
        }
        await task.value
    }

    private func waitUntilIdle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let idle: Bool = lock.withLock {
                if busy == 0 { return true }
                idleWaiters.append(continuation)
                return false
            }
            if idle { continuation.resume() }
        }
    }
}
