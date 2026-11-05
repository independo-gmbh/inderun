import Foundation

/// One block of mono signed 16-bit PCM produced by a ``NeuralSpeechRuntime``.
///
/// `sampleRate` must equal the package's `speech.sampleRate`: the provider never resamples and
/// treats any other rate as an internal error.
public struct PcmChunk: Sendable, Equatable {
    public let samples: [Int16]
    public let sampleRate: Int
    /// `true` on the final chunk of one sentence.
    public let isLast: Bool

    public init(samples: [Int16], sampleRate: Int, isLast: Bool) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.isLast = isLast
    }
}
