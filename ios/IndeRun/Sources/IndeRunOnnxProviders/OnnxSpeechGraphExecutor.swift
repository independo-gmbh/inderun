import Foundation
import OnnxRuntimeBindings

/// A loaded graph with the output names read once at load.
private struct LoadedSpeechGraph {
    let session: ORTSession
    let outputNames: Set<String>
}

/// Runs the graphs of a speech model package through ONNX Runtime, on the CPU execution provider
/// (CoreML cannot compile the Articulino graphs). Sessions are created and run on
/// `OnnxExecutionQueue`, one per role, so graph calls are serialized; intra-op spinning is off, so
/// the worker threads sleep between graph calls. `load` replaces the loaded graphs; a run that
/// already holds a replaced session keeps it alive until it returns. ORT has no boolean tensor
/// element type in this binding, so the tensors are f32 or i64 only (see ``SpeechTensor``).
public final class OnnxSpeechGraphExecutor: SpeechGraphExecutor, @unchecked Sendable {
    private let directory: URL
    private let threads: Int
    private let lock = NSLock()
    private var graphs: [String: LoadedSpeechGraph] = [:]

    public init(directory: URL, threads: Int? = nil) {
        self.directory = directory
        self.threads = max(1, threads ?? min(4, ProcessInfo.processInfo.activeProcessorCount))
    }

    public func load(graphs files: [String: String]) async throws {
        let env: ORTEnv
        do {
            env = try SharedOnnxEnvironment.get()
        } catch {
            throw NeuralSpeechRuntimeError(kind: .unavailable, message: "graph failed to load: environment: \(error)", originalError: error)
        }
        var loaded: [String: LoadedSpeechGraph] = [:]
        for (role, file) in files.sorted(by: { $0.key < $1.key }) {
            let path = directory.appendingPathComponent(file).path
            let threads = self.threads
            do {
                try checkPackageFileName(file)
                loaded[role] = try await OnnxExecutionQueue.shared.run {
                    guard FileManager.default.fileExists(atPath: path) else {
                        throw NeuralSpeechRuntimeError(kind: .unavailable, message: "model files missing: \(file)")
                    }
                    let options = try ORTSessionOptions()
                    try options.setIntraOpNumThreads(Int32(threads))
                    try options.addConfigEntry(withKey: "session.intra_op.allow_spinning", value: "0")
                    let session = try ORTSession(env: env, modelPath: path, sessionOptions: options)
                    return LoadedSpeechGraph(session: session, outputNames: Set(try session.outputNames()))
                }
            } catch {
                let message = (error as? NeuralSpeechRuntimeError)?.message ?? error.localizedDescription
                throw NeuralSpeechRuntimeError(
                    kind: .unavailable, message: "graph failed to load: \(role): \(message)", originalError: error
                )
            }
        }
        lock.withLock { graphs = loaded }
    }

    public func run(role: String, inputs: [String: SpeechTensor]) async throws -> [String: SpeechTensor] {
        guard let graph = lock.withLock({ graphs[role] }) else {
            throw NeuralSpeechRuntimeError(kind: .internalFailure, message: "graph not loaded: \(role)")
        }
        return try await OnnxExecutionQueue.shared.run {
            let outputs: [String: ORTValue]
            do {
                let values = try inputs.mapValues(makeORTValue)
                outputs = try graph.session.run(withInputs: values, outputNames: graph.outputNames, runOptions: nil)
            } catch let error as NeuralSpeechRuntimeError {
                throw error
            } catch {
                throw NeuralSpeechRuntimeError(
                    kind: .unavailable, message: "graph failed: \(role): \(error.localizedDescription)", originalError: error
                )
            }
            var result: [String: SpeechTensor] = [:]
            for (name, value) in outputs {
                do {
                    result[name] = try makeSpeechTensor(value)
                } catch {
                    throw NeuralSpeechRuntimeError(
                        kind: .internalFailure, message: "graph output unsupported: \(role).\(name)", originalError: error
                    )
                }
            }
            return result
        }
    }

    public func close() async {
        lock.withLock { graphs = [:] }
    }
}

func makeORTValue(_ tensor: SpeechTensor) throws -> ORTValue {
    let shape = tensor.shape.map { NSNumber(value: $0) }
    switch tensor.data {
    case let .f32(values):
        let data = NSMutableData(bytes: values, length: values.count * MemoryLayout<Float>.size)
        return try ORTValue(tensorData: data, elementType: .float, shape: shape)
    case let .i64(values):
        return try makeInt64Tensor(values, shape: tensor.shape)
    }
}

func makeSpeechTensor(_ value: ORTValue) throws -> SpeechTensor {
    let info = try value.tensorTypeAndShapeInfo()
    let shape = info.shape.map { $0.intValue }
    let bytes = try value.tensorData() as Data
    switch info.elementType {
    case .float:
        let values = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return SpeechTensor(shape: shape, data: .f32(values))
    case .int64:
        let values = bytes.withUnsafeBytes { Array($0.bindMemory(to: Int64.self)) }
        return SpeechTensor(shape: shape, data: .i64(values))
    default:
        throw NeuralSpeechRuntimeError(kind: .internalFailure, message: "unsupported element type \(info.elementType.rawValue)")
    }
}
