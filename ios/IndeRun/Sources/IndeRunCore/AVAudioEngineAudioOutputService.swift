#if canImport(AVFoundation)
import AVFoundation
import Foundation
import IndeRunContracts

/// The default Apple audio output: one `AVAudioEngine` and `AVAudioPlayerNode` per session,
/// playing through the engine's main mixer. It never sets or activates an `AVAudioSession`
/// category; the audio session belongs to the application.
public final class AVAudioEngineAudioOutputService: AudioOutputService {
    private let makeSession: @Sendable (AVAudioFormat, Date) throws -> AVAudioEngineAudioOutputSession

    public convenience init() {
        self.init(makeSession: { format, openedAt in
            try AVAudioEngineAudioOutputSession(format: format, openedAt: openedAt)
        })
    }

    /// Tests inject a factory that cancels the opening task while the session is being built.
    init(makeSession: @escaping @Sendable (AVAudioFormat, Date) throws -> AVAudioEngineAudioOutputSession) {
        self.makeSession = makeSession
    }

    public func open(format: AudioOutputFormat) async throws -> any AudioOutputSession {
        guard format.channels == 1,
              format.encoding == .pcmS16le,
              (8000 ... 48000).contains(format.sampleRate),
              let playerFormat = AVAudioFormat(standardFormatWithSampleRate: Double(format.sampleRate), channels: 1)
        else {
            throw createCapabilityMismatch(
                message: "The audio output does not support this format.",
                details: ["code": JSONAny("audio_format_unsupported")]
            )
        }
        try Task.checkCancellation()
        let session = try makeSession(playerFormat, Date())
        // Building the session starts the engine synchronously; a cancel that landed meanwhile
        // must not hand a running engine to a caller that has stopped waiting.
        do {
            try Task.checkCancellation()
        } catch {
            session.stop()
            throw error
        }
        return session
    }
}

/// One playback session on its own engine.
///
/// `open` starts the engine with the player node idle, so it makes no sound; the first `write`
/// starts the player. At most three buffers are in flight (``AudioOutputGate``), each released
/// by its `.dataPlayedBack` completion, which also drives `drain()`.
///
/// `firstAudioMs()` comes from a tap on the player node, installed immediately before the first
/// `play()`: a tap on an idle node would see silence buffers and report first audio before any
/// write. The tap records the first rendered buffer that has frames, then is removed.
///
/// The system can stop the engine under the session: an `.AVAudioEngineConfigurationChange` for
/// this engine (an output device change, for example) or, on iOS-family platforms, an
/// `AVAudioSession` interruption or a media services reset. Any of them ends the session, as does a
/// `write` that finds the engine no longer running: pending and later `write`/`drain` calls throw
/// `Unavailable` with `details.code` `audio_output_interrupted` (after `stop()` they return
/// instead). The session only observes the application's audio session; it never sets or
/// activates its category.
///
/// Two locks, always taken in the order `controlLock` then `stateLock`: `stateLock` guards the
/// flags and is never held across an AVFoundation call, so the tap and completion callbacks can
/// take it; `controlLock` orders scheduling and `play()` against teardown, so nothing is scheduled
/// or played once `stop()` has begun. It is recursive in case the system delivers a notification
/// synchronously on a thread that holds it.
final class AVAudioEngineAudioOutputSession: AudioOutputSession, @unchecked Sendable {
    let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let openedAt: Date
    private let gate = AudioOutputGate(limit: 3)
    private let stateLock = NSLock()
    private let controlLock = NSRecursiveLock()
    private var stopped = false
    /// Set with `stopped` when the system ended the session; `nil` after `stop()`.
    private var endError: IndeRunException?
    private var started = false
    private var tapInstalled = false
    private var firstAudioAt: Date?
    private var observers: [NSObjectProtocol] = []

