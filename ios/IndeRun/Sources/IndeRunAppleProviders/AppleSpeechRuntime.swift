import AVFoundation
import Foundation
import IndeRunContracts
import IndeRunCore

/// An installed system voice. `identifier` is the id the catalog lists it under (ADR 018).
struct AppleSpeechVoice: Sendable, Equatable {
    var identifier: String
    var locale: String
    var gender: VoiceGender?
    var name: String?
}

/// Mono 16-bit signed little-endian samples at `sampleRate`.
struct RenderedSpeech: Sendable, Equatable {
    var samples: Data
    var sampleRate: Int

    var durationMs: Double {
        Double(samples.count / 2) / Double(sampleRate) * 1000
    }
}

/// What one finished utterance reported. Either value is `nil` when the synthesizer never sent the
/// callback it is measured from.
struct SpokenAudio: Sendable, Equatable {
    /// From `didStart` to `didFinish`.
    var durationMs: Double?
    /// From handing the utterance to the synthesizer to its first `willSpeakRangeOfSpeechString`,
    /// the earliest callback that marks a word being spoken.
    var firstAudioMs: Double?
}

/// Internal seam around `AVSpeechSynthesizer`.
///
/// The production implementation drives the real synthesizer; tests inject a scripted runtime so
/// the lifecycle is deterministic on machines without voices or an audio stack.
protocol AppleSpeechRuntime: Sendable {
    /// Every installed voice, novelty voices last, otherwise best quality first and the system's
    /// choice for a locale ahead of its equals. The planner breaks ties by this order, so it
    /// decides who speaks when an application picks no voice.
    func voices() -> [AppleSpeechVoice]

    /// The installed voice with this identifier, without listing the others: a listing is too
    /// slow for the path between a tap and the audio.
    func voice(identifier: String) -> AppleSpeechVoice?

    /// The system's choice of voice for `locale`, or for the device's language when `nil`.
    func defaultVoice(locale: String?) -> AppleSpeechVoice?

    /// Loads `voice` on the playback synthesizer without audio or an audio session, so its first
    /// utterance starts sooner. Cancelling the calling task stops it.
    func warm(voice: AppleSpeechVoice) async throws

    /// Speaks `text` and returns once it has finished, with its timings when known.
    /// Cancelling the calling task stops the audio immediately and throws `CancellationError`.
    func speak(text: String, voice: AppleSpeechVoice) async throws -> SpokenAudio

    /// Renders `text` silently. Cancelling the calling task stops rendering and throws
    /// `CancellationError`.
    func render(text: String, voice: AppleSpeechVoice, maxBytes: Int) async throws -> RenderedSpeech
}

/// The one synthesizer playback uses, created at the first utterance. A new synthesizer loads its
/// voice again, which held the first word back by over a second on an iPhone.
///
/// It also keeps the session that used it last. The system delivers callbacks for a stopped
/// utterance on the main queue some time after `stopSpeaking`, and one that reaches a freed
/// synthesizer or delegate crashed the process (#251), so neither is freed while the system may
/// still call it: a session lives until the next one replaces it, and when the provider goes away
/// both are retired rather than released. A retired pair is stopped and then released on the main
/// queue, behind any callback already queued there, `SystemAppleSpeechRuntime.retirementGrace`
/// later, so providers created and discarded repeatedly hold only the synthesizers retired in the
/// last few seconds.
private final class PlaybackSynthesizer: @unchecked Sendable {
    private final class Retired: @unchecked Sendable {
        let lock = NSLock()
        var items: [ObjectIdentifier: (AVSpeechSynthesizer, AnyObject?)] = [:]
        var total = 0
    }

    private static let retired = Retired()

    /// Retired synthesizers not yet released, and every one retired so far in the process.
    static var retirement: (pending: Int, total: Int) {
        retired.lock.withLock { (retired.items.count, retired.total) }
    }

    private let lock = NSLock()
    private var synthesizer: AVSpeechSynthesizer?
    private var lastSession: AnyObject?

    func shared() -> AVSpeechSynthesizer {
        lock.withLock {
            if let synthesizer { return synthesizer }
            let created = AVSpeechSynthesizer()
            synthesizer = created
            return created
        }
    }

    /// Keeps `session` alive until a later session replaces it or the provider is released.
    func keep(_ session: AnyObject) {
        lock.withLock { lastSession = session }
    }

