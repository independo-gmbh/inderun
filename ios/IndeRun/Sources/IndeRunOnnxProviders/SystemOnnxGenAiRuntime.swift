import CryptoKit
import Foundation
import IndeRunContracts
import OnnxRuntimeBindings
import Tokenizers

/// Default production `OnnxGenAiRuntime`, backed by the official ONNX Runtime SPM bindings
/// (`microsoft/onnxruntime-swift-package-manager`) for inference and `swift-transformers`'s
/// `Tokenizers` module for tokenization.
///
/// **IO contract.** This runtime auto-detects, from the loaded graph's declared input names, which
/// of two decoder-only export shapes a model uses -- no `ModelPackage` field or app-facing
/// configuration selects it. Both require `input_ids`/`attention_mask` (`int64`) and a `logits`
/// output (`float32`, `[1, sequenceLength, vocabSize]`):
///
/// - **Plain** (no `past_key_values.*` inputs): the full sequence is recomputed on every decode
///   step. Always supported; the fallback when KV-cache detection can't establish every assumption
///   below.
/// - **KV-cache** (`past_key_values.{layer}.key`/`.value` inputs present, matching the legacy
///   (non-merged) Hugging Face Optimum `decoder_with_past_model` export convention): exactly one
///   token is fed as `input_ids` per model call -- this graph shape traces `input_ids`'s
///   sequence-length axis fixed at 1, not dynamic, so it cannot accept the whole prompt in one
///   call the way a merged/optional-past graph can. The prompt is therefore replayed through the
///   same session one token at a time (discarding logits) to build up `past_key_values` before the
///   first real generated token is produced, then generation proceeds one token per call the same
///   way, with each step's `present.{layer}.key`/`.value` outputs threaded back in as the next
///   step's `past_key_values.*` inputs. Requires `num_hidden_layers` (or GPT-2-style `n_layer`),
///   `num_attention_heads`/`n_head` (or `num_key_value_heads`), and `hidden_size`/`n_embd` (or
///   `head_dim`) to be readable from `config.json` in the model directory; an optional
///   `position_ids` input is honored if the graph declares it. Graphs that also declare a
///   `use_cache_branch` boolean input (merged Optimum exports, which accept the whole prompt on
///   their first call) fall back to the plain path instead -- the ONNX Runtime Objective-C
///   bindings this runtime depends on expose no `bool` tensor element type to feed it correctly,
///   and this runtime does not implement the merged graph's alternate calling convention. This
///   path is designed against the documented Optimum export convention and the ONNX Runtime
///   Objective-C API; its one-token-per-call shape was corrected against a real device failure
///   (`Got invalid dimensions for input: input_ids ... Expected: 1`) surfaced by a real exported
///   model (LaMini-GPT, see the iOS demo app). See #88 for remaining broader real-device
///   verification (load time, memory, cancellation, other model families).
///
/// **Decode loop.** Generation defaults to greedy (argmax); `generation.temperature`/`topP`/`seed`
/// select sampling (temperature scaling, optional top-p nucleus filtering, seeded when `seed` is
/// set) instead. `generation.stop` sequences are honored. Session creation and every `run()` call
/// execute on a dedicated serial queue rather than the Swift Concurrency cooperative pool, since
/// `ORTSession.run()` is a blocking synchronous call. A single `ORTEnv` is shared process-wide
/// across sessions, per ORT's own guidance. The CoreML execution provider is configured by default
/// on the plain decode path, falling back to XNNPACK and then ORT's default CPU EP if CoreML is
/// unavailable on the host; CoreML compiles the graph into an on-device `.mlmodelc` cache on first
/// load (managed by ORT/CoreML, not by IndeRun) keyed by the model and execution-provider options,
/// and invalidated by a changed model file or EP option set. The KV-cache path never uses CoreML,
/// even when available: its first decode call feeds a genuinely zero-length `past_key_values`
/// tensor, and ORT's CoreML EP rejects a dynamic-shaped input with zero elements at run time (a
/// real device failure, not a hypothetical one) -- that graph always runs on XNNPACK/CPU instead.
/// See `docs/architecture/onnx-runtime-provider-family.md` for the full specification and
/// residual risks.
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