    init(format: AVAudioFormat, openedAt: Date) throws {
        self.format = format
        self.openedAt = openedAt
        // A host without an output device reports a 0-channel output; connecting to it raises an
        // Objective-C exception rather than throwing, so it is refused before anything is connected.
        let output = engine.outputNode.outputFormat(forBus: 0)
        guard output.channelCount > 0, output.sampleRate > 0 else {
            throw Self.failed("This host has no audio output device.")
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        // Observed before the engine starts, so a change between start and observation is not missed.
        let observers = makeObservers()
        stateLock.withLock { self.observers = observers }
        do {
            try engine.start()
        } catch {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            stateLock.withLock { self.observers = [] }
            throw Self.failed("The audio output could not be started: \(error.localizedDescription)")
        }
        // A notification that arrived before `start()` returned has already ended the session.
        if isStopped {
            engine.stop()
            throw Self.interrupted()
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private var isStopped: Bool { stateLock.withLock { stopped } }

    /// Whether the session has ended; throws the ending error when the system ended it.
    private func hasEnded() throws -> Bool {
        let (ended, error) = stateLock.withLock { (stopped, endError) }
        if let error { throw error }
        return ended
    }

    func write(_ samples: [Int16]) async throws {
        if try hasEnded() { return }
        try Task.checkCancellation()
        guard let buffer = makeBuffer(samples) else { return }
        try await gate.reserve()
        // Counted before scheduling, so a completion can never arrive ahead of its own count.
        await gate.markScheduled()
        let engineStopped: Bool = controlLock.withLock {
            let startsPlayback: Bool? = stateLock.withLock {
                if stopped { return nil }
                defer { started = true }
                return !started
            }
            guard let startsPlayback else { return false }
            // The system may have stopped the engine without a notification reaching this session
            // yet (an iOS audio session interruption posts none for the engine). Buffers scheduled on
            // it never play back, and `play()` on it raises an uncatchable Objective-C exception.
            guard engine.isRunning else { return true }
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.bufferPlayedBack()
            }
            if startsPlayback {
                installFirstAudioTap()
                guard engine.isRunning else { return true }
                player.play()
            }
            return false
        }
        if engineStopped { finish(Self.interrupted()) }
        // The session may have ended while this write waited or was skipped: throw a system ending.
        if try hasEnded() { return }
    }

    func drain() async throws {
        if try hasEnded() { return }
        try await gate.awaitDrained()
    }

    /// Tears the engine down before returning; writers and drainers parked in the gate are
    /// released by a detached task shortly after.
    func stop() {
        finish(nil)
    }

    func firstAudioMs() -> Double? {
        stateLock.withLock { firstAudioAt.map { $0.timeIntervalSince(openedAt) * 1000 } }
    }

    /// Ends the session once: tears the engine down, then settles the gate's waiters, throwing
    /// `error` in them when given. Later calls do nothing.
    private func finish(_ error: IndeRunException?) {
        let teardown: (removeTap: Bool, observers: [NSObjectProtocol])? = stateLock.withLock {
            if stopped { return nil }
            stopped = true
            endError = error
            defer {
                tapInstalled = false
                observers = []
            }
            return (tapInstalled, observers)
        }
        guard let teardown else { return }
        teardown.observers.forEach { NotificationCenter.default.removeObserver($0) }
        controlLock.withLock {
            if teardown.removeTap { player.removeTap(onBus: 0) }
            player.stop()
            engine.stop()
        }
        let gate = gate
        Task { await gate.end(error) }
    }

    /// Ends the session when the system stops this engine under it.
    private func makeObservers() -> [NSObjectProtocol] {
        var observers: [NSObjectProtocol] = []
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.finish(Self.interrupted())
        })
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        // An interruption (a call, Siri, losing the session in the background) stops the engine and
        // posts nothing for it. Only `.began` matters: the session has ended by the time it would resume.
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            guard type == .began else { return }
            self?.finish(Self.interrupted())
        })
        // A reset of the media services daemon invalidates every engine and posts nothing for them.
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.finish(Self.interrupted())
        })
        #endif
        return observers
    }

    private static func interrupted() -> IndeRunException {
        createUnavailable(
            message: "Audio output was interrupted by the system.",
            details: ["code": JSONAny("audio_output_interrupted")]
        )
    }

    private static func failed(_ message: String) -> IndeRunException {
        createUnavailable(message: message, details: ["code": JSONAny("audio_output_failed")])
    }

    /// A completion that `player.stop()` delivers for discarded audio is ignored: the gate is
    /// settled by `finish`, so a pending drain cannot return as if that audio had played.
    private func bufferPlayedBack() {
        if isStopped { return }
        let gate = gate
        Task { await gate.markPlayedBack() }
    }

    /// Called under `controlLock`, immediately before the first `play()`.
    private func installFirstAudioTap() {
        stateLock.withLock { tapInstalled = true }
        player.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard buffer.frameLength > 0, let self else { return }
            let now = Date()
            let isFirst: Bool = self.stateLock.withLock {
                if self.firstAudioAt != nil { return false }
                self.firstAudioAt = now
                return true
            }
            // Removing a tap from inside its own block is unsafe; remove it from another thread.
            if isFirst { DispatchQueue.global().async { [weak self] in self?.removeFirstAudioTap() } }
        }
    }

    private func removeFirstAudioTap() {
        controlLock.withLock {
            let installed: Bool = stateLock.withLock {
                defer { tapInstalled = false }
                return tapInstalled
            }
            if installed { player.removeTap(onBus: 0) }
        }
    }

    /// Mono Float32 in the player's format; `nil` for no samples.
    private func makeBuffer(_ samples: [Int16]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        for (index, sample) in samples.enumerated() {
            channel[index] = Float(sample) / 32768
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}
#endif
