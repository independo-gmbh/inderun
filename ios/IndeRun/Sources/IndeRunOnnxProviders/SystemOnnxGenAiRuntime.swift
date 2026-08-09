import CryptoKit
import Foundation
import IndeRunContracts
import OnnxRuntimeBindings
import Tokenizers

/// Default production `OnnxGenAiRuntime`, backed by the official ONNX Runtime SPM bindings
/// (`microsoft/onnxruntime-swift-package-manager`) for inference and `swift-transformers`'s
/// `Tokenizers` module for tokenization.
///
/// **IO contract.** This runtime expects the model graph to expose exactly the inputs
/// `input_ids` and `attention_mask` (both `int64`, shape `[1, sequenceLength]`) and a `logits`
/// output (`float32`, shape `[1, sequenceLength, vocabSize]`) -- the plain decoder-only export
/// shape, without `past_key_values`. Models exported with KV-cache inputs (the common
/// Hugging Face Optimum convention) are not supported by this default runtime; supply a custom
/// `OnnxGenAiRuntime` for those.
///
/// **Decode loop.** Generation is greedy (argmax) and recomputes the full sequence on every step
/// -- there is no KV-cache reuse, no CoreML execution provider, and no shared/tuned `ORTEnv` or
/// thread-pool policy in this version. This is a known, documented performance limitation (see
/// `docs/architecture/onnx-runtime-provider-family.md`), not a hidden one -- CPU-only, unoptimized
/// throughput. `generation.stop` sequences are honored; `temperature`/`topP`/`seed` are not (there
/// is no sampling, only argmax). Apps that need throughput, sampling, or an accelerated execution
/// provider inject a different runtime behind the same seam.
///
/// **Chat formatting.** Input is tokenized via the tokenizer's chat template
/// (`Tokenizer.applyChatTemplate`) when the loaded `tokenizer_config.json` declares one, since most
/// instruction-tuned models require their specific role-tagged special tokens. Tokenizers without a
/// configured template fall back to a plain `"role: content"` join.
///
/// **Model sources.** `bundled` resolves under `Bundle.main.resourceURL`, `filesystem` and
/// `app_managed` resolve `source.ref` as a directory path (absolute, or relative to the app's
/// Application Support directory for `app_managed`). `programmatic` has no files to resolve and
/// is reported as unavailable; apps using `programmatic` sources must supply their own runtime.
public final class SystemOnnxGenAiRuntime: OnnxGenAiRuntime {
    private static let defaultMaxOutputTokens = 256
    private static let inputIdsName = "input_ids"
    private static let attentionMaskName = "attention_mask"
    private static let logitsName = "logits"

    private let session: LoadedSessionBox

    public init() {
        self.session = LoadedSessionBox()
    }

    public func prepare(_ modelPackage: ModelPackage) async -> OnnxRuntimeAvailability {
        do {
            _ = try await session.loaded(for: modelPackage)
            return OnnxRuntimeAvailability(available: true)
        } catch let error as OnnxRuntimeError {
            return OnnxRuntimeAvailability(available: false, reason: error.message)
        } catch {
            return OnnxRuntimeAvailability(available: false, reason: "runtime initialization failed: \(error).")
        }
    }

    public func generate(_ input: OnnxGenerationInput) async throws -> OnnxGenerationOutput {
        let loaded = try await session.loaded(for: input.modelPackage)
        var tokenIds = encodeInput(input.messages, tokenizer: loaded.tokenizer)

        guard !tokenIds.isEmpty else {
            throw OnnxRuntimeError(kind: .capability, message: "model output malformed: tokenizer produced no input tokens.")
        }

        let maxOutputTokens = input.generation?.maxOutputTokens ?? Self.defaultMaxOutputTokens
        let stopSequences = (input.generation?.stop ?? []).filter { !$0.isEmpty }
        let eosTokenId = loaded.tokenizer.eosTokenId
        let promptLength = tokenIds.count
        var generatedCount = 0
        var matchedStop: String?

        while generatedCount < maxOutputTokens {
            try Task.checkCancellation()

            let nextToken = try runStep(loaded: loaded, tokenIds: tokenIds)
            tokenIds.append(nextToken)
            generatedCount += 1

            if let eosTokenId, nextToken == eosTokenId {
                break
            }

            if !stopSequences.isEmpty {
                let partialText = loaded.tokenizer.decode(tokens: Array(tokenIds[promptLength...]), skipSpecialTokens: true)
                if let stop = stopSequences.first(where: { partialText.hasSuffix($0) }) {
                    matchedStop = stop
                    break
                }
            }
        }

        let generatedIds = Array(tokenIds[promptLength...])
        var text = loaded.tokenizer.decode(tokens: generatedIds, skipSpecialTokens: true)
        if let matchedStop, text.hasSuffix(matchedStop) {
            text.removeLast(matchedStop.count)
        }
        let finishReason: FinishReason = generatedCount >= maxOutputTokens ? .length : .stop

        return OnnxGenerationOutput(
            text: text,
            finishReason: finishReason,
            usage: Usage(inputTokens: promptLength, outputTokens: generatedCount, totalTokens: promptLength + generatedCount)
        )
    }

