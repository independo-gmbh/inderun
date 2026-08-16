import Foundation
import IndeRunContracts

/// Configuration for the deterministic fixture runtime.
public struct FixtureOnnxRuntimeOptions: Sendable {
    /// Availability snapshot returned by `prepare`. Defaults to `{ available: true }`.
    public var availability: OnnxRuntimeAvailability
    /// Text or full output produced by `generate`. Defaults to a deterministic echo.
    public var respond: (@Sendable (OnnxGenerationInput) -> OnnxGenerationOutput)?
    /// Error thrown by `generate` instead of producing output.
    public var failWith: OnnxRuntimeError?
    /// Artificial generation delay, used to exercise timeouts via task cancellation.
    public var delay: Duration?

    public init(
        availability: OnnxRuntimeAvailability = OnnxRuntimeAvailability(available: true),
        respond: (@Sendable (OnnxGenerationInput) -> OnnxGenerationOutput)? = nil,
        failWith: OnnxRuntimeError? = nil,
        delay: Duration? = nil
    ) {
        self.availability = availability
        self.respond = respond
        self.failWith = failWith
        self.delay = delay
    }
}

/// Creates a deterministic in-memory ONNX runtime.
///
/// This is the test seam mandated by the ONNX Runtime provider family specification: it proves
/// the model package contract, capability checks, routing, and error normalization without
/// depending on a real ONNX runtime, and it lets apps exercise the on-device route in demos
/// without bundling a model. It is deliberately public/importable, matching the Web member's
/// `createFixtureOnnxRuntime` rather than keeping fixtures private to the test target.
///
/// - Parameter options: Scripted availability, response, failure, and delay behavior.
public func createFixtureOnnxRuntime(options: FixtureOnnxRuntimeOptions = FixtureOnnxRuntimeOptions()) -> any OnnxGenAiRuntime {
    FixtureOnnxGenAiRuntime(options: options)
}

private struct FixtureOnnxGenAiRuntime: OnnxGenAiRuntime {
    let options: FixtureOnnxRuntimeOptions

    func prepare(_ modelPackage: ModelPackage) async -> OnnxRuntimeAvailability {
        options.availability
    }

    func generate(_ input: OnnxGenerationInput) async throws -> OnnxGenerationOutput {
        if let delay = options.delay {
            try await Task.sleep(for: delay)
        }

        try Task.checkCancellation()

        if let failWith = options.failWith {
            throw failWith
        }

        if let respond = options.respond {
            return respond(input)
        }

        return OnnxGenerationOutput(text: createFixtureText(modelPackage: input.modelPackage, messages: input.messages))
    }
}

private func createFixtureText(modelPackage: ModelPackage, messages: [OnnxGenerationMessage]) -> String {
    let lastUserMessage = messages.last { $0.role == .user }
    let prompt = lastUserMessage?.content ?? ""
    return "[fixture:\(modelPackage.id)] \(prompt)"
}
