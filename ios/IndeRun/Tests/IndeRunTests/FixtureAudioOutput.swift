import Foundation
import IndeRunContracts
@testable import IndeRunCore

/// A recording audio output session with a virtual clock shared with its service: `write` returns
/// at once, and only `drain` advances the clock, by the duration of the frames not yet played.
/// Mirrors `audio-output-fixture.ts`.
final class FixtureAudioOutputSession: AudioOutputSession, @unchecked Sendable {
    let format: AudioOutputFormat
    private let clock: FixtureAudioOutputService
    private let openedAt: Double
    private let lock = NSLock()
    private var recordedWrites: [[Int16]] = []
    private var written = 0
    private var played = 0
    private var discarded = 0
    private var isPlaying = false
    private var isStopped = false
    private var endError: IndeRunException?
    private var firstAudio: Double?

    fileprivate init(format: AudioOutputFormat, clock: FixtureAudioOutputService) {
        self.format = format
        self.clock = clock
        self.openedAt = clock.now()
    }

    var writes: [[Int16]] { lock.withLock { recordedWrites } }
    var writtenFrames: Int { lock.withLock { written } }
    var playedFrames: Int { lock.withLock { played } }
    var discardedFrames: Int { lock.withLock { discarded } }
    var playing: Bool { lock.withLock { isPlaying } }
    var stopped: Bool { lock.withLock { isStopped } }

    func write(_ samples: [Int16]) async throws {
        try lock.withLock {
            if let endError { throw endError }
            if isStopped { return }
            recordedWrites.append(samples)
            written += samples.count
            if firstAudio == nil {
                firstAudio = clock.now() - openedAt
                isPlaying = true
            }
        }
    }

    func drain() async throws {
        if clock.isStalled, lock.withLock({ !isStopped && endError == nil }) {
            // A stalled output never plays: drain fails once the unplayed audio's duration plus the
            // grace has passed, then the session is over (later writes ignored, drain at once).
            let pending = lock.withLock { written - played }
            clock.advance(byMs: Double(pending) * 1000 / Double(format.sampleRate) + FixtureAudioOutputService.graceMs)
            end(nil)
            throw createUnavailable(
                message: "The audio output made no progress.",
                details: ["code": JSONAny("audio_output_failed")]
            )
        }
        let pending: Int = try lock.withLock {
            if let endError { throw endError }
            if isStopped { return 0 }
            let pending = written - played
            played = written
            return pending
        }
        clock.advance(byMs: Double(pending) * 1000 / Double(format.sampleRate))
    }

    func stop() {
        end(nil)
    }

    /// Ends the session the way the system does (an interruption): buffered audio is discarded,
    /// and every later `write` and `drain` throws `error`. After `stop()` they return instead.
    func interrupt(_ error: IndeRunException) {
        end(error)
    }

    private func end(_ error: IndeRunException?) {
        lock.withLock {
            if isStopped { return }
            isStopped = true
            endError = error
            isPlaying = false
            discarded += written - played
        }
    }

    func firstAudioMs() -> Double? {
        lock.withLock { firstAudio }
    }
}

/// A recording audio output service: `now()` starts at 0 and only `drain()` advances it.
final class FixtureAudioOutputService: AudioOutputService, @unchecked Sendable {
    private let lock = NSLock()
    private var ms = 0.0
    private var opened: [FixtureAudioOutputSession] = []
    private var stalled = false

    /// The grace a stalled drain waits past the unplayed audio, in virtual ms.
    static let graceMs = 2000.0

    /// While stalled, the output of every session never advances and `drain()` fails with
    /// `audio_output_failed` after the unplayed duration plus ``graceMs``.
    func setStalled(_ value: Bool) { lock.withLock { stalled = value } }
    fileprivate var isStalled: Bool { lock.withLock { stalled } }

    /// Virtual milliseconds; advanced only by `drain()`.
    func now() -> Double { lock.withLock { ms } }

    var sessions: [FixtureAudioOutputSession] { lock.withLock { opened } }

    fileprivate func advance(byMs delta: Double) {
        lock.withLock { ms += delta }
    }

    func open(format: AudioOutputFormat) async throws -> any AudioOutputSession {
        guard format.channels == 1,
              format.encoding == .pcmS16le,
              (8000 ... 48000).contains(format.sampleRate)
        else {
            throw createCapabilityMismatch(
                message: "The audio output does not support this format.",
                details: ["code": JSONAny("audio_format_unsupported")]
            )
        }
        try Task.checkCancellation()
        let session = FixtureAudioOutputSession(format: format, clock: self)
        lock.withLock { opened.append(session) }
        return session
    }
}
