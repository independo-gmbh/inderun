import Foundation
import XCTest
import IndeRunContracts
@testable import IndeRunCore
#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: - Audio output conformance

/// The Apple half of the cross-SDK audio output catalog
/// (`contracts/fixtures/host/audio-output-lifecycle.json`, ADR 021). One handler per case id;
/// `testImplementsEveryCaseInTheSharedCatalogAndNoOthers` fails when the handler ids and the
/// catalog ids differ. Mirrors `audio-output.conformance.test.ts`.
final class AudioOutputLifecycleConformanceTests: XCTestCase {
    func testImplementsEveryCaseInTheSharedCatalogAndNoOthers() throws {
        let catalogIds = try loadCatalog().cases.map(\.id).sorted()
        XCTAssertFalse(catalogIds.isEmpty)
        XCTAssertEqual(Set(catalogIds).count, catalogIds.count, "duplicate case id in the catalog")
        XCTAssertEqual(handlers.keys.sorted(), catalogIds)
    }

    func testFixtureMatchesTheSharedCatalog() async throws {
        let fixture = FixtureAudioOutputService()
        try await runCatalog(AudioOutputTarget(service: fixture, now: { fixture.now() }), label: "fixture")
        // 3000 ms at 24000 Hz: the buffered audio was discarded, not played.
        // Re-run the one case on a fresh fixture so the counter is attributable to it.
        let discarding = FixtureAudioOutputService()
        let target = AudioOutputTarget(service: discarding, now: { discarding.now() })
        let expected = try XCTUnwrap(loadCatalog().cases.first { $0.id == "stop_discards_buffered_audio" }).expect
        _ = try await handlers["stop_discards_buffered_audio"]!(target, expected)
        XCTAssertEqual(discarding.sessions.first?.discardedFrames, 72000)
    }

    /// The fixture's two endings, which PR 3's provider tests rely on: after `interrupt(_:)` a write
    /// and a drain throw its error; after `stop()` they return without effect.
    func testFixtureWriteAfterInterruptThrowsAndAfterStopReturns() async throws {
        let interrupting = FixtureAudioOutputService()
        let interrupted = try await interrupting.open(format: format)
        try await interrupted.write(tone(ms: 200))
        let error = createUnavailable(
            message: "Audio output was interrupted by the system.",
            details: ["code": JSONAny("audio_output_interrupted")]
        )
        try XCTUnwrap(interrupting.sessions.first).interrupt(error)
        do {
            try await interrupted.write(tone(ms: 200))
            XCTFail("write after interrupt returned instead of throwing")
        } catch let thrown as IndeRunException {
            XCTAssertEqual(thrown.details?["code"]?.value as? String, "audio_output_interrupted")
        }
        do {
            try await interrupted.drain()
            XCTFail("drain after interrupt returned instead of throwing")
        } catch let thrown as IndeRunException {
            XCTAssertEqual(thrown.details?["code"]?.value as? String, "audio_output_interrupted")
        }
        XCTAssertEqual(interrupting.sessions.first?.writtenFrames, 4800)
        XCTAssertEqual(interrupting.sessions.first?.discardedFrames, 4800)

        let stopping = FixtureAudioOutputService()
        let stopped = try await stopping.open(format: format)
        stopped.stop()
        try await stopped.write(tone(ms: 200))
        try await stopped.drain()
        XCTAssertEqual(stopping.sessions.first?.writtenFrames, 0)
    }
}

#if canImport(AVFoundation)
// MARK: - Real engine

/// The catalog against `AVAudioEngineAudioOutputService`. Plays audio through the default output
/// device, so it skips (never fails or hangs) on a host that has none or renders nothing.
extension AudioOutputLifecycleConformanceTests {
    func testAVAudioEngineMatchesTheSharedCatalog() async throws {
        let service = try await probeRealEngine()
        try await runCatalog(
            AudioOutputTarget(service: service, now: { Date().timeIntervalSince1970 * 1000 }),
            label: "AVAudioEngine"
        )
    }

