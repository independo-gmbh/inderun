import Foundation
import IndeRunContracts

/// Counts scheduled and played-back buffers for one session and parks writers and drainers.
///
/// A writer `reserve()`s a slot before scheduling its buffer and parks while `limit` slots are
/// taken; each played-back buffer frees one. A drainer parks until every scheduled buffer has
/// played back. A parked caller whose task is cancelled throws `CancellationError`. `end(_:)`
/// settles every waiter, and every later call returns (or throws the ending error) at once.
/// Each continuation is resumed exactly once.
actor AudioOutputGate {
    private enum Queue { case writers, drainers }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let limit: Int
    /// Slots handed to writers: a writer holds its slot from `reserve()` until its buffer plays back.
    private var reserved = 0
    private var scheduled = 0
    private var played = 0
    private var writers: [Waiter] = []
    private var drainers: [Waiter] = []
    private var ended = false
    private var endError: IndeRunException?

    init(limit: Int = 3) {
        self.limit = limit
    }

    /// Returns once fewer than `limit` buffers are in flight; at once after `end`.
    func reserve() async throws {
        if ended { return try settleEnded() }
        try Task.checkCancellation()
        if reserved - played < limit {
            reserved += 1
            return
        }
        try await park(in: .writers)
    }

    func markScheduled() {
        scheduled += 1
    }

    func markPlayedBack() {
        guard !ended, played < scheduled else { return }
        played += 1
        while !writers.isEmpty, reserved - played < limit {
            reserved += 1
            writers.removeFirst().continuation.resume()
        }
        if played == scheduled { settleAll(.drainers, with: .success(())) }
    }

    /// Returns once played == scheduled; at once after `end`.
    func awaitDrained() async throws {
        if ended { return try settleEnded() }
        try Task.checkCancellation()
        if played == scheduled { return }
        try await park(in: .drainers)
    }

    /// Settles every waiter: throwing `error` when given, returning otherwise. Idempotent.
    func end(_ error: IndeRunException?) {
        guard !ended else { return }
        ended = true
        endError = error
        let result: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
        settleAll(.writers, with: result)
        settleAll(.drainers, with: result)
    }

    private func settleEnded() throws {
        if let endError { throw endError }
    }

    private func park(in queue: Queue) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // A cancellation that landed before this point found nothing to remove.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                append(Waiter(id: id, continuation: continuation), to: queue)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func append(_ waiter: Waiter, to queue: Queue) {
        switch queue {
        case .writers: writers.append(waiter)
        case .drainers: drainers.append(waiter)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        if let index = writers.firstIndex(where: { $0.id == id }) {
            writers.remove(at: index).continuation.resume(throwing: CancellationError())
        } else if let index = drainers.firstIndex(where: { $0.id == id }) {
            drainers.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    private func settleAll(_ queue: Queue, with result: Result<Void, Error>) {
        let pending: [Waiter]
        switch queue {
        case .writers:
            pending = writers
            writers.removeAll()
        case .drainers:
            pending = drainers
            drainers.removeAll()
        }
        for waiter in pending { waiter.continuation.resume(with: result) }
    }
}
