import Foundation
import IndeRunContracts

/// Availability snapshot reported by an ONNX text generation runtime.
///
/// The `reason` string uses the provider-internal capability vocabulary documented in
/// `docs/architecture/onnx-runtime-provider-family.md`. It is not a public enum: the provider
/// flattens every failure into a single `capability_unavailable` route rejection and carries the
/// reason as human-readable text.
public struct OnnxRuntimeAvailability: Equatable, Sendable {
    /// Whether the runtime can execute the given model package on this host right now.
    public let available: Bool
    /// Human-readable detail describing why the runtime is unavailable.
    public let reason: String?

    public init(available: Bool, reason: String? = nil) {
        self.available = available
        self.reason = reason
    }
}

/// Normalized conversation turn handed to an ONNX text generation runtime.
public struct OnnxGenerationMessage: Equatable, Sendable {
    /// The role of the author of this turn.
    public let role: Role
    /// Plain-text content of this turn.
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// Normalized generation request handed to an ONNX text generation runtime.
public struct OnnxGenerationInput: Sendable {
    /// The model package the provider was configured with.
    public let modelPackage: ModelPackage
    /// Conversation turns, normalized from `prompt` or `messages` by the provider.
    public let messages: [OnnxGenerationMessage]
    /// Optional generation controls copied from the task request.
    public let generation: Generation?

    public init(modelPackage: ModelPackage, messages: [OnnxGenerationMessage], generation: Generation? = nil) {
        self.modelPackage = modelPackage
        self.messages = messages
        self.generation = generation
    }
}

/// Normalized generation result returned by an ONNX text generation runtime.
public struct OnnxGenerationOutput: Sendable {
    /// The generated text.
    public let text: String
    /// Optional normalized finish reason; the provider defaults to `.stop`.
    public let finishReason: FinishReason?
    /// Optional token accounting, when the runtime reports it.
    public let usage: TaskResultUsage?

    public init(text: String, finishReason: FinishReason? = nil, usage: TaskResultUsage? = nil) {
        self.text = text
        self.finishReason = finishReason
        self.usage = usage
    }
}

/// Failure category a runtime can signal so the provider maps it onto the IndeRun error taxonomy.
///
/// - `capability`: model or runtime cannot serve this request (`CapabilityMismatch`).
/// - `unavailable`: runtime initialization failure or resource exhaustion (`Unavailable`).
/// - `timeout`: generation exceeded its budget or was cancelled (`Timeout`).
/// - `internal`: unexpected runtime failure (`Internal`).
public enum OnnxRuntimeErrorKind: Sendable {
    case capability
    case unavailable
    case timeout
    case internalFailure
}

/// Error type ONNX runtime implementations throw to steer IndeRun error normalization.
///
/// Anything else thrown by a runtime is normalized to `Internal`.
public struct OnnxRuntimeError: Error, Sendable {
    /// Failure category used by the provider to select an IndeRun error class.
    public let kind: OnnxRuntimeErrorKind
    /// Human-readable failure detail.
    public let message: String
    /// Optional underlying error description captured for telemetry details.
    public let originalErrorDescription: String?

    public init(kind: OnnxRuntimeErrorKind, message: String, originalError: Error? = nil) {
        self.kind = kind
        self.message = message
        self.originalErrorDescription = originalError.map { String(describing: $0) }
    }
}

/// Injectable seam between the IndeRun Apple ONNX provider and the actual on-device runtime.
///
/// IndeRun ships a default runtime backed by the official ONNX Runtime SPM bindings plus
/// `swift-transformers` tokenization, and a deterministic fixture for tests and demos.
/// Applications can supply their own implementation (for example one wrapping ONNX Runtime
/// GenAI once it is SPM-installable, or a KV-cached decode loop) without touching the provider.
public protocol OnnxGenAiRuntime: Sendable {
    /// Checks runtime package availability, execution backend availability, and model readiness.
    /// Implementations must resolve with an availability snapshot rather than throwing.
    func prepare(_ modelPackage: ModelPackage) async -> OnnxRuntimeAvailability

    /// Runs one Mode-1 generation.
    func generate(_ input: OnnxGenerationInput) async throws -> OnnxGenerationOutput
}
