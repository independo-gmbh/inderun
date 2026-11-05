import Foundation

/// The element data of a ``SpeechTensor``.
public enum SpeechTensorData: Sendable, Equatable {
    case f32([Float])
    case i64([Int64])
}

/// A named tensor exchanged with a ``SpeechGraphExecutor``.
public struct SpeechTensor: Sendable, Equatable {
    public let shape: [Int]
    public let data: SpeechTensorData

    public init(shape: [Int], data: SpeechTensorData) {
        self.shape = shape
        self.data = data
    }
}

/// Runs the graphs of a speech model package, one role at a time (`speech.graphs` maps each role
/// to its file). Implemented by the ONNX Runtime and Core AI executors of later releases; a
/// ``NeuralSpeechRuntime`` drives it.
public protocol SpeechGraphExecutor: Sendable {
    /// Loads every graph, keyed by role. A load replaces what an earlier load left: the previous graphs
    /// are released once no run uses them, and only the ones given here can run. A pipeline runtime calls
    /// it once per successful `prepare` of a package, and again only after a failed one.
    func load(graphs: [String: String]) async throws
    /// Runs the graph of `role` on `inputs`, returning its outputs by name.
    func run(role: String, inputs: [String: SpeechTensor]) async throws -> [String: SpeechTensor]
    /// Releases the loaded graphs.
    func close() async
}