    deinit {
        guard let synthesizer else { return }
        let key = ObjectIdentifier(synthesizer)
        let session = lastSession
        Self.retired.lock.withLock {
            Self.retired.items[key] = (synthesizer, session)
            Self.retired.total += 1
        }
        Self.release(key)
    }

    /// Stops a retired synthesizer and releases it a grace period later. Nothing can still be
    /// speaking through it: a run holds its provider until it ends, so the provider is released
    /// only after its last utterance finished or was stopped. The stop is for a synthesizer that
    /// still reports speaking, which a simulator was seen to do, and its callbacks arrive within
    /// the grace period.
    private static func release(_ key: ObjectIdentifier) {
        DispatchQueue.main.async {
            let synthesizer = retired.lock.withLock { retired.items[key]?.0 }
            if synthesizer?.isSpeaking == true { synthesizer?.stopSpeaking(at: .immediate) }
            DispatchQueue.main.asyncAfter(deadline: .now() + SystemAppleSpeechRuntime.retirementGrace) {
                // Removed under the lock, freed after it.
                let item = retired.lock.withLock { retired.items.removeValue(forKey: key) }
                _ = item
            }
        }
    }
}

struct SystemAppleSpeechRuntime: AppleSpeechRuntime {
    /// How long a render may go without a new buffer: a host without an audio stack may never
    /// call back, and nothing else would end the run.
    static let renderStallTimeout: TimeInterval = 10
    /// How long an utterance may take to start. Without it a synthesizer that never calls back
    /// would hold the provider's turn until the caller cancels.
    static let speechStartTimeout: TimeInterval = 15
    /// How long a released provider's synthesizer is kept after it is stopped: longer than the
    /// system takes to deliver a stopped utterance's last callbacks.
    static let retirementGrace: TimeInterval = 5

    private let playback = PlaybackSynthesizer()

    /// Playback synthesizers retired by released providers: those not yet released, and the total.
    static var retiredSynthesizers: (pending: Int, total: Int) { PlaybackSynthesizer.retirement }

    func voices() -> [AppleSpeechVoice] {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let systemChoices = Set(
            Set(voices.map(\.language)).compactMap { AVSpeechSynthesisVoice(language: $0)?.identifier }
        )
        func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
            (Self.isNovelty(voice) ? 1_000 : 0) - voice.quality.rawValue * 10
                + (systemChoices.contains(voice.identifier) ? 0 : 1)
        }
        return voices
            .sorted { lhs, rhs in
                rank(lhs) != rank(rhs) ? rank(lhs) < rank(rhs) : lhs.identifier < rhs.identifier
            }
            .map(Self.described)
    }

    /// The plan bound this voice from the listing, so the listing decides when the direct lookup
    /// finds nothing; only then does the lookup cost a listing.
    func voice(identifier: String) -> AppleSpeechVoice? {
        (AVSpeechSynthesisVoice(identifier: identifier)
            ?? AVSpeechSynthesisVoice.speechVoices().first { $0.identifier == identifier })
            .map(Self.described)
    }

    func defaultVoice(locale: String?) -> AppleSpeechVoice? {
        AVSpeechSynthesisVoice(language: locale ?? AVSpeechSynthesisVoice.currentLanguageCode()).map(Self.described)
    }

    func warm(voice: AppleSpeechVoice) async throws {
        let session = RenderSession(
            utterance: utterance(text: "a", voice: voice),
            maxBytes: 1024 * 1024,
            synthesizer: playback.shared()
        )
        playback.keep(session)
        _ = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { session.start($0) }
        } onCancel: {
            session.stop()
        }
    }

    private static func described(_ voice: AVSpeechSynthesisVoice) -> AppleSpeechVoice {
        AppleSpeechVoice(
            identifier: voice.identifier,
            locale: voice.language,
            gender: voice.gender == .female ? .female : voice.gender == .male ? .male : nil,
            name: voice.name.isEmpty ? nil : voice.name
        )
    }

    private static func isNovelty(_ voice: AVSpeechSynthesisVoice) -> Bool {
        guard #available(iOS 17, macOS 14, *) else { return false }
        return voice.voiceTraits.contains(.isNoveltyVoice)
    }

    func speak(text: String, voice: AppleSpeechVoice) async throws -> SpokenAudio {
        let session = PlaybackSession(utterance: utterance(text: text, voice: voice), synthesizer: playback.shared())
        playback.keep(session)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { session.start($0) }
        } onCancel: {
            session.stop()
        }
    }

    func render(text: String, voice: AppleSpeechVoice, maxBytes: Int) async throws -> RenderedSpeech {
        let session = RenderSession(
            utterance: utterance(text: text, voice: voice),
            maxBytes: maxBytes,
            synthesizer: AVSpeechSynthesizer()
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { session.start($0) }
        } onCancel: {
            session.stop()
        }
    }

    private func utterance(text: String, voice: AppleSpeechVoice) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voice.identifier)
        return utterance
    }
}

