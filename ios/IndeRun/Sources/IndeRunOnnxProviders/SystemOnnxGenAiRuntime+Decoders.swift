import Foundation
import OnnxRuntimeBindings

/// IO tensor names shared by both decode paths and the KV-cache detection logic. File-scope (not
/// nested) so every private type in this file -- the two decoders -- can share them without
/// widening any type's own access level.
private let inputIdsName = "input_ids"
private let attentionMaskName = "attention_mask"
private let positionIdsName = "position_ids"
private let logitsName = "logits"
private let pastKeyValuesPrefix = "past_key_values."

/// One decode step: append a single generated token id given the tokens produced so far.
protocol StepDecoder {
    mutating func step(sampling: SamplingConfig) async throws -> Int
}

/// Full-sequence-recompute decode step: the plain `input_ids`/`attention_mask`/`logits` IO
/// contract, without KV-cache reuse. Input buffers are preallocated once for the whole generation
/// (sized to `promptLength + maxOutputTokens`) and written into a growing subrange each step, so
/// only the token-id array grows -- no fresh `NSMutableData` allocation per token.
struct FullRecomputeDecoder: StepDecoder {
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
struct KvCacheDecoder: StepDecoder {
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
