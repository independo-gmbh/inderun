import Foundation
import IndeRunContracts

/// Counts scheduled and played-back buffers for one session and parks writers and drainers.
///
/// A writer `reserve()`s a slot before scheduling its buffer and parks while `limit` slots are
/// taken; each played-back buffer frees one. A drainer parks until every scheduled buffer has
/// played back. A parked caller whose task is cancelled throws `CancellationError`. `end(_:)`
/// settles every waiter, and every later call returns (or throws the ending error) at once.
/// Each continuation is resumed exactly once.
///
/// Waits are bounded when the gate is given a `grace` (``AVAudioEngineAudioOutputService`` always
/// gives one): a parked writer or drainer waits at most the duration of the audio scheduled and
/// not yet played back when it parks (`unplayedFrames / sampleRate`), plus `grace` (2000 ms by
/// default), on a wall-clock timer, never on the output's own clock. When the bound passes with the
/// caller still parked, the output is stalled: every waiter, parked writers and drainers alike,
/// throws `Unavailable` with `details.code` `audio_output_failed`, `onExpire` runs (the session
/// stops its engine), and the gate ends without error, so later writes are ignored and a later
/// drain returns at once, as after `stop()`.
actor AudioOutputGate {
    private enum Queue { case writers, drainers }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let limit: Int
    private let sampleRate: Int
    private let grace: Duration?
    private let sleep: @Sendable (Duration) async throws -> Void
    private let onExpire: @Sendable () -> Void
    /// Frame counts of the scheduled buffers that have not played back, oldest first.
    private var unplayedBuffers: [Int] = []
    /// Slots handed to writers: a writer holds its slot from `reserve()` until its buffer plays back.
    private var reserved = 0
    private var scheduled = 0
    private var played = 0
    private var writers: [Waiter] = []
    private var drainers: [Waiter] = []
    private var ended = false
    private var endError: IndeRunException?

    /// `grace` is `nil` for an unbounded gate. `sleep` is the timer behind the bound; tests inject one.
    init(
        limit: Int = 3,
        sampleRate: Int = 24000,
        grace: Duration? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        onExpire: @escaping @Sendable () -> Void = {}
    ) {
        self.limit = limit
        self.sampleRate = sampleRate
        self.grace = grace
        self.sleep = sleep
        self.onExpire = onExpire
    }

    /// Audio scheduled and not yet played back, in frames.
    var unplayedFrames: Int { unplayedBuffers.reduce(0, +) }

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

    func markScheduled(frames: Int = 0) {
        scheduled += 1
        unplayedBuffers.append(frames)
    }

    func markPlayedBack() {
        guard !ended, played < scheduled else { return }
        played += 1
        if !unplayedBuffers.isEmpty { unplayedBuffers.removeFirst() }
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

    /// The longest a caller parking now waits: the unplayed audio's duration plus the grace.
    private func waitBound() -> Duration? {
        guard let grace else { return nil }
        return .seconds(Double(unplayedFrames) / Double(max(sampleRate, 1))) + grace
    }

    private func park(in queue: Queue) async throws {
        let id = UUID()
        let bound = waitBound()
        let timer = bound.map { bound in
            Task {
                do { try await self.sleep(bound) } catch { return }
                await self.expire(waiter: id, after: bound)
            }
        }
        defer { timer?.cancel() }
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

    /// The output made no progress within `bound`. Ignored when the waiter has already settled.
    private func expire(waiter id: UUID, after bound: Duration) {
        guard !ended, (writers + drainers).contains(where: { $0.id == id }) else { return }
        ended = true
        endError = nil
        let error = createUnavailable(
            message: "The audio output made no progress within \(bound.milliseconds) ms "
                + "(the unplayed audio plus a \(grace?.milliseconds ?? 0) ms grace).",
            details: ["code": JSONAny("audio_output_failed")]
        )
        settleAll(.writers, with: .failure(error))
        settleAll(.drainers, with: .failure(error))
        onExpire()
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

private extension Duration {
    var milliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