/// One audible utterance on the shared synthesizer. The provider plays one at a time, so this
/// session owns the synthesizer until it settles. Callbacks are matched to its own utterance, so
/// a late one cannot reach a later session, and the first ending wins: anything the system
/// delivers after it is ignored.
private final class PlaybackSession: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let utterance: AVSpeechUtterance
    private let synthesizer: AVSpeechSynthesizer
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SpokenAudio, Error>?
    private var stopped = false
    private var settled = false
    private var issuedAt: Date?
    private var startedAt: Date?
    private var firstAudioMs: Double?
    private var interruptionObserver: NSObjectProtocol?
    private var startWatchdog: DispatchWorkItem?

    init(utterance: AVSpeechUtterance, synthesizer: AVSpeechSynthesizer) {
        self.utterance = utterance
        self.synthesizer = synthesizer
    }

    func start(_ continuation: CheckedContinuation<SpokenAudio, Error>) {
        let observer = makeInterruptionObserver()
        let alreadyStopped = lock.withLock {
            interruptionObserver = observer
            if !stopped { self.continuation = continuation }
            return stopped
        }
        guard !alreadyStopped else {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            continuation.resume(throwing: CancellationError())
            return
        }
        armStartWatchdog()
        synthesizer.delegate = self
        lock.withLock { issuedAt = Date() }
        synthesizer.speak(utterance)
        // A stop that landed since the check above found nothing to stop yet.
        if lock.withLock({ stopped }) { synthesizer.stopSpeaking(at: .immediate) }
    }

    func stop() {
        let owns = lock.withLock {
            stopped = true
            return !settled
        }
        // Once settled, the synthesizer may already be speaking a later utterance.
        if owns { synthesizer.stopSpeaking(at: .immediate) }
        settle(.failure(CancellationError()))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        guard utterance === self.utterance else { return }
        lock.withLock {
            startedAt = Date()
            startWatchdog?.cancel()
        }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        guard utterance === self.utterance else { return }
        let now = Date()
        lock.withLock {
            if firstAudioMs == nil, let issuedAt { firstAudioMs = now.timeIntervalSince(issuedAt) * 1000 }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard utterance === self.utterance else { return }
        let spoken = lock.withLock {
            SpokenAudio(durationMs: startedAt.map { Date().timeIntervalSince($0) * 1000 }, firstAudioMs: firstAudioMs)
        }
        settle(.success(spoken))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard utterance === self.utterance else { return }
        settle(.failure(CancellationError()))
    }

    private func settle(_ result: Result<SpokenAudio, Error>) {
        let (continuation, observer) = lock.withLock {
            defer {
                self.continuation = nil
                interruptionObserver = nil
                settled = true
            }
            startWatchdog?.cancel()
            return (self.continuation, interruptionObserver)
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        continuation?.resume(with: result)
    }

    private func armStartWatchdog() {
        let item = DispatchWorkItem { [weak self] in
            self?.synthesizer.stopSpeaking(at: .immediate)
            self?.settle(.failure(createUnavailable(
                message: "The synthesizer did not start speaking within the timeout.",
                details: ["code": JSONAny("speech_start_stalled")]
            )))
        }
        lock.withLock { startWatchdog = item }
        DispatchQueue.global().asyncAfter(deadline: .now() + SystemAppleSpeechRuntime.speechStartTimeout, execute: item)
    }

    /// An audio session interruption pauses the synthesizer and may never resume it, which would
    /// leave the run open forever. It has already been audible, so it ends as a failure.
    private func makeInterruptionObserver() -> NSObjectProtocol? {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        return NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            guard type == .began, let self else { return }
            self.synthesizer.stopSpeaking(at: .immediate)
            self.settle(.failure(createUnavailable(
                message: "Speech playback was interrupted by the system.",
                details: ["code": JSONAny("speech_interrupted")]
            )))
        }
        #else
        return nil
        #endif
    }
}