    /// A cancel that lands while the engine is starting, after `open` checked for cancellation and
    /// before the session exists, must not hand a running engine to a caller that has stopped
    /// waiting: `open` throws `CancellationError` and the session it built is stopped.
    func testOpenCancelledWhileTheEngineStartsStopsTheSession() async throws {
        _ = try await probeRealEngine()
        let built = SessionBox()
        let service = AVAudioEngineAudioOutputService(makeSession: { format, openedAt in
            let session = try AVAudioEngineAudioOutputSession(format: format, openedAt: openedAt)
            built.set(session)
            // The caller cancels while the engine is starting.
            withUnsafeCurrentTask { $0?.cancel() }
            return session
        })
        do {
            let session = try await service.open(format: format)
            session.stop()
            XCTFail("open() returned a session to a cancelled task")
        } catch is CancellationError {
            // Expected.
        }
        let session = try XCTUnwrap(built.get(), "the session factory was not called")
        XCTAssertFalse(session.engine.isRunning, "the engine of a cancelled open is still running")
    }

    func testInterruptionEndsPendingDrain() async throws {
        let service = try await probeRealEngine()
        let session = try await service.open(format: format)
        let engineSession = try XCTUnwrap(session as? AVAudioEngineAudioOutputSession)
        try await session.write(tone(ms: 2000))
        let drain = Task { try await session.drain() }
        await settle(ms: 100)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engineSession.engine)
        do {
            try await bounded(ms: 1000, "interrupted drain") { try await drain.value }
            XCTFail("drain() returned instead of throwing after the interruption")
        } catch let error as IndeRunException {
            XCTAssertEqual(error.errorClass, .Unavailable)
            XCTAssertEqual(error.details?["code"]?.value as? String, "audio_output_interrupted")
        }
        // The system ended the session: a following write throws the same error at once, so a
        // provider synthesizing its next chunk cannot report the cut-off utterance as completed.
        // 250 ms, not the catalog's 50: tolerant of a loaded CI simulator.
        try await assertInterrupted("write after interruption") { try await session.write(tone(ms: 200)) }
        try await assertInterrupted("drain after interruption") { try await session.drain() }
        session.stop()
    }

    #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    /// An `AVAudioSession` interruption (a call, Siri) ends the session: a pending drain throws.
    func testAudioSessionInterruptionEndsPendingDrain() async throws {
        try await assertSystemNotificationEndsPendingDrain(
            AVAudioSession.interruptionNotification,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
    }

    /// A media services reset invalidates every engine: a pending drain throws.
    func testMediaServicesResetEndsPendingDrain() async throws {
        try await assertSystemNotificationEndsPendingDrain(AVAudioSession.mediaServicesWereResetNotification, userInfo: nil)
    }

    private func assertSystemNotificationEndsPendingDrain(_ name: Notification.Name, userInfo: [AnyHashable: Any]?) async throws {
        let service = try await probeRealEngine()
        let session = try await service.open(format: format)
        try await session.write(tone(ms: 2000))
        let drain = Task { try await session.drain() }
        await settle(ms: 100)
        NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
        try await assertInterrupted("drain pending at \(name.rawValue)", within: 1000) { try await drain.value }
        try await assertInterrupted("write after \(name.rawValue)") { try await session.write(tone(ms: 200)) }
        session.stop()
    }
    #endif

    /// Asserts that `operation` throws `Unavailable` / `audio_output_interrupted` within `within` ms.
    private func assertInterrupted(
        _ label: String,
        within: Int = 250,
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        do {
            try await bounded(ms: within, label, operation)
            XCTFail("\(label): returned instead of throwing")
        } catch let error as IndeRunException {
            XCTAssertEqual(error.errorClass, .Unavailable, label)
            XCTAssertEqual(error.details?["code"]?.value as? String, "audio_output_interrupted", label)
        }
    }

    /// The system can stop the engine without a notification reaching the session (an iOS audio
    /// session interruption posts none for the engine). The first write must end the session, not
    /// call `play()` on the stopped engine, which raises an uncatchable Objective-C exception.
    func testWriteOnAnEngineTheSystemStoppedEndsTheSession() async throws {
        let service = try await probeRealEngine()
        let session = try await service.open(format: format)
        let engineSession = try XCTUnwrap(session as? AVAudioEngineAudioOutputSession)
        engineSession.engine.stop()
        do {
            try await bounded(ms: 250, "write on a stopped engine") { try await session.write(tone(ms: 200)) }
            XCTFail("write() returned instead of throwing on a stopped engine")
        } catch let error as IndeRunException {
            XCTAssertEqual(error.errorClass, .Unavailable)
            XCTAssertEqual(error.details?["code"]?.value as? String, "audio_output_interrupted")
        }
        XCTAssertNil(session.firstAudioMs())
        // The system ended the session: further calls throw its error at once.
        try await assertInterrupted("write after the session ended") { try await session.write(tone(ms: 200)) }
        try await assertInterrupted("drain after the session ended") { try await session.drain() }
        session.stop()
    }

    /// Opens the real service, writes 200 ms and waits up to 2 s for `firstAudioMs()`; skips when
    /// the host cannot open an output (`audio_output_failed`) or renders nothing (no first audio).
    private func probeRealEngine() async throws -> AVAudioEngineAudioOutputService {
        let service = AVAudioEngineAudioOutputService()
        let session: any AudioOutputSession
        do {
            session = try await service.open(format: format)
        } catch let error as IndeRunException where error.details?["code"]?.value as? String == "audio_output_failed" {
            throw XCTSkip("This host cannot open an audio output: \(error.message)")
        }
        defer { session.stop() }
        try await session.write(tone(ms: 200))
        let deadline = Date().addingTimeInterval(2)
        while session.firstAudioMs() == nil, Date() < deadline { await settle(ms: 10) }
        guard session.firstAudioMs() != nil else {
            throw XCTSkip("This host's audio output rendered nothing within 2 s.")
        }
        return service
    }
}

