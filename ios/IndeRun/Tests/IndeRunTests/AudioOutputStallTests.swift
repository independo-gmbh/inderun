import Foundation
import XCTest
import IndeRunContracts
#if canImport(AVFoundation)
import AVFoundation
#endif
@testable import IndeRunCore

/// A timer the test drives: `sleep` records the bound it was asked for and parks until `fire()`.
private final class ManualTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var requested: [Duration] = []
    private var parked: [UUID: CheckedContinuation<Void, Error>] = [:]

    var requests: [Duration] { lock.withLock { requested } }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelled: Bool = lock.withLock {
                    requested.append(duration)
                    if Task.isCancelled { return true }
                    parked[id] = continuation
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            lock.withLock { parked.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }

    /// Lets every parked timer expire.
    func fire() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            defer { parked.removeAll() }
            return Array(parked.values)
        }
        all.forEach { $0.resume() }
    }

    /// Waits up to about two seconds for `count` timers to have been requested.
    func waitForRequests(_ count: Int) async {
        for _ in 0 ..< 1000 where requests.count < count {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func bump() { lock.withLock { value += 1 } }
}

private func assertAudioOutputFailed(_ error: Error, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
    guard let error = error as? IndeRunException else {
        return XCTFail("\(label): threw \(error)", file: file, line: line)
    }
    XCTAssertEqual(error.errorClass, .Unavailable, label, file: file, line: line)
    XCTAssertEqual(error.details?["code"]?.value as? String, "audio_output_failed", label, file: file, line: line)
}

final class AudioOutputStallTests: XCTestCase {
    private let sampleRate = 24000
    private let grace = Duration.milliseconds(2000)

    private func makeGate(_ timer: ManualTimer, expired: Counter = Counter()) -> AudioOutputGate {
        AudioOutputGate(
            limit: 3,
            sampleRate: sampleRate,
            grace: grace,
            sleep: { try await timer.sleep($0) },
            onExpire: { expired.bump() }
        )
    }

    private func schedule(_ gate: AudioOutputGate, buffers: Int, ms: Int = 500) async throws {
        for _ in 0 ..< buffers {
            try await gate.reserve()
            await gate.markScheduled(frames: sampleRate * ms / 1000)
        }
    }

    func testDrainFailsWithAudioOutputFailedWhenOutputStalls() async throws {
        let timer = ManualTimer()
        let expired = Counter()
        let gate = makeGate(timer, expired: expired)
        try await schedule(gate, buffers: 1)
        let drain = Task { try await gate.awaitDrained() }
        await timer.waitForRequests(1)
        timer.fire()
        do {
            try await drain.value
            XCTFail("drain returned although the output never played")
        } catch {
            assertAudioOutputFailed(error, "stalled drain")
        }
        XCTAssertEqual(expired.count, 1)
    }

    func testDrainBoundCountsOnlyUnplayedAudio() async throws {
        let timer = ManualTimer()
        let gate = makeGate(timer)
        try await schedule(gate, buffers: 3) // 1500 ms scheduled
        await gate.markPlayedBack() // 500 ms played, 1000 ms left
        let drain = Task { try await gate.awaitDrained() }
        await timer.waitForRequests(1)
        XCTAssertEqual(timer.requests, [.milliseconds(1000) + grace])
        await gate.end(nil)
        try await drain.value
    }

    func testBackpressureWaitIsBounded() async throws {
        let timer = ManualTimer()
        let gate = makeGate(timer)
        try await schedule(gate, buffers: 3)
        let writer = Task { try await gate.reserve() }
        await timer.waitForRequests(1)
        XCTAssertEqual(timer.requests, [.milliseconds(1500) + grace])
        timer.fire()
        do {
            try await writer.value
            XCTFail("a write parked behind a stalled output was never released")
        } catch {
            assertAudioOutputFailed(error, "stalled write")
        }
    }

    func testExpiryFailsParkedWritersAndDrainersTogether() async throws {
        let timer = ManualTimer()
        let gate = makeGate(timer)
        try await schedule(gate, buffers: 3)
        let writer = Task { try await gate.reserve() }
        let drainer = Task { try await gate.awaitDrained() }
        await timer.waitForRequests(2)
        timer.fire()
        for task in [writer, drainer] {
            do {
                try await task.value
                XCTFail("a parked caller survived the expiry")
            } catch {
                assertAudioOutputFailed(error, "parked caller")
            }
        }
    }

    func testWritesAfterFailureAreIgnored() async throws {
        let timer = ManualTimer()
        let gate = makeGate(timer)
        try await schedule(gate, buffers: 3)
        let drain = Task { try await gate.awaitDrained() }
        await timer.waitForRequests(1)
        timer.fire()
        _ = try? await drain.value
        // Later calls return at once, as after stop(): no throw, no new timer.
        try await gate.reserve()
        try await gate.awaitDrained()
        XCTAssertEqual(timer.requests.count, 1)
    }

    func testStopReleasesAStalledDrainWithoutALaterRejection() async throws {
        let timer = ManualTimer()
        let expired = Counter()
        let gate = makeGate(timer, expired: expired)
        try await schedule(gate, buffers: 1)
        let drain = Task { try await gate.awaitDrained() }
        await timer.waitForRequests(1)
        await gate.end(nil) // what stop() does
        try await drain.value
        timer.fire() // a timer that outlived the wait must do nothing
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(expired.count, 0)
        try await gate.awaitDrained()
    }

    func testADrainThatCompletesInTimeLeavesNoRejectionBehind() async throws {
        let timer = ManualTimer()
        let expired = Counter()
        let gate = makeGate(timer, expired: expired)
        try await schedule(gate, buffers: 1)
        let drain = Task { try await gate.awaitDrained() }
        await timer.waitForRequests(1)
        await gate.markPlayedBack()
        try await drain.value
        timer.fire()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(expired.count, 0)
        try await gate.reserve() // the gate is still live
    }

    #if canImport(AVFoundation)
    /// The engine session wires the gate: a timer that expires at once ends a real drain with
    /// `audio_output_failed`, then the session behaves as stopped. Skips without an output device.
    func testEngineSessionEndsAfterExpiryAndStopStaysIdempotent() async throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1))
        let session: AVAudioEngineAudioOutputSession
        do {
            session = try AVAudioEngineAudioOutputSession(
                format: format,
                openedAt: Date(),
                outputWaitGrace: .milliseconds(1),
                sleep: { _ in } // the wall clock says time is up as soon as anyone waits
            )
        } catch let error as IndeRunException where error.details?["code"]?.value as? String == "audio_output_failed" {
            throw XCTSkip("This host cannot open an audio output: \(error.message)")
        }
        defer { session.stop() }
        let samples = [Int16](repeating: 1000, count: 24000 * 3)
        try await session.write(samples)
        do {
            try await session.drain()
            XCTFail("drain returned although the wait bound had expired")
        } catch {
            assertAudioOutputFailed(error, "engine drain")
        }
        try await session.write(samples) // ignored
        try await session.drain() // at once
        XCTAssertFalse(session.engine.isRunning)
        session.stop()
        session.stop()
    }
    #endif
}
