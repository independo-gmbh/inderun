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

    /// Speaks `text` and returns once it has finished, with how long it played when known.
    /// Cancelling the calling task stops the audio immediately and throws `CancellationError`.
    func speak(text: String, voice: AppleSpeechVoice) async throws -> Double?

    /// Renders `text` silently. Cancelling the calling task stops rendering and throws
    /// `CancellationError`.
    func render(text: String, voice: AppleSpeechVoice, maxBytes: Int) async throws -> RenderedSpeech
}

/// A canonical 44-byte RIFF/WAVE header (PCM, mono, 16-bit) followed by the samples.
enum SpeechWAV {
    static func encode(_ speech: RenderedSpeech) -> Data {
        var data = Data()
        func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        let byteRate = UInt32(speech.sampleRate * 2)
        append("RIFF")
        append32(UInt32(36 + speech.samples.count))
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1) // PCM
        append16(1) // mono
        append32(UInt32(speech.sampleRate))
        append32(byteRate)
        append16(2) // block align
        append16(16) // bits per sample
        append("data")
        append32(UInt32(speech.samples.count))
        data.append(speech.samples)
        return data
    }
}

/// The one synthesizer playback uses, created at the first utterance. A new synthesizer loads its
/// voice again, which held the first word back by over a second on an iPhone.
private final class PlaybackSynthesizer: @unchecked Sendable {
    private let lock = NSLock()
    private var synthesizer: AVSpeechSynthesizer?

    func shared() -> AVSpeechSynthesizer {
        lock.withLock {
            if let synthesizer { return synthesizer }
            let created = AVSpeechSynthesizer()
            synthesizer = created
            return created
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

    private let playback = PlaybackSynthesizer()

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

    func speak(text: String, voice: AppleSpeechVoice) async throws -> Double? {
        let session = PlaybackSession(utterance: utterance(text: text, voice: voice), synthesizer: playback.shared())
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
    private var continuation: CheckedContinuation<Double?, Error>?
    private var stopped = false
    private var settled = false
    private var startedAt: Date?
    private var interruptionObserver: NSObjectProtocol?
    private var startWatchdog: DispatchWorkItem?

    init(utterance: AVSpeechUtterance, synthesizer: AVSpeechSynthesizer) {
        self.utterance = utterance
        self.synthesizer = synthesizer
    }

    func start(_ continuation: CheckedContinuation<Double?, Error>) {
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

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard utterance === self.utterance else { return }
        let durationMs = lock.withLock { startedAt.map { Date().timeIntervalSince($0) * 1000 } }
        settle(.success(durationMs))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard utterance === self.utterance else { return }
        settle(.failure(CancellationError()))
    }

    private func settle(_ result: Result<Double?, Error>) {
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
/// buffer to 16-bit PCM from its first channel. A zero-length buffer ends the utterance.
private final class RenderSession: @unchecked Sendable {
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
        synthesizer.write(utterance) { [self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                finish()
            } else {
                append(pcm)
            }
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
