import Foundation
import IndeRunContracts

/// What the composed runtimes of `IndeRunOnnxProviders` and `IndeRunCoreAIProviders` share: the
/// `limits.memBytes` refusal and the stream that wraps one sentence's synthesis.
package enum ComposedNeuralSpeechRuntime {
    /// The refusal reason when the package's `limits.memBytes` exceeds the device memory
    /// (`deviceMemoryBytes`, default `ProcessInfo.physicalMemory`); `nil` when it fits or declares none.
    package static func memoryRefusal(_ modelPackage: ModelPackage, deviceMemoryBytes: (@Sendable () -> UInt64)?) -> String? {
        guard let needed = modelPackage.limits?.memBytes, needed > 0 else { return nil }
        let device = deviceMemoryBytes?() ?? ProcessInfo.processInfo.physicalMemory
        guard UInt64(needed) > device else { return nil }
        return "insufficient memory: package needs \(needed) bytes, device has \(device) bytes"
    }

    /// Runs `body` as one sentence's stream: it finishes when `body` returns, cancelling the consumer
    /// cancels `body`, and a cancelled `body` ends the stream without an error.
    package static func stream(
        _ body: @escaping @Sendable (AsyncThrowingStream<PcmChunk, Error>.Continuation) async throws -> Void
    ) -> AsyncThrowingStream<PcmChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await body(continuation)
                    continuation.finish()
                } catch {
                    if Task.isCancelled { continuation.finish() } else { continuation.finish(throwing: error) }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