/// IO tensor names shared by both decode paths and the KV-cache detection logic. File-scope (not
/// nested) so every private type in this file -- the class, the two decoders, and the session
/// loader -- can share them without widening any type's own access level.
private let inputIdsName = "input_ids"
private let attentionMaskName = "attention_mask"
private let positionIdsName = "position_ids"
private let logitsName = "logits"
private let pastKeyValuesPrefix = "past_key_values."

public final class SystemOnnxGenAiRuntime: OnnxGenAiRuntime {
    private static let defaultMaxOutputTokens = 256

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
        let tokenIds = encodeInput(input.messages, tokenizer: loaded.tokenizer)

        guard !tokenIds.isEmpty else {
            throw OnnxRuntimeError(kind: .capability, message: "model output malformed: tokenizer produced no input tokens.")
        }

        let maxOutputTokens = input.generation?.maxOutputTokens ?? Self.defaultMaxOutputTokens
        let stopSequences = (input.generation?.stop ?? []).filter { !$0.isEmpty }
        let eosTokenId = loaded.tokenizer.eosTokenId
        let promptLength = tokenIds.count
        let sampling = SamplingConfig(generation: input.generation)

        var decoder = makeDecoder(loaded: loaded, promptTokenIds: tokenIds, maxOutputTokens: maxOutputTokens)
        var generatedIds: [Int] = []
        var matchedStop: String?

        while generatedIds.count < maxOutputTokens {
            try Task.checkCancellation()

            let nextToken = try await decoder.step(sampling: sampling)
            generatedIds.append(nextToken)

            if let eosTokenId, nextToken == eosTokenId {
                break
            }

            if !stopSequences.isEmpty {
                let partialText = loaded.tokenizer.decode(tokens: generatedIds, skipSpecialTokens: true)
                if let stop = stopSequences.first(where: { partialText.hasSuffix($0) }) {
                    matchedStop = stop
                    break
                }
            }
        }

        var text = loaded.tokenizer.decode(tokens: generatedIds, skipSpecialTokens: true)
        if let matchedStop, text.hasSuffix(matchedStop) {
            text.removeLast(matchedStop.count)
        }
        let finishReason: FinishReason = generatedIds.count >= maxOutputTokens ? .length : .stop

        return OnnxGenerationOutput(
            text: text,
            finishReason: finishReason,
            usage: Usage(inputTokens: promptLength, outputTokens: generatedIds.count, totalTokens: promptLength + generatedIds.count)
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

    private func normalizedPrompt(from messages: [OnnxGenerationMessage]) -> String {
        messages.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n")
    }

    private func makeDecoder(loaded: LoadedSession, promptTokenIds: [Int], maxOutputTokens: Int) -> any StepDecoder {
        switch loaded.decodeStrategy {
        case .fullRecompute:
            return FullRecomputeDecoder(loaded: loaded, promptTokenIds: promptTokenIds, maxOutputTokens: maxOutputTokens)
        case .kvCache(let layout):
            return KvCacheDecoder(loaded: loaded, layout: layout, promptTokenIds: promptTokenIds)
        }
    }
}

/// One decode step: append a single generated token id given the tokens produced so far.
private protocol StepDecoder {
    mutating func step(sampling: SamplingConfig) async throws -> Int
}

/// Full-sequence-recompute decode step: the plain `input_ids`/`attention_mask`/`logits` IO
/// contract, without KV-cache reuse. Input buffers are preallocated once for the whole generation
/// (sized to `promptLength + maxOutputTokens`) and written into a growing subrange each step, so
/// only the token-id array grows -- no fresh `NSMutableData` allocation per token.
private struct FullRecomputeDecoder: StepDecoder {
    let loaded: LoadedSession
    var tokenIds: [Int]
    let capacity: Int
    private var inputIdsBuffer: NSMutableData
    private var attentionMaskBuffer: NSMutableData