/// One silent render through `AVSpeechSynthesizer.write(_:toBufferCallback:)`, converting each
/// buffer to 16-bit PCM from its first channel.
///
/// The synthesizer sends an empty buffer at each of its internal chunk boundaries, not only at the
/// end, so an empty buffer is not the end of the audio: ending there cut long text off after its
/// first chunk (#251). The render ends on `didFinish`, which the synthesizer sends for a written
/// utterance too, after its last buffer.
private final class RenderSession: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let utterance: AVSpeechUtterance
    private let maxBytes: Int
    private let synthesizer: AVSpeechSynthesizer
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RenderedSpeech, Error>?
    private var stopped = false
    private var samples = Data()
    private var sampleRate: Int?
    private var watchdog: DispatchWorkItem?

    init(utterance: AVSpeechUtterance, maxBytes: Int, synthesizer: AVSpeechSynthesizer) {
        self.utterance = utterance
        self.maxBytes = maxBytes
        self.synthesizer = synthesizer
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard utterance === self.utterance else { return }
        finish()
    }

    func start(_ continuation: CheckedContinuation<RenderedSpeech, Error>) {
        let alreadyStopped = lock.withLock {
            if !stopped { self.continuation = continuation }
            return stopped
        }
        guard !alreadyStopped else {
            continuation.resume(throwing: CancellationError())
            return
        }
        armWatchdog()
        synthesizer.delegate = self
        synthesizer.write(utterance) { [self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return }
            append(pcm)
        }
        // A stop that landed since the check above found nothing to stop yet.
        if lock.withLock({ stopped }) { synthesizer.stopSpeaking(at: .immediate) }
    }

    func stop() {
        lock.withLock { stopped = true }
        synthesizer.stopSpeaking(at: .immediate)
        settle(.failure(CancellationError()))
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        let bytes = Self.int16Samples(buffer)
        let overLimit = lock.withLock {
            sampleRate = sampleRate ?? Int(buffer.format.sampleRate)
            samples.append(bytes)
            return samples.count > maxBytes
        }
        if overLimit {
            synthesizer.stopSpeaking(at: .immediate)
            settle(.failure(createUnavailable(
                message: "The rendered speech exceeds the artifact size limit.",
                details: ["code": JSONAny("artifact_too_large")]
            )))
        } else {
            armWatchdog()
        }
    }

    private func finish() {
        let rendered = lock.withLock { () -> RenderedSpeech? in
            guard let sampleRate, !samples.isEmpty else { return nil }
            return RenderedSpeech(samples: samples, sampleRate: sampleRate)
        }
        if let rendered {
            settle(.success(rendered))
        } else {
            settle(.failure(createUnavailable(
                message: "The synthesizer produced no audio.",
                details: ["code": JSONAny("speech_render_failed")]
            )))
        }
    }

    private func settle(_ result: Result<RenderedSpeech, Error>) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            watchdog?.cancel()
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    private func armWatchdog() {
        let item = DispatchWorkItem { [weak self] in
            self?.synthesizer.stopSpeaking(at: .immediate)
            self?.settle(.failure(createUnavailable(
                message: "The synthesizer delivered no audio within the timeout.",
                details: ["code": JSONAny("speech_render_failed")]
            )))
        }
        let live = lock.withLock { () -> Bool in
            watchdog?.cancel()
            watchdog = item
            return continuation != nil
        }
        // A buffer can arrive after the render ended; it must not restart the clock.
        guard live else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + SystemAppleSpeechRuntime.renderStallTimeout, execute: item)
    }

    private static func int16Samples(_ buffer: AVAudioPCMBuffer) -> Data {
        let frames = Int(buffer.frameLength)
        var out = Data(capacity: frames * 2)
        func append(_ value: Int16) {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        if let channel = buffer.int16ChannelData?[0] {
            for index in 0..<frames { append(channel[index]) }
        } else if let channel = buffer.floatChannelData?[0] {
            for index in 0..<frames {
                append(Int16(max(-1, min(1, channel[index])) * Float(Int16.max)))
            }
        }
        return out
    }
}