/// Hands a session built inside `open` to the test that cancelled it.
private final class SessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var session: AVAudioEngineAudioOutputSession?

    func set(_ session: AVAudioEngineAudioOutputSession) { lock.withLock { self.session = session } }
    func get() -> AVAudioEngineAudioOutputSession? { lock.withLock { session } }
}
#endif

// MARK: - Catalog

/// Mirrors `$expectKeys` in the catalog; every key is optional.
private struct Expectations: Decodable {
    struct AfterOpen: Decodable { let firstAudioDefined: Bool }
    struct AfterWrites: Decodable {
        let firstAudioDefined: Bool
        var waitAtMostMs: Int?
        var firstAudioAtMostMs: Double?
    }
    struct Drain: Decodable {
        let elapsedAtLeastMs: Double
        let timeoutMs: Int
    }
    struct Stop: Decodable {
        let `throws`: Bool
        var calls: Int?
        var writeSettlesWithinMs: Int?
    }
    struct AtMost: Decodable {
        let elapsedAtMostMs: Double
        let `throws`: Bool
    }
    struct Independence: Decodable {
        let stoppedDrainAtMostMs: Double
        let otherDrainAtLeastMs: Double
        let timeoutMs: Int
    }
    struct OpenRejection: Decodable {
        let errorClass: String
        let code: String
    }

    var afterOpen: AfterOpen?
    var afterWrites: AfterWrites?
    var drain: Drain?
    var stop: Stop?
    var writeAfterStop: AtMost?
    var drainAfterStop: AtMost?
    var independence: Independence?
    var openRejectsWith: OpenRejection?
}

private struct CatalogCase: Decodable {
    let id: String
    let expect: Expectations
}