    init(loaded: LoadedSession, promptTokenIds: [Int], maxOutputTokens: Int) {
        self.loaded = loaded
        self.tokenIds = promptTokenIds
        self.capacity = promptTokenIds.count + maxOutputTokens
        let byteCapacity = capacity * MemoryLayout<Int64>.size
        self.inputIdsBuffer = NSMutableData(length: byteCapacity) ?? NSMutableData()
        self.attentionMaskBuffer = NSMutableData(length: byteCapacity) ?? NSMutableData()
    }

    mutating func step(sampling: SamplingConfig) async throws -> Int {
        let sequenceLength = tokenIds.count
        writeBuffers(sequenceLength: sequenceLength)

        let byteCount = sequenceLength * MemoryLayout<Int64>.size
        let inputIdsValue = try ORTValue(
            tensorData: NSMutableData(data: inputIdsBuffer.subdata(with: NSRange(location: 0, length: byteCount))),
            elementType: .int64,
            shape: [1, NSNumber(value: sequenceLength)]
        )
        let attentionMaskValue = try ORTValue(
            tensorData: NSMutableData(data: attentionMaskBuffer.subdata(with: NSRange(location: 0, length: byteCount))),
            elementType: .int64,
            shape: [1, NSNumber(value: sequenceLength)]
        )

        let outputs = try await runOnnxSession(
            loaded.session,
            inputs: [inputIdsName: inputIdsValue, attentionMaskName: attentionMaskValue],
            outputNames: [logitsName]
        )

        guard let logitsValue = outputs[logitsName] else {
            throw OnnxRuntimeError(kind: .internalFailure, message: "model output malformed: missing '\(logitsName)' output.")
        }

        let nextToken = try selectNextToken(logits: logitsValue, sequenceLength: sequenceLength, sampling: sampling)
        tokenIds.append(nextToken)
        return nextToken
    }

    private mutating func writeBuffers(sequenceLength: Int) {
        let tokenBytes = tokenIds.map { Int64($0) }
        tokenBytes.withUnsafeBytes { raw in
            inputIdsBuffer.replaceBytes(in: NSRange(location: 0, length: raw.count), withBytes: raw.baseAddress!)
        }
        let maskBytes = [Int64](repeating: 1, count: sequenceLength)
        maskBytes.withUnsafeBytes { raw in
            attentionMaskBuffer.replaceBytes(in: NSRange(location: 0, length: raw.count), withBytes: raw.baseAddress!)
        }
    }
}

/// KV-cache decode step, following the legacy (non-merged) Hugging Face Optimum
/// `decoder_with_past_model` export convention: exactly one token is fed as `input_ids` per model
/// call (this graph's sequence-length axis is traced fixed at 1), with each call's `present.*`
/// outputs threaded back in as the next call's `past_key_values.*` inputs directly (no copy),
/// which is itself the buffer reuse win for this path. The prompt is replayed one token at a time
/// before real generation begins -- see `step(sampling:)`.
private struct KvCacheDecoder: StepDecoder {
    let loaded: LoadedSession
    let layout: KvCacheLayout
    var tokenIds: [Int]
    var pastKeyValues: [String: ORTValue]
    /// Prompt tokens not yet fed to the model. Legacy (non-merged) Optimum
    /// `decoder_with_past_model` exports trace `input_ids` with a sequence-length axis fixed at
    /// 1 -- there is no separate no-past graph in this runtime to prefill the prompt in one call
    /// -- so the prompt must be replayed through the same with-past session one token at a time to
    /// build up `past_key_values` before generation can begin.
    var remainingPromptTokens: [Int]
    /// Number of tokens already fed into the model (== the current `past_key_values` length).
    var fedCount = 0

