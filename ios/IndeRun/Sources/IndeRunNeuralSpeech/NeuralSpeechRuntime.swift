import Foundation
import IndeRunContracts

/// Availability snapshot reported by a ``NeuralSpeechRuntime``.
public struct NeuralSpeechAvailability: Sendable, Equatable {
    public let available: Bool
    /// Human-readable detail; the provider surfaces it verbatim when `available` is `false`.
    public let reason: String?

    public init(available: Bool, reason: String? = nil) {
        self.available = available
        self.reason = reason
    }
}

/// One sentence handed to a ``NeuralSpeechRuntime``.
public struct NeuralSpeechSynthesisInput: Sendable {
    public let modelPackage: ModelPackage
    public let text: String
    public let locale: String
    public let voiceId: String

    public init(modelPackage: ModelPackage, text: String, locale: String, voiceId: String) {
        self.modelPackage = modelPackage
        self.text = text
        self.locale = locale
        self.voiceId = voiceId
    }
}

/// Executes a speech model package for ``NeuralSpeechProvider``.
///
/// `availability` is also where an unknown `pipeline` is refused, with the reason verbatim; it must
/// not load anything. `limits.memBytes` is refused there by the composed runtime of
/// `IndeRunOnnxProviders` (`OnnxNeuralSpeechRuntime`), against the device's physical memory; the
/// pipeline runtimes (`ArticulinoRuntime`) do not check it. `prepare` loads the model and is
/// idempotent on success: the same package (`id@version`) prepared again returns the remembered
/// outcome; only a failed prepare is retried. `synthesize` is called
/// once per sentence and returns that sentence's chunks; cancelling the consuming task, or
/// abandoning the iteration, ends it without an error. On a timeout the provider cancels the
/// pull; a stream that honours cancellation returns at once, a synchronous call is waited for, so
/// inference should run where cancellation can reach it and stay bounded to that sentence.
///
/// The provider consumes (copies or hands to the host) a chunk's samples before the yield returns,
/// so a runtime may reuse its buffer afterwards.
///
/// `synthesize` may be called concurrently: artifact runs do not wait for the playback turn, and two
/// providers may share one runtime instance. A runtime must serialize or isolate its own sessions.
public protocol NeuralSpeechRuntime: Sendable {
    func availability(_ modelPackage: ModelPackage) async -> NeuralSpeechAvailability
    func prepare(_ modelPackage: ModelPackage) async -> NeuralSpeechAvailability
    func synthesize(_ input: NeuralSpeechSynthesisInput) -> AsyncThrowingStream<PcmChunk, Error>
}

/// Failure category a runtime signals so the provider maps it onto the IndeRun error taxonomy.
public enum NeuralSpeechRuntimeErrorKind: Sendable {
    case capability
    case unavailable
    case timeout
    case internalFailure
}

/// The error neural speech runtimes throw to steer IndeRun error normalization. Anything else a
/// runtime throws is normalized to `Internal`.
public struct NeuralSpeechRuntimeError: Error, Sendable {
    public let kind: NeuralSpeechRuntimeErrorKind
    public let message: String
    /// The underlying error's description, carried as `details.originalError`.
    public let originalErrorDescription: String?

    public init(kind: NeuralSpeechRuntimeErrorKind, message: String, originalError: Error? = nil) {
        self.kind = kind
        self.message = message
        self.originalErrorDescription = originalError.map { String(describing: $0) }
    }
}