private struct Catalog: Decodable {
    let cases: [CatalogCase]
}

private func repositoryRoot() -> URL {
    // .../ios/IndeRun/Tests/IndeRunTests/AudioOutputLifecycleConformanceTests.swift
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func loadCatalog() throws -> Catalog {
    let url = repositoryRoot().appendingPathComponent("contracts/fixtures/host/audio-output-lifecycle.json")
    return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
}

// MARK: - Targets and observations

/// A service under test and the clock its elapsed times are read on (the fixture's virtual
/// clock, or wall time for a real service).
struct AudioOutputTarget {
    let service: any AudioOutputService
    let now: @Sendable () -> Double
}

private struct Observation {
    var firstAudioDefinedAfterOpen: Bool?
    var firstAudioDefinedAfterWrites: Bool?
    var firstAudioMs: Double?
    var drainElapsedMs: Double?
    var stopThrew: Bool?
    var stopCalls: Int?
    var writeSettledAfterStopMs: Double?
    var writeAfterStopElapsedMs: Double?
    var writeAfterStopThrew: Bool?
    var drainAfterStopElapsedMs: Double?
    var drainAfterStopThrew: Bool?
    var stoppedDrainElapsedMs: Double?
    var otherDrainElapsedMs: Double?
    var openRejection: IndeRunException?
}

private typealias Handler = (AudioOutputTarget, Expectations) async throws -> Observation

private let format = AudioOutputFormat(sampleRate: 24000)

/// 440 Hz at -14 dBFS.
private func tone(ms: Int, sampleRate: Int = format.sampleRate) -> [Int16] {
    let frames = Int((Double(sampleRate * ms) / 1000).rounded())
    let amplitude = 32767 * pow(10, -14.0 / 20)
    return (0 ..< frames).map { index in
        Int16((amplitude * sin(2 * Double.pi * 440 * Double(index) / Double(sampleRate))).rounded())
    }
}

/// Wall time; the fixture's own clock is virtual.
private func settle(ms: Int) async {
    try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
}

private struct BoundExceeded: Error, CustomStringConvertible {
    let label: String
    let ms: Int
    var description: String { "\(label) did not settle within \(ms) ms" }
}

/// Races `operation` against a sleep that throws, so a broken path fails rather than hangs.
private func bounded<T: Sendable>(
    ms: Int,
    _ label: String,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            throw BoundExceeded(label: label, ms: ms)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw BoundExceeded(label: label, ms: ms) }
        return first
    }
}

/// Runs `action`, returning whether it threw.
private func threw(_ action: () async throws -> Void) async -> Bool {
    do {
        try await action()
        return false
    } catch {
        return true
    }
}

// MARK: - Handlers