    init(loaded: LoadedSession, layout: KvCacheLayout, promptTokenIds: [Int]) {
        self.loaded = loaded
        self.layout = layout
        self.tokenIds = promptTokenIds
        self.pastKeyValues = layout.emptyPastKeyValues()
        self.remainingPromptTokens = promptTokenIds
    }

    mutating func step(sampling: SamplingConfig) async throws -> Int {
        // Replay every remaining prompt token except the last, discarding logits -- only the
        // last prompt token's logits (fed with every earlier token already in `past_key_values`)
        // predict the first generated token.
        while remainingPromptTokens.count > 1 {
            _ = try await feedToken(remainingPromptTokens.removeFirst(), wantLogits: false, sampling: sampling)
        }

        let tokenToFeed = remainingPromptTokens.isEmpty ? tokenIds[tokenIds.count - 1] : remainingPromptTokens.removeFirst()
        guard let nextToken = try await feedToken(tokenToFeed, wantLogits: true, sampling: sampling) else {
            throw OnnxRuntimeError(kind: .internalFailure, message: "model output malformed: missing '\(logitsName)' output.")
        }
        tokenIds.append(nextToken)
        return nextToken
    }

    /// Feeds exactly one token (`input_ids`/`attention_mask` shape `[1, 1]`, matching this
    /// graph's fixed sequence-length-1 trace) and advances `pastKeyValues`/`fedCount`. Returns the
    /// sampled next token when `wantLogits` is set (the `logits` output is only requested then, to
    /// avoid computing/transferring it for the discarded prompt-replay steps), `nil` otherwise.
    private mutating func feedToken(_ token: Int, wantLogits: Bool, sampling: SamplingConfig) async throws -> Int? {
        let totalLength = fedCount + 1

        var inputs: [String: ORTValue] = [
            inputIdsName: try makeInt64Tensor([Int64(token)], shape: [1, 1]),
            attentionMaskName: try makeInt64Tensor([Int64](repeating: 1, count: totalLength), shape: [1, totalLength])
        ]
        for (name, value) in pastKeyValues {
            inputs[name] = value
        }
        if layout.hasPositionIds {
            inputs[positionIdsName] = try makeInt64Tensor([Int64(fedCount)], shape: [1, 1])
        }

        var outputNames = Set(layout.presentOutputNames)
        if wantLogits {
            outputNames.insert(logitsName)
        }

        let outputs = try await runOnnxSession(loaded.session, inputs: inputs, outputNames: outputNames)

        var nextPastKeyValues: [String: ORTValue] = [:]
        for layer in 0..<layout.numLayers {
            for part in ["key", "value"] {
                let presentName = "present.\(layer).\(part)"
                let pastName = "\(pastKeyValuesPrefix)\(layer).\(part)"
                guard let value = outputs[presentName] else {
                    throw OnnxRuntimeError(
                        kind: .internalFailure,
                        message: "model output malformed: missing '\(presentName)' output."
                    )
                }
                nextPastKeyValues[pastName] = value
            }
        }
        pastKeyValues = nextPastKeyValues
        fedCount += 1

        guard wantLogits else { return nil }
        guard let logitsValue = outputs[logitsName] else {
            throw OnnxRuntimeError(kind: .internalFailure, message: "model output malformed: missing '\(logitsName)' output.")
        }
        return try selectNextToken(logits: logitsValue, sequenceLength: 1, sampling: sampling)
    }
}

private func makeInt64Tensor(_ values: [Int64], shape: [Int]) throws -> ORTValue {
    let data = NSMutableData(bytes: values, length: values.count * MemoryLayout<Int64>.size)
    return try ORTValue(tensorData: data, elementType: .int64, shape: shape.map { NSNumber(value: $0) })
}

/// Runs `session.run` on the dedicated execution queue (see `OnnxExecutionQueue`) and wraps any
/// raw ORT failure (missing/mistyped input, shape mismatch, and similar) into an
/// `OnnxRuntimeError` carrying the original error as detail, rather than letting an opaque native
/// error propagate uncaught up to the provider's generic "execution failed" fallback.
private func runOnnxSession(
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

/// Reads the last-position logits row directly out of the tensor buffer rather than copying the
/// full `[sequenceLength x vocabSize]` tensor into a Swift `Array` -- the decode loop only ever
/// needs the last row -- then either argmaxes it (the default) or samples from it when
/// `sampling` selects temperature/top-p sampling.
private func selectNextToken(logits: ORTValue, sequenceLength: Int, sampling: SamplingConfig) throws -> Int {
    let typeAndShape = try logits.tensorTypeAndShapeInfo()
    let shape = typeAndShape.shape.map { $0.intValue }
    guard shape.count == 3, shape[0] == 1, shape[1] == sequenceLength else {
        throw OnnxRuntimeError(kind: .internalFailure, message: "model output malformed: unexpected logits shape \(shape).")
    }
    let vocabSize = shape[2]

    let data = try logits.tensorData()
    let lastPositionOffset = (sequenceLength - 1) * vocabSize
    let byteOffset = lastPositionOffset * MemoryLayout<Float>.size
    let rowByteCount = vocabSize * MemoryLayout<Float>.size
    guard data.length >= byteOffset + rowByteCount else {
        throw OnnxRuntimeError(kind: .internalFailure, message: "model output malformed: logits buffer smaller than expected shape.")
    }

    var lastRow = [Float](repeating: 0, count: vocabSize)
    (data as Data).withUnsafeBytes { (rawPointer: UnsafeRawBufferPointer) in
        let source = rawPointer.baseAddress!.advanced(by: byteOffset).assumingMemoryBound(to: Float.self)
        lastRow.withUnsafeMutableBufferPointer { destination in
            destination.baseAddress!.update(from: source, count: vocabSize)
        }
    }

    return sampling.selectToken(from: lastRow)
}

/// Generation controls this runtime honors as an alternative to argmax decoding.
///
/// `temperature == nil` (or `<= 0`) keeps the default, deterministic argmax behavior. Setting
/// `temperature` switches to sampling: logits are scaled by `1 / temperature`, optionally narrowed
/// to the smallest set of tokens whose cumulative probability reaches `topP` (nucleus sampling),
/// then sampled. A `seed` makes sampling reproducible via a seeded generator; without one, sampling
/// draws from `SystemRandomNumberGenerator`.
private struct SamplingConfig {
    let temperature: Double?
    let topP: Double?
    let seed: Int?

    init(generation: Generation?) {
        if let temperature = generation?.temperature, temperature > 0 {
            self.temperature = temperature
        } else {
            self.temperature = nil
        }
        self.topP = generation?.topP
        self.seed = generation?.seed
    }

    func selectToken(from logits: [Float]) -> Int {
        guard let temperature else {
            return argmax(logits)
        }

        let scaled = logits.map { Float(Double($0) / temperature) }
        let probabilities = softmax(scaled)
        let candidates = topPFiltered(probabilities, topP: topP)

        if let seed {
            var generator = SplitMix64(seed: UInt64(bitPattern: Int64(seed)))
            return sample(candidates, using: &generator)
        } else {
            var generator = SystemRandomNumberGenerator()
            return sample(candidates, using: &generator)
        }
    }

    private func argmax(_ logits: [Float]) -> Int {
        var bestIndex = 0
        var bestValue = -Float.infinity
        for (index, value) in logits.enumerated() where value > bestValue {
            bestValue = value
            bestIndex = index
        }
        return bestIndex
    }

    private func softmax(_ logits: [Float]) -> [Float] {
        let maxValue = logits.max() ?? 0
        let exponentiated = logits.map { expf($0 - maxValue) }
        let sum = exponentiated.reduce(0, +)
        guard sum > 0 else { return logits.map { _ in 1.0 / Float(logits.count) } }
        return exponentiated.map { $0 / sum }
    }

    /// Narrows `probabilities` to the smallest prefix (sorted descending) whose cumulative mass
    /// reaches `topP`, renormalized so the remaining candidates sum to 1. Returns every index when
    /// `topP` is unset.
    private func topPFiltered(_ probabilities: [Float], topP: Double?) -> [(index: Int, probability: Float)] {
        let indexed = probabilities.enumerated().map { (index: $0.offset, probability: $0.element) }
        guard let topP, topP > 0, topP < 1 else {
            return indexed
        }

        let sorted = indexed.sorted { $0.probability > $1.probability }
        var cumulative: Float = 0
        var cutoff = sorted.count
        for (position, entry) in sorted.enumerated() {
            cumulative += entry.probability
            if cumulative >= Float(topP) {
                cutoff = position + 1
                break
            }
        }
        let selected = sorted.prefix(cutoff)
        let total = selected.reduce(Float(0)) { $0 + $1.probability }
        guard total > 0 else {
            return indexed
        }
        return selected.map { (index: $0.index, probability: $0.probability / total) }
    }

    private func sample(_ candidates: [(index: Int, probability: Float)], using generator: inout some RandomNumberGenerator) -> Int {
        guard !candidates.isEmpty else { return 0 }
        let target = Float.random(in: 0..<1, using: &generator)
        var cumulative: Float = 0
        for candidate in candidates {
            cumulative += candidate.probability
            if target < cumulative {
                return candidate.index
            }
        }
        return candidates[candidates.count - 1].index
    }
}

/// Deterministic, seedable `RandomNumberGenerator` (SplitMix64) used for reproducible sampling when
/// `generation.seed` is set -- `SystemRandomNumberGenerator` cannot be seeded.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A tokenizer + ORT session resolved and loaded for a specific model package, plus the decode
/// strategy auto-detected from the graph's declared input names at load time.
///
/// `@unchecked Sendable`: `ORTSession.run` is documented safe for concurrent invocation and this
/// value only ever crosses from `LoadedSessionBox` (an actor) back to its single caller, mirroring
/// the `@unchecked Sendable` pattern already used for actor-adjacent state elsewhere in this SDK.
private struct LoadedSession: @unchecked Sendable {
    let tokenizer: Tokenizer
    let session: ORTSession
    let decodeStrategy: DecodeStrategy
}

/// The decode contract this runtime detected for a loaded graph. `.kvCache` is chosen only when
/// every assumption the KV-cache decode path depends on (layer count, head count, head dimension,
/// per-layer `past_key_values`/`present` naming) is resolvable from the graph's declared input names
/// and the model directory's `config.json`; anything unresolvable conservatively falls back to
/// `.fullRecompute` rather than guessing.
private enum DecodeStrategy: Sendable {
    case fullRecompute
    case kvCache(KvCacheLayout)
}

/// Static geometry the KV-cache decode path needs to build empty initial `past_key_values` tensors
/// and locate this graph's `present.*` outputs, resolved once at load time.
private struct KvCacheLayout: Sendable {
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

/// Runs ONNX Runtime session creation and inference on a dedicated serial queue rather than the
/// Swift Concurrency cooperative thread pool: `ORTSession.init` and `ORTSession.run` are blocking
/// synchronous calls, and Swift Concurrency's own guidance is not to block its limited cooperative
/// threads with such work. A single shared queue is sufficient -- a single generation is inherently
/// sequential token-by-token, and the queue also gives cancellation-adjacent work one well-defined
/// place to execute.
private final class OnnxExecutionQueue: @unchecked Sendable {
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

    /// Auto-detects the decode strategy from the graph's declared input names, so no
    /// `ModelPackage` field or app-facing configuration is needed to pick between the plain and
    /// KV-cache IO contracts. Falls back to `.fullRecompute` -- always supported -- whenever any
    /// KV-cache assumption (naming convention, resolvable `config.json` architecture fields)
    /// doesn't hold, rather than guessing.
    private static func detectDecodeStrategy(session: ORTSession, directory: URL) throws -> DecodeStrategy {
        guard let inputNames = try? session.inputNames() else {
            return .fullRecompute
        }
        let hasPastKeyValues = inputNames.contains { $0.hasPrefix("past_key_values.") }
        guard hasPastKeyValues else {
            return .fullRecompute
        }

        guard let layout = try? kvCacheLayout(session: session, inputNames: inputNames, directory: directory) else {
            return .fullRecompute
        }
        return .kvCache(layout)
    }

    private static func kvCacheLayout(session: ORTSession, inputNames: [String], directory: URL) throws -> KvCacheLayout {
        let configPath = directory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configPath.path),
              let configData = try? Data(contentsOf: configPath),
              let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            throw OnnxRuntimeError(
                kind: .capability,
                message: "model files missing: 'config.json' not found or unreadable for KV-cache detection."
            )
        }

        // Field names vary by architecture family: Llama-style configs use
        // `num_hidden_layers`/`num_attention_heads`/`hidden_size`; GPT-2-style configs (still
        // common among small quantized decoder-with-past exports) use `n_layer`/`n_head`/`n_embd`
        // instead. Both are read so KV-cache detection isn't silently GPT-2-blind.
        guard let numLayers = intField(config, "num_hidden_layers", "n_layer") else {
            throw OnnxRuntimeError(
                kind: .capability,
                message: "model package malformed: 'config.json' missing 'num_hidden_layers'/'n_layer'."
            )
        }

        let numAttentionHeads = intField(config, "num_attention_heads", "n_head")
        let numKeyValueHeads = intField(config, "num_key_value_heads") ?? numAttentionHeads
        guard let numKeyValueHeads else {
            throw OnnxRuntimeError(kind: .capability, message: "model package malformed: 'config.json' missing attention head count.")
        }

        let headDim: Int
        if let explicitHeadDim = intField(config, "head_dim") {
            headDim = explicitHeadDim
        } else if let hiddenSize = intField(config, "hidden_size", "n_embd"), let numAttentionHeads, numAttentionHeads > 0 {
            headDim = hiddenSize / numAttentionHeads
        } else {
            throw OnnxRuntimeError(
                kind: .capability,
                message: "model package malformed: 'config.json' missing 'hidden_size'/'n_embd'/'head_dim'."
            )
        }

        // `use_cache_branch` (some merged Optimum exports' boolean cache-branch selector) needs a
        // `bool`-typed tensor, which this version of the ONNX Runtime Objective-C bindings does not
        // expose an `ORTTensorElementDataType` case for -- conservatively fall back to
        // `.fullRecompute` for such graphs rather than feeding a mistyped tensor.
        guard !inputNames.contains("use_cache_branch") else {
            throw OnnxRuntimeError(
                kind: .capability,
                message: "unsupported model format: 'use_cache_branch' input is not supported by this runtime's KV-cache path."
            )
        }

        let outputNames = (try? session.outputNames()) ?? []
        for layer in 0..<numLayers {
            for part in ["key", "value"] {
                guard inputNames.contains("past_key_values.\(layer).\(part)") else {
                    throw OnnxRuntimeError(
                        kind: .capability,
                        message: "model package malformed: missing 'past_key_values.\(layer).\(part)' input."
                    )
                }
                guard outputNames.contains("present.\(layer).\(part)") else {
                    throw OnnxRuntimeError(
                        kind: .capability,
                        message: "model package malformed: missing 'present.\(layer).\(part)' output."
                    )
                }
            }
        }

        return KvCacheLayout(
            numLayers: numLayers,
            numKeyValueHeads: numKeyValueHeads,
            headDim: headDim,
            hasPositionIds: inputNames.contains("position_ids")
        )
    }

    private static func intField(_ config: [String: Any], _ keys: String...) -> Int? {
        for key in keys {
            if let value = config[key] as? Int { return value }
            if let value = config[key] as? NSNumber { return value.intValue }
        }
        return nil
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
