#if canImport(CoreAI)
import CoreAI
import Foundation

/// A loaded inference function, with the model that owns it.
@available(iOS 27, macOS 27, *)
private struct LoadedCoreAIGraph: Sendable {
    let model: AIModel
    let function: InferenceFunction
}

/// Runs the graphs of a `coreai` speech model package through Apple Core AI. Each role names an
/// `.aimodel` file (a file or a directory) and an inference function in it (``CoreAIGraphReference``);
/// roles that share a file share one `AIModel`. A file already specialized for this device is taken
/// from `AIModelCache.default`; otherwise `load` specializes it first, which can take minutes on a
/// large model, and leaves it in the cache for the next load. `load` replaces the loaded graphs; a run
/// that already holds a replaced function keeps it alive until it returns. Core AI's inference
/// functions may run concurrently, so runs are not serialized here. The tensors are f32 or i64 only
/// (see ``SpeechTensor``); a graph whose mask is boolean casts it inside the `.aimodel`.
@available(iOS 27, macOS 27, *)
public final class CoreAISpeechGraphExecutor: SpeechGraphExecutor, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var graphs: [String: LoadedCoreAIGraph] = [:]

    public init(directory: URL) {
        self.directory = directory
    }

    public func load(graphs values: [String: String]) async throws {
        let roles = values.sorted(by: { $0.key < $1.key })
        // Refuse every malformed reference and file name before Core AI is touched.
        var references: [(role: String, reference: CoreAIGraphReference)] = []
        for (role, value) in roles {
            let reference = try CoreAIGraphReference(role: role, value: value)
            do {
                try checkPackageFileName(reference.file)
            } catch let error as NeuralSpeechRuntimeError {
                throw NeuralSpeechRuntimeError(
                    kind: .unavailable, message: "graph failed to load: \(role): \(error.message)", originalError: error
                )
            }
            references.append((role, reference))
        }

        var models: [String: AIModel] = [:]
        var loaded: [String: LoadedCoreAIGraph] = [:]
        for (role, reference) in references {
            let model: AIModel
            do {
                if let known = models[reference.file] {
                    model = known
                } else {
                    let opened = try await openModel(reference.file)
                    models[reference.file] = opened
                    model = opened
                }
            } catch {
                let message = (error as? NeuralSpeechRuntimeError)?.message ?? error.localizedDescription
                throw NeuralSpeechRuntimeError(
                    kind: .unavailable, message: "graph failed to load: \(role): \(message)", originalError: error
                )
            }
            let function: InferenceFunction?
            do {
                function = try model.loadFunction(named: reference.function)
            } catch {
                throw NeuralSpeechRuntimeError(
                    kind: .unavailable, message: "graph failed to load: \(role): \(error.localizedDescription)", originalError: error
                )
            }
            guard let function else {
                throw NeuralSpeechRuntimeError(
                    kind: .capability, message: "graph function missing: \(role): \(reference.function) in \(reference.file)"
                )
            }
            loaded[role] = LoadedCoreAIGraph(model: model, function: function)
        }
        lock.withLock { graphs = loaded }
    }

    /// The model of `file`, from the specialization cache when it is there, else specialized now.
    /// Throws `model files missing: <file>` when the package has no such file.
    private func openModel(_ file: String) async throws -> AIModel {
        let url = directory.appendingPathComponent(file)
        // An .aimodel may be a file or a directory; either counts.
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NeuralSpeechRuntimeError(kind: .unavailable, message: "model files missing: \(file)")
        }
        if let cached = try AIModelCache.default.model(for: url, options: .default) {
            return cached
        }
        return try await AIModel.specialize(contentsOf: url, options: .default)
    }

    public func run(role: String, inputs: [String: SpeechTensor]) async throws -> [String: SpeechTensor] {
        guard let graph = lock.withLock({ graphs[role] }) else {
            throw NeuralSpeechRuntimeError(kind: .internalFailure, message: "graph not loaded: \(role)")
        }
        let arrays = try inputs.mapValues(makeNDArray)
        var outputs: InferenceFunction.Outputs
        do {
            outputs = try await graph.function.run(inputs: arrays)
        } catch {
            throw NeuralSpeechRuntimeError(
                kind: .unavailable, message: "graph failed: \(role): \(error.localizedDescription)", originalError: error
            )
        }
        var result: [String: SpeechTensor] = [:]
        for name in Array(outputs.names) {
            guard let array = outputs.remove(name)?.ndArray else {
                throw NeuralSpeechRuntimeError(kind: .internalFailure, message: "graph output unsupported: \(role).\(name)")
            }
            result[name] = try makeSpeechTensor(array, role: role, name: name)
        }
        return result
    }

    public func close() async {
        lock.withLock { graphs = [:] }
    }
}
#endif