/// Every wait and bound a handler uses comes from the case's own expectations.
private let handlers: [String: Handler] = [
    "open_makes_no_sound": { target, _ in
        let session = try await target.service.open(format: format)
        await settle(ms: 200)
        let defined = session.firstAudioMs() != nil
        session.stop()
        return Observation(firstAudioDefinedAfterOpen: defined)
    },
    "first_write_starts_playback": { target, expected in
        let waitMs = expected.afterWrites?.waitAtMostMs ?? 0
        let session = try await target.service.open(format: format)
        let definedAfterOpen = session.firstAudioMs() != nil
        try await session.write(tone(ms: 200))
        let deadline = Date().addingTimeInterval(Double(waitMs) / 1000)
        while session.firstAudioMs() == nil, Date() < deadline { await settle(ms: 10) }
        let firstAudioMs = session.firstAudioMs()
        try await bounded(ms: waitMs, "drain") { try await session.drain() }
        session.stop()
        return Observation(
            firstAudioDefinedAfterOpen: definedAfterOpen,
            firstAudioDefinedAfterWrites: firstAudioMs != nil,
            firstAudioMs: firstAudioMs
        )
    },
    "drain_waits_for_everything_written": { target, expected in
        let session = try await target.service.open(format: format)
        let from = target.now()
        try await session.write(tone(ms: 200))
        try await session.write(tone(ms: 200))
        try await bounded(ms: expected.drain!.timeoutMs, "drain") { try await session.drain() }
        let elapsed = target.now() - from
        session.stop()
        return Observation(drainElapsedMs: elapsed)
    },
    "stop_discards_buffered_audio": { target, expected in
        let session = try await target.service.open(format: format)
        let inFlight = Task { try await session.write(tone(ms: 3000)) }
        await settle(ms: 100)
        session.stop()
        let stoppedAt = target.now()
        let withinMs = expected.stop!.writeSettlesWithinMs!
        try await bounded(ms: withinMs, "in-flight write") { try await inFlight.value }
        let settledAfter = target.now() - stoppedAt
        let drainFrom = target.now()
        let drainThrew = await threw {
            try await bounded(ms: withinMs, "drain after stop") { try await session.drain() }
        }
        return Observation(
            stopThrew: false,
            writeSettledAfterStopMs: settledAfter,
            drainAfterStopElapsedMs: target.now() - drainFrom,
            drainAfterStopThrew: drainThrew
        )
    },
    "stop_is_idempotent": { target, expected in
        let session = try await target.service.open(format: format)
        try await session.write(tone(ms: 200))
        var calls = 0
        for _ in 0 ..< expected.stop!.calls! {
            calls += 1
            session.stop()
        }
        let drainFrom = target.now()
        let drainThrew = await threw {
            try await bounded(ms: Int(expected.drainAfterStop!.elapsedAtMostMs), "drain after stop") {
                try await session.drain()
            }
        }
        return Observation(
            stopThrew: false,
            stopCalls: calls,
            drainAfterStopElapsedMs: target.now() - drainFrom,
            drainAfterStopThrew: drainThrew
        )
    },
    "write_after_stop_is_ignored": { target, expected in
        let session = try await target.service.open(format: format)
        session.stop()
        let from = target.now()
        let writeThrew = await threw {
            try await bounded(ms: Int(expected.writeAfterStop!.elapsedAtMostMs), "write after stop") {
                try await session.write(tone(ms: 200))
            }
        }
        let elapsed = target.now() - from
        await settle(ms: 300)
        return Observation(
            firstAudioDefinedAfterWrites: session.firstAudioMs() != nil,
            writeAfterStopElapsedMs: elapsed,
            writeAfterStopThrew: writeThrew
        )
    },
    "drain_after_stop_resolves_at_once": { target, expected in
        let session = try await target.service.open(format: format)
        try await session.write(tone(ms: 200))
        session.stop()
        let from = target.now()
        let drainThrew = await threw {
            try await bounded(ms: Int(expected.drainAfterStop!.elapsedAtMostMs), "drain after stop") {
                try await session.drain()
            }
        }
        return Observation(drainAfterStopElapsedMs: target.now() - from, drainAfterStopThrew: drainThrew)
    },
    "sessions_are_independent": { target, expected in
        let timeoutMs = expected.independence!.timeoutMs
        let first = try await target.service.open(format: format)
        let second = try await target.service.open(format: format)
        let from = target.now()
        try await first.write(tone(ms: 1000))
        try await second.write(tone(ms: 1000))
        first.stop()
        let stoppedFrom = target.now()
        try await bounded(ms: timeoutMs, "drain of the stopped session") { try await first.drain() }
        let stoppedElapsed = target.now() - stoppedFrom
        try await bounded(ms: timeoutMs, "drain of the other session") { try await second.drain() }
        let otherElapsed = target.now() - from
        second.stop()
        return Observation(stoppedDrainElapsedMs: stoppedElapsed, otherDrainElapsedMs: otherElapsed)
    },
    "unsupported_format_refused": { target, _ in
        do {
            let session = try await target.service.open(format: AudioOutputFormat(sampleRate: 4000))
            session.stop()
        } catch let error as IndeRunException {
            return Observation(openRejection: error)
        }
        return Observation()
    }
]

