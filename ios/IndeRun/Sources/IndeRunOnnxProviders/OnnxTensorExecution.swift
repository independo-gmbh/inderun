import Foundation
import OnnxRuntimeBindings

func makeInt64Tensor(_ values: [Int64], shape: [Int]) throws -> ORTValue {
    let data = NSMutableData(bytes: values, length: values.count * MemoryLayout<Int64>.size)
    return try ORTValue(tensorData: data, elementType: .int64, shape: shape.map { NSNumber(value: $0) })
}

/// Runs `session.run` on the dedicated execution queue (see `OnnxExecutionQueue`) and wraps any
/// raw ORT failure (missing/mistyped input, shape mismatch, and similar) into an
/// `OnnxRuntimeError` carrying the original error as detail, rather than letting an opaque native
/// error propagate uncaught up to the provider's generic "execution failed" fallback.
func runOnnxSession(
    _ session: ORTSession,
    inputs: [String: ORTValue],
    outputNames: Set<String>
) async throws -> [String: ORTValue] {
    do {
        return try await OnnxExecutionQueue.shared.run {
            try session.run(withInputs: inputs, outputNames: outputNames, runOptions: nil)
        }
    } catch let error as OnnxRuntimeError {
        throw error
    } catch {
        throw OnnxRuntimeError(kind: .unavailable, message: "ONNX Runtime session execution failed.", originalError: error)
    }
}

/// Runs ONNX Runtime session creation and inference on a dedicated serial queue rather than the
/// Swift Concurrency cooperative thread pool: `ORTSession.init` and `ORTSession.run` are blocking
/// synchronous calls, and Swift Concurrency's own guidance is not to block its limited cooperative
/// threads with such work. A single shared queue is sufficient -- a single generation is inherently
/// sequential token-by-token, and the queue also gives cancellation-adjacent work one well-defined
/// place to execute.
final class OnnxExecutionQueue: @unchecked Sendable {
    static let shared = OnnxExecutionQueue()

    private let queue = DispatchQueue(label: "app.independo.inderun.onnx.execution", qos: .userInitiated)

    func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
