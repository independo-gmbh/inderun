import Foundation
import IndeRunContracts

/// How ready a runtime's model is before the provider has loaded it (ADR 019).
public enum NeuralSpeechReadiness: String, Sendable, Equatable {
    /// A `prepare` is required before a run can succeed.
    case notPrepared = "not_prepared"
    /// A run works, but the first one is slow.
    case cold
}

/// Availability snapshot reported by a ``NeuralSpeechRuntime``.
public struct NeuralSpeechAvailability: Sendable, Equatable {
    public let available: Bool
    /// Human-readable detail; the provider surfaces it verbatim when `available` is `false`.
    public let reason: String?
    /// Optional hint, reported until the provider has loaded the model itself; `nil` keeps the
    /// provider's own `cold`.
    public let readiness: NeuralSpeechReadiness?

    public init(available: Bool, reason: String? = nil, readiness: NeuralSpeechReadiness? = nil) {
        self.available = available
        self.reason = reason
        self.readiness = readiness
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

    /// Optional pre-split hook: rewrites the request's whole text into the form the model should
    /// speak (for example German numbers into words), before the provider splits it into sentences.
    /// Called once per request, on the whole text, with the locale the voice speaks. Synchronous and
    /// non-throwing: the shared core's C call cannot fail. The default returns `text` unchanged.
    func normalizeText(_ modelPackage: ModelPackage, text: String, locale: String) -> String

    /// Releases what the runtime holds (loaded models, sessions). Terminal and idempotent: concurrent
    /// calls share one close, and a later call returns at once. Once called, nothing is created or
    /// loaded any more: `availability` and `prepare` report unavailable with the reason
    /// `runtime closed`, `synthesize` fails with ``NeuralSpeechRuntimeError`` (kind `.unavailable`,
    /// message `runtime closed`, code `runtime_closed`), and `normalizeText` returns the text unchanged.
    /// A synthesis in flight ends at its next graph boundary with the same error, unless its last
    /// chunk was already delivered (it completes) or its consumer cancelled (cancellation wins, the
    /// stream ends without an error). Graphs are released only after the graph calls in flight have
    /// returned. The default does nothing.
    func close() async
}

extension NeuralSpeechRuntime {
    public func close() async {}

    public func normalizeText(_ modelPackage: ModelPackage, text: String, locale: String) -> String { text }
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
    /// A stable machine-readable code the provider carries as `details.code`, for example
    /// `runtime_closed`; `nil` when the failure has none.
    public let code: String?

    public init(kind: NeuralSpeechRuntimeErrorKind, message: String, originalError: Error? = nil, code: String? = nil) {
        self.kind = kind
        self.message = message
        self.code = code
        self.originalErrorDescription = originalError.map { String(describing: $0) }
    }
}