// MARK: - Run and assertions

/// Runs every catalog case against `target`, reporting each mismatch as `label/case id: ...`.
private func runCatalog(_ target: AudioOutputTarget, label: String) async throws {
    for entry in try loadCatalog().cases {
        guard let handler = handlers[entry.id] else {
            XCTFail("\(label)/\(entry.id): no handler")
            continue
        }
        do {
            let observed = try await handler(target, entry.expect)
            check(label: "\(label)/\(entry.id)", expected: entry.expect, observed: observed)
        } catch {
            XCTFail("\(label)/\(entry.id): \(error)")
        }
    }
}

// swiftlint:disable:next cyclomatic_complexity function_body_length
private func check(label: String, expected: Expectations, observed: Observation) {
    if let afterOpen = expected.afterOpen {
        XCTAssertEqual(observed.firstAudioDefinedAfterOpen, afterOpen.firstAudioDefined, "\(label): firstAudio after open")
    }
    if let afterWrites = expected.afterWrites {
        XCTAssertEqual(
            observed.firstAudioDefinedAfterWrites,
            afterWrites.firstAudioDefined,
            "\(label): firstAudio after writes"
        )
        if let atMost = afterWrites.firstAudioAtMostMs {
            XCTAssertLessThanOrEqual(observed.firstAudioMs ?? .infinity, atMost, "\(label): firstAudioMs")
        }
    }
    if let drain = expected.drain {
        XCTAssertGreaterThanOrEqual(observed.drainElapsedMs ?? -1, drain.elapsedAtLeastMs, "\(label): drain elapsed")
    }
    if let stop = expected.stop {
        XCTAssertEqual(observed.stopThrew, stop.throws, "\(label): stop throws")
        if let calls = stop.calls {
            XCTAssertEqual(observed.stopCalls, calls, "\(label): stop calls")
        }
        if let within = stop.writeSettlesWithinMs {
            XCTAssertLessThanOrEqual(
                observed.writeSettledAfterStopMs ?? .infinity,
                Double(within),
                "\(label): in-flight write after stop"
            )
        }
    }
    if let writeAfterStop = expected.writeAfterStop {
        XCTAssertLessThanOrEqual(
            observed.writeAfterStopElapsedMs ?? .infinity,
            writeAfterStop.elapsedAtMostMs,
            "\(label): write after stop elapsed"
        )
        XCTAssertEqual(observed.writeAfterStopThrew, writeAfterStop.throws, "\(label): write after stop throws")
    }
    if let drainAfterStop = expected.drainAfterStop {
        XCTAssertLessThanOrEqual(
            observed.drainAfterStopElapsedMs ?? .infinity,
            drainAfterStop.elapsedAtMostMs,
            "\(label): drain after stop elapsed"
        )
        XCTAssertEqual(observed.drainAfterStopThrew, drainAfterStop.throws, "\(label): drain after stop throws")
    }
    if let independence = expected.independence {
        XCTAssertLessThanOrEqual(
            observed.stoppedDrainElapsedMs ?? .infinity,
            independence.stoppedDrainAtMostMs,
            "\(label): stopped session drain"
        )
        XCTAssertGreaterThanOrEqual(
            observed.otherDrainElapsedMs ?? -1,
            independence.otherDrainAtLeastMs,
            "\(label): other session drain"
        )
    }
    if let rejection = expected.openRejectsWith {
        guard let error = observed.openRejection else {
            XCTFail("\(label): open was not refused")
            return
        }
        XCTAssertEqual(error.errorClass.rawValue, rejection.errorClass, "\(label): error class")
        XCTAssertEqual(error.details?["code"]?.value as? String, rejection.code, "\(label): details.code")
    }
}
