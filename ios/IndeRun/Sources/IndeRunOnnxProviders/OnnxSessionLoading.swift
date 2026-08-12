import Foundation
import IndeRunContracts
import OnnxRuntimeBindings
import Tokenizers

/// A tokenizer + ORT session resolved and loaded for a specific model package, plus the decode
/// strategy auto-detected from the graph's declared input names at load time.
///
/// `@unchecked Sendable`: `ORTSession.run` is documented safe for concurrent invocation and this
/// value only ever crosses from `LoadedSessionBox` (an actor) back to its single caller, mirroring
/// the `@unchecked Sendable` pattern already used for actor-adjacent state elsewhere in this SDK.
struct LoadedSession: @unchecked Sendable {
    let tokenizer: Tokenizer
    let session: ORTSession
    let decodeStrategy: DecodeStrategy
}

/// The decode contract this runtime detected for a loaded graph. `.kvCache` is chosen only when
/// every assumption the KV-cache decode path depends on (layer count, head count, head dimension,
/// per-layer `past_key_values`/`present` naming) is resolvable from the graph's declared input names
/// and the model directory's `config.json`; anything unresolvable conservatively falls back to
/// `.fullRecompute` rather than guessing.
enum DecodeStrategy: Sendable {
    case fullRecompute
    case kvCache(KvCacheLayout)
}

/// Static geometry the KV-cache decode path needs to build empty initial `past_key_values` tensors
/// and locate this graph's `present.*` outputs, resolved once at load time.
struct KvCacheLayout: Sendable {
    let numLayers: Int
    let numKeyValueHeads: Int
    let headDim: Int
    let hasPositionIds: Bool

    var presentOutputNames: [String] {
        (0..<numLayers).flatMap { layer in ["present.\(layer).key", "present.\(layer).value"] }
    }

    /// Zero-length `past_key_values.*` tensors for the first decode step: shape
    /// `[1, numKeyValueHeads, 0, headDim]` -- the sequence-length axis starts empty and grows as
    /// `present.*` outputs replace these tensors after each step.
    func emptyPastKeyValues() -> [String: ORTValue] {
        var result: [String: ORTValue] = [:]
        let shape: [NSNumber] = [1, NSNumber(value: numKeyValueHeads), 0, NSNumber(value: headDim)]
        for layer in 0..<numLayers {
            for part in ["key", "value"] {
                let name = "past_key_values.\(layer).\(part)"
                guard let value = try? ORTValue(tensorData: NSMutableData(), elementType: .float, shape: shape) else { continue }
                result[name] = value
            }
        }
        return result
    }
}

/// Process-wide `ORTEnv`, created once and reused by every session. ORT documents that "one ORTEnv
/// should be created before and destroyed after other ORT API usage" -- creating a fresh one per
/// model load (the previous behavior) worked but discarded that shared-lifecycle intent for no
/// benefit.
private enum SharedOnnxEnvironment {
    static let instance: Result<ORTEnv, OnnxRuntimeError> = {
        do {
            return .success(try ORTEnv(loggingLevel: .warning))
        } catch {
            return .failure(OnnxRuntimeError(
                kind: .unavailable,
                message: "runtime initialization failed: unable to create ONNX Runtime environment.",
                originalError: error
            ))
        }
    }()

    static func get() throws -> ORTEnv {
        switch instance {
        case .success(let env): return env
        case .failure(let error): throw error
        }
    }
}