    /// Tokenizes input via the model's chat template when the tokenizer provides one (correct for
    /// instruction-tuned models, which expect role-tagged special tokens rather than plain text),
    /// falling back to a plain `role: content` join for tokenizers without a configured template.
    private func encodeInput(_ messages: [OnnxGenerationMessage], tokenizer: Tokenizer) -> [Int] {
        let chatMessages: [[String: any Sendable]] = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        if let tokenIds = try? tokenizer.applyChatTemplate(messages: chatMessages) {
            return tokenIds
        }
        return tokenizer.encode(text: normalizedPrompt(from: messages))
    }

    private func runStep(loaded: LoadedSession, tokenIds: [Int]) throws -> Int {
        let sequenceLength = tokenIds.count

        let tensorByteCount = sequenceLength * MemoryLayout<Int64>.size
        let inputIdsData = NSMutableData(bytes: tokenIds.map { Int64($0) }, length: tensorByteCount)
        let attentionMaskData = NSMutableData(bytes: [Int64](repeating: 1, count: sequenceLength), length: tensorByteCount)

        do {
            let inputIdsValue = try ORTValue(
                tensorData: inputIdsData,
                elementType: .int64,
                shape: [1, NSNumber(value: sequenceLength)]
            )
            let attentionMaskValue = try ORTValue(
                tensorData: attentionMaskData,
                elementType: .int64,
                shape: [1, NSNumber(value: sequenceLength)]
            )

            let outputs = try loaded.session.run(
                withInputs: [Self.inputIdsName: inputIdsValue, Self.attentionMaskName: attentionMaskValue],
                outputNames: [Self.logitsName],
                runOptions: nil
            )

            guard let logitsValue = outputs[Self.logitsName] else {
                throw OnnxRuntimeError(kind: .internalFailure, message: "model output malformed: missing '\(Self.logitsName)' output.")
            }

            return try argmaxLastPosition(logits: logitsValue, sequenceLength: sequenceLength)
        } catch let error as OnnxRuntimeError {
            throw error
        } catch {
            throw OnnxRuntimeError(kind: .unavailable, message: "ONNX Runtime session execution failed.", originalError: error)
        }
    }

    private func argmaxLastPosition(logits: ORTValue, sequenceLength: Int) throws -> Int {
        let typeAndShape = try logits.tensorTypeAndShapeInfo()
        let shape = typeAndShape.shape.map { $0.intValue }
        guard shape.count == 3, shape[0] == 1, shape[1] == sequenceLength else {
            throw OnnxRuntimeError(kind: .internalFailure, message: "model output malformed: unexpected logits shape \(shape).")
        }
        let vocabSize = shape[2]

        // Reads only the final position's row directly out of the tensor buffer rather than
        // copying the full [sequenceLength x vocabSize] tensor into a Swift Array -- the decode
        // loop only ever needs the last row's argmax.
        let data = try logits.tensorData()
        let lastPositionOffset = (sequenceLength - 1) * vocabSize
        let byteOffset = lastPositionOffset * MemoryLayout<Float>.size
        let rowByteCount = vocabSize * MemoryLayout<Float>.size
        guard data.length >= byteOffset + rowByteCount else {
            throw OnnxRuntimeError(kind: .internalFailure, message: "model output malformed: logits buffer smaller than expected shape.")
        }

        var bestIndex = 0
        var bestValue = -Float.infinity
        (data as Data).withUnsafeBytes { (rawPointer: UnsafeRawBufferPointer) in
            let lastRow = rawPointer.baseAddress!.advanced(by: byteOffset).assumingMemoryBound(to: Float.self)
            for index in 0..<vocabSize {
                let value = lastRow[index]
                if value > bestValue {
                    bestValue = value
                    bestIndex = index
                }
            }
        }
        return bestIndex
    }

