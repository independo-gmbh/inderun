import Foundation
import IndeRunContracts

/// Scripts a ``FixtureNeuralSpeechRuntime``.
public struct FixtureNeuralSpeechRuntimeOptions: Sendable {
    /// What `availability` reports. Default available.
    public var availability: NeuralSpeechAvailability
    /// What `prepare` reports. Default available.
    public var prepareResult: NeuralSpeechAvailability
    /// Synthetic duration per character (UTF-16 code unit, as on Web) of the sentence. Default 50.
    public var msPerCharacter: Double
    /// Duration of one chunk. Default 100.
    public var chunkMs: Double
    /// Wall delay before each chunk. Default 0.
    public var delayMs: Int
    /// Fail with `NeuralSpeechRuntimeError(.internalFailure)` after this many chunks of a sentence.
    public var failAfterChunks: Int?

    public init(
        availability: NeuralSpeechAvailability = NeuralSpeechAvailability(available: true),
        prepareResult: NeuralSpeechAvailability = NeuralSpeechAvailability(available: true),
        msPerCharacter: Double = 50,
        chunkMs: Double = 100,
        delayMs: Int = 0,
        failAfterChunks: Int? = nil
    ) {
        self.availability = availability
        self.prepareResult = prepareResult
        self.msPerCharacter = msPerCharacter
        self.chunkMs = chunkMs
        self.delayMs = delayMs
        self.failAfterChunks = failAfterChunks
    }
}

/// Deterministic runtime for tests and demos: a 440 Hz sine at -14 dBFS with phase continuous
/// across the chunks of one sentence, `msPerCharacter` times the sentence length long, in chunks of
/// `chunkMs` (the last one partial when the duration is not a multiple of it), at the package's
/// sample rate. Chunks are produced on demand, in the consuming task: cancelling it ends the
/// iteration between chunks without an error. Records every call. Mirrors
/// `createFixtureNeuralSpeechRuntime` on Web.
public final class FixtureNeuralSpeechRuntime: NeuralSpeechRuntime, @unchecked Sendable {
    private static let toneHz = 440.0
    /// About -14 dBFS.
    private static let amplitude = 0.2 * 32767

    private let options: FixtureNeuralSpeechRuntimeOptions
    private let lock = NSLock()
    // swiftlint:disable large_tuple
    private var recorded: [(text: String, locale: String, voiceId: String)] = []
    private var prepares = 0
    private var availabilities = 0

    public init(options: FixtureNeuralSpeechRuntimeOptions = FixtureNeuralSpeechRuntimeOptions()) {
        self.options = options
    }

    /// Every sentence handed to `synthesize`, in call order.
    public var synthesized: [(text: String, locale: String, voiceId: String)] { lock.withLock { recorded } }
    // swiftlint:enable large_tuple
    public var prepareCalls: Int { lock.withLock { prepares } }
    public var availabilityCalls: Int { lock.withLock { availabilities } }

    public func availability(_ modelPackage: ModelPackage) async -> NeuralSpeechAvailability {
        lock.withLock { availabilities += 1 }
        return options.availability
    }

    public func prepare(_ modelPackage: ModelPackage) async -> NeuralSpeechAvailability {
        lock.withLock { prepares += 1 }
        return options.prepareResult
    }

    public func synthesize(_ input: NeuralSpeechSynthesisInput) -> AsyncThrowingStream<PcmChunk, Error> {
        lock.withLock { recorded.append((input.text, input.locale, input.voiceId)) }
        let sampleRate = input.modelPackage.speech?.sampleRate ?? 24000
        let tone = FixtureTone(
            sampleRate: sampleRate,
            totalFrames: Int((Double(input.text.utf16.count) * options.msPerCharacter * Double(sampleRate) / 1000).rounded()),
            chunkFrames: max(1, Int((options.chunkMs * Double(sampleRate) / 1000).rounded())),
            delayMs: options.delayMs,
            failAfterChunks: options.failAfterChunks
        )
        return AsyncThrowingStream(unfolding: { try await tone.next() })
    }

    /// The chunks of one sentence, produced when asked for.
    private final class FixtureTone: @unchecked Sendable {
        private let sampleRate: Int
        private let totalFrames: Int
        private let chunkFrames: Int
        private let delayMs: Int
        private let failAfterChunks: Int?
        /// One period of the tone: it repeats every `sampleRate / gcd(sampleRate, 440)` frames, so
        /// the phase stays continuous without computing a sine per frame.
        private let period: [Int16]
        private let lock = NSLock()
        private var produced = 0
        private var chunks = 0

        init(sampleRate: Int, totalFrames: Int, chunkFrames: Int, delayMs: Int, failAfterChunks: Int?) {
            let step = 2 * Double.pi * FixtureNeuralSpeechRuntime.toneHz / Double(sampleRate)
            let frames = sampleRate / Self.gcd(sampleRate, Int(FixtureNeuralSpeechRuntime.toneHz))
            self.period = (0 ..< frames).map { Int16((FixtureNeuralSpeechRuntime.amplitude * sin(step * Double($0))).rounded()) }
            self.sampleRate = sampleRate
            self.totalFrames = totalFrames
            self.chunkFrames = chunkFrames
            self.delayMs = delayMs
            self.failAfterChunks = failAfterChunks
        }

        func next() async throws -> PcmChunk? {
            let state = lock.withLock { (produced, chunks) }
            guard !Task.isCancelled, state.0 < totalFrames else { return nil }
            if let failAfterChunks, state.1 >= failAfterChunks {
                throw NeuralSpeechRuntimeError(kind: .internalFailure, message: "fixture synthesis failed")
            }
            if delayMs > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                } catch {
                    return nil
                }
                if Task.isCancelled { return nil }
            }
            let start = state.0
            let frames = min(chunkFrames, totalFrames - start)
            var samples: [Int16] = []
            samples.reserveCapacity(frames)
            var position = start % period.count
            while samples.count < frames {
                let count = min(frames - samples.count, period.count - position)
                samples.append(contentsOf: period[position ..< position + count])
                position = 0
            }
            lock.withLock {
                produced = start + frames
                chunks += 1
            }
            return PcmChunk(samples: samples, sampleRate: sampleRate, isLast: start + frames >= totalFrames)
        }

        private static func gcd(_ lhs: Int, _ rhs: Int) -> Int {
            rhs == 0 ? max(lhs, 1) : gcd(rhs, lhs % rhs)
        }
    }
}