/// Lazily resolves and caches the loaded session for the most recently requested model package,
/// so repeated `prepare`/`generate` calls do not reload the model and tokenizer every time.
actor LoadedSessionBox {
    private var cached: (key: String, loaded: LoadedSession)?

    func loaded(for modelPackage: ModelPackage) async throws -> LoadedSession {
        let key = Self.cacheKey(for: modelPackage)
        if let cached, cached.key == key {
            return cached.loaded
        }

        let loaded = try await Self.load(modelPackage)
        cached = (key, loaded)
        return loaded
    }

    /// Cache key covering everything that identifies *which bytes* this session was built from --
    /// `id` alone does not: an app can swap a bundled model file, change `source.ref`, or bump
    /// `version` while keeping the same `id`, and a stale cached session would silently keep
    /// serving the old model.
    private static func cacheKey(for modelPackage: ModelPackage) -> String {
        var parts = [modelPackage.id, modelPackage.format.rawValue, modelPackage.version ?? ""]
        if let source = modelPackage.source {
            parts.append(source.sourceType.rawValue)
            parts.append(source.ref ?? "")
        }
        if let checksums = modelPackage.integrity?.checksums {
            parts.append(checksums.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))
        }
        return parts.joined(separator: "|")
    }

    private static func load(_ modelPackage: ModelPackage) async throws -> LoadedSession {
        guard modelPackage.format == .onnx || modelPackage.format == .ort else {
            let format = modelPackage.format.rawValue
            throw OnnxRuntimeError(
                kind: .capability,
                message: "unsupported model format: SystemOnnxGenAiRuntime requires format 'onnx' or 'ort', got '\(format)'."
            )
        }

        let directory = try resolveDirectory(modelPackage)

        // Graph file convention: the schema's `files.required` has no positional/role semantics
        // of its own, so this runtime defines one explicitly -- the *first* entry is the ONNX
        // graph file; any remaining entries (for example external weight shards) are required to
        // be present but are not referenced directly, since ORT resolves them relative to the
        // graph file itself. This convention is documented in
        // `docs/architecture/onnx-runtime-provider-family.md#apple-implementation`.
        guard let requiredFiles = modelPackage.files?.filesRequired, let modelFileName = requiredFiles.first else {
            throw OnnxRuntimeError(kind: .capability, message: "model files missing: model package declares no required files.")
        }
        let modelPath = directory.appendingPathComponent(modelFileName)
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw OnnxRuntimeError(kind: .capability, message: "model files missing: '\(modelFileName)' not found at \(modelPath.path).")
        }
        for fileName in requiredFiles.dropFirst() {
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path) else {
                throw OnnxRuntimeError(kind: .capability, message: "model files missing: '\(fileName)' not found in \(directory.path).")
            }
        }

        guard let tokenizerFileName = modelPackage.files?.tokenizer else {
            throw OnnxRuntimeError(kind: .capability, message: "tokenizer/config missing: model package declares no tokenizer file.")
        }
        let tokenizerPath = directory.appendingPathComponent(tokenizerFileName)
        guard FileManager.default.fileExists(atPath: tokenizerPath.path) else {
            throw OnnxRuntimeError(
                kind: .capability,
                message: "tokenizer/config missing: '\(tokenizerFileName)' not found at \(tokenizerPath.path)."
            )
        }

        try verifyChecksums(modelPackage, directory: directory)

        let tokenizer: Tokenizer
        do {
            tokenizer = try await AutoTokenizer.from(modelFolder: directory)
        } catch {
            throw OnnxRuntimeError(kind: .capability, message: "tokenizer/config missing: failed to load tokenizer.", originalError: error)
        }

        let env = try SharedOnnxEnvironment.get()
        let modelPathString = modelPath.path
        var session = try await makeSession(env: env, modelPath: modelPathString, useCoreML: true)

        let decodeStrategy = try detectDecodeStrategy(session: session, directory: directory)

        // The CoreML execution provider cannot run this graph's KV-cache path: the very first
        // decode call feeds a genuinely zero-length `past_key_values` (see
        // `KvCacheLayout.emptyPastKeyValues`), and ORT's CoreML EP rejects a dynamic-shaped input
        // with zero elements at run time (`... has a dynamic shape (...) but the runtime shape
        // (...) has zero elements. This is not supported by the CoreML EP.` -- a real device
        // failure, not a hypothetical one). The plain decode path never constructs a zero-length
        // tensor, so it keeps CoreML. Re-creating the session is the only option: ORT's execution
        // provider list is fixed at session-creation time, not selectable per call.
        if case .kvCache = decodeStrategy {
            session = try await makeSession(env: env, modelPath: modelPathString, useCoreML: false)
        }

        return LoadedSession(tokenizer: tokenizer, session: session, decodeStrategy: decodeStrategy)
    }

    private static func makeSession(env: ORTEnv, modelPath: String, useCoreML: Bool) async throws -> ORTSession {
        do {
            return try await OnnxExecutionQueue.shared.run {
                let options = try makeSessionOptions(useCoreML: useCoreML)
                return try ORTSession(env: env, modelPath: modelPath, sessionOptions: options)
            }
        } catch {
            throw OnnxRuntimeError(
                kind: .unavailable,
                message: "runtime initialization failed: unable to create ONNX Runtime session.",
                originalError: error
            )
        }
    }

    /// Configures the CoreML execution provider by default (when `useCoreML`), falling back to
    /// XNNPACK and then ORT's default CPU EP if CoreML EP configuration fails on this device/OS --
    /// CoreML's availability and compilation behavior vary across hardware and OS versions, so
    /// this must degrade rather than fail session creation. `useCoreML: false` skips straight to
    /// XNNPACK/CPU, for graphs CoreML cannot run at all (see the KV-cache zero-length-tensor note
    /// at this method's call site). `intraOpNumThreads` is set explicitly (bounded by the device's
    /// active processor count) rather than left at ORT's implicit default.
    private static func makeSessionOptions(useCoreML: Bool) throws -> ORTSessionOptions {
        let options = try ORTSessionOptions()
        let threadCount = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))
        try? options.setIntraOpNumThreads(Int32(threadCount))

        let coreMLEnabled: Bool = {
            guard useCoreML else { return false }
            return (try? options.appendCoreMLExecutionProvider(with: ORTCoreMLExecutionProviderOptions())) != nil
        }()
        if !coreMLEnabled {
            let xnnpackOptions = ORTXnnpackExecutionProviderOptions()
            xnnpackOptions.intra_op_num_threads = Int32(threadCount)
            _ = try? options.appendXnnpackExecutionProvider(with: xnnpackOptions)
        }
        return options
    }
}