    private func normalizedPrompt(from messages: [OnnxGenerationMessage]) -> String {
        messages.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n")
    }
}

/// A tokenizer + ORT session resolved and loaded for a specific model package.
///
/// `@unchecked Sendable`: `ORTSession.run` is documented safe for concurrent invocation and this
/// value only ever crosses from `LoadedSessionBox` (an actor) back to its single caller, mirroring
/// the `@unchecked Sendable` pattern already used for actor-adjacent state elsewhere in this SDK.
private struct LoadedSession: @unchecked Sendable {
    let tokenizer: Tokenizer
    let session: ORTSession
}

/// Lazily resolves and caches the loaded session for the most recently requested model package,
/// so repeated `prepare`/`generate` calls do not reload the model and tokenizer every time.
private actor LoadedSessionBox {
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

        let session: ORTSession
        do {
            let env = try ORTEnv(loggingLevel: .warning)
            session = try ORTSession(env: env, modelPath: modelPath.path, sessionOptions: nil)
        } catch {
            throw OnnxRuntimeError(
                kind: .unavailable,
                message: "runtime initialization failed: unable to create ONNX Runtime session.",
                originalError: error
            )
        }

        return LoadedSession(tokenizer: tokenizer, session: session)
    }

    /// Verifies `ModelPackage.integrity.checksums` (`sha256:<hex>`) for every declared file this
    /// runtime actually resolved a path for, before the graph or tokenizer is loaded. Declared
    /// checksums for files outside this runtime's resolution (for example files a different
    /// runtime seam would use) are not checked -- only files under `directory` are addressable.
    private static func verifyChecksums(_ modelPackage: ModelPackage, directory: URL) throws {
        guard let checksums = modelPackage.integrity?.checksums, !checksums.isEmpty else { return }

        for (fileName, expected) in checksums {
            let fileURL = directory.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }

            let parts = expected.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0] == "sha256" else {
                throw OnnxRuntimeError(
                    kind: .capability,
                    message: "checksum/integrity mismatch: unsupported algorithm for '\(fileName)' (only 'sha256:<hex>' is supported)."
                )
            }
            let expectedHex = String(parts[1])

            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                throw OnnxRuntimeError(
                    kind: .capability,
                    message: "model files missing: unable to read '\(fileName)' for checksum verification.",
                    originalError: error
                )
            }
            let actualHex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

            guard actualHex.caseInsensitiveCompare(expectedHex) == .orderedSame else {
                throw OnnxRuntimeError(
                    kind: .capability,
                    message: "checksum/integrity mismatch: '\(fileName)' does not match its declared checksum."
                )
            }
        }
    }

    private static func resolveDirectory(_ modelPackage: ModelPackage) throws -> URL {
        guard let source = modelPackage.source else {
            throw OnnxRuntimeError(kind: .capability, message: "model source unavailable: model package declares no source.")
        }

        switch source.sourceType {
        case .bundled:
            guard let resourceURL = Bundle.main.resourceURL else {
                throw OnnxRuntimeError(kind: .unavailable, message: "runtime initialization failed: app bundle has no resource directory.")
            }
            return source.ref.map { resourceURL.appendingPathComponent($0) } ?? resourceURL
        case .filesystem:
            guard let ref = source.ref else {
                throw OnnxRuntimeError(kind: .capability, message: "model source unavailable: 'filesystem' source requires 'ref'.")
            }
            return URL(fileURLWithPath: ref)
        case .appManaged:
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
            return source.ref.map { base.appendingPathComponent($0) } ?? base
        case .programmatic:
            throw OnnxRuntimeError(
                kind: .capability,
                message: "model source unavailable: 'programmatic' sources require an application-supplied OnnxGenAiRuntime."
            )
        case .registry, .remote:
            throw OnnxRuntimeError(
                kind: .capability,
                message: "model source unavailable: '\(source.sourceType.rawValue)' model sources are deferred on Apple platforms."
            )
        }
    }
}
