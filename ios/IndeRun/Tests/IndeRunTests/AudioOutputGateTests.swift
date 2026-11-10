import Foundation
import XCTest
import IndeRunContracts
@testable import IndeRunCore

/// Records whether a gate call has returned, for polling from the test.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var isRaised: Bool { lock.withLock { raised } }

    func raise() { lock.withLock { raised = true } }

    /// Waits up to about one second for the flag. Bounded, so a broken path fails rather than hangs.
    func waitUntilRaised() async {
        for _ in 0 ..< 500 where !isRaised {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

private let interrupted = createUnavailable(
    message: "Audio output was interrupted by the system.",
    details: ["code": JSONAny("audio_output_interrupted")]
)

/// Gives a parked waiter time to reach the gate before the test checks that it has not returned.
private func letWaitersPark() async {
    try? await Task.sleep(nanoseconds: 50_000_000)
}

final class AudioOutputGateTests: XCTestCase {
    func testReserveWaitsWhenThreeBuffersAreInFlight() async throws {
        let gate = AudioOutputGate(limit: 3)
        for _ in 0 ..< 3 {
            try await gate.reserve()
            await gate.markScheduled()
        }
        let returned = Flag()
        let fourth = Task {
            try await gate.reserve()
            returned.raise()
        }
        await letWaitersPark()
        XCTAssertFalse(returned.isRaised, "the fourth reserve() returned with three buffers in flight")
        await gate.markPlayedBack()
        await returned.waitUntilRaised()
        XCTAssertTrue(returned.isRaised, "the fourth reserve() stayed parked after a buffer played back")
        try await fourth.value
    }

    func testAwaitDrainedReturnsWhenPlayedEqualsScheduled() async throws {
        let gate = AudioOutputGate()
        for _ in 0 ..< 2 {
            try await gate.reserve()
            await gate.markScheduled()
        }
        let drained = Flag()
        let drainer = Task {
            try await gate.awaitDrained()
            drained.raise()
        }
        await gate.markPlayedBack()
        await letWaitersPark()
        XCTAssertFalse(drained.isRaised, "awaitDrained() returned with one buffer still in flight")
        await gate.markPlayedBack()
        await drained.waitUntilRaised()
        XCTAssertTrue(drained.isRaised, "awaitDrained() stayed parked after every buffer played back")
        try await drainer.value
    }

    func testAwaitDrainedReturnsAtOnceWithNothingScheduled() async throws {
        let gate = AudioOutputGate()
        try await gate.awaitDrained()
    }

    func testEndWithErrorThrowsInPendingWaiters() async throws {
        let gate = AudioOutputGate(limit: 1)
        try await gate.reserve()
        await gate.markScheduled()
        let returned = Flag()
        let writer = Task {
            defer { returned.raise() }
            try await gate.reserve()
        }
        let drainer = Task {
            defer { returned.raise() }
            try await gate.awaitDrained()
        }
        await letWaitersPark()
        XCTAssertFalse(returned.isRaised, "a waiter returned before end(_:)")
        await gate.end(interrupted)
        for (label, waiter) in [("reserve", writer), ("awaitDrained", drainer)] {
            do {
                try await waiter.value
                XCTFail("\(label) returned instead of throwing")
            } catch let error as IndeRunException {
                XCTAssertEqual(error.errorClass, .Unavailable, label)
                XCTAssertEqual(error.details?["code"]?.value as? String, "audio_output_interrupted", label)
            }
        }
    }

    func testCancelledReserveThrowsAndLeaksNoSlot() async throws {
        let gate = AudioOutputGate(limit: 1)
        try await gate.reserve()
        await gate.markScheduled()
        let cancelled = Task { try await gate.reserve() }
        await letWaitersPark()
        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("a cancelled reserve() returned instead of throwing")
        } catch is CancellationError {}
        let admitted = Flag()
        let next = Task {
            try await gate.reserve()
            admitted.raise()
        }
        await letWaitersPark()
        XCTAssertFalse(admitted.isRaised, "the next reserve() returned with the one slot in flight")
        await gate.markPlayedBack()
        await admitted.waitUntilRaised()
        XCTAssertTrue(admitted.isRaised, "the cancelled writer kept the slot the played-back buffer freed")
        try await next.value
    }

    func testEndWithoutErrorReleasesWaiters() async throws {
        let gate = AudioOutputGate(limit: 1)
        try await gate.reserve()
        await gate.markScheduled()
        let released = Flag()
        let writer = Task { try await gate.reserve() }
        let drainer = Task { try await gate.awaitDrained() }
        let both = Task {
            try await writer.value
            try await drainer.value
            released.raise()
        }
        await letWaitersPark()
        XCTAssertFalse(released.isRaised)
        await gate.end(nil)
        await released.waitUntilRaised()
        XCTAssertTrue(released.isRaised, "end(nil) did not release the parked waiters")
        try await both.value
    }

    func testReserveAndAwaitDrainedReturnAtOnceAfterEnd() async throws {
        let gate = AudioOutputGate(limit: 1)
        try await gate.reserve()
        await gate.markScheduled()
        await gate.end(nil)
        await gate.end(interrupted) // idempotent: the first ending wins
        try await gate.reserve()
        try await gate.reserve()
        try await gate.awaitDrained()
    }
}
