import Foundation
import IndeRunContracts
import OnnxRuntimeBindings

/// Reads the last-position logits row directly out of the tensor buffer rather than copying the
/// full `[sequenceLength x vocabSize]` tensor into a Swift `Array` -- the decode loop only ever
/// needs the last row -- then either argmaxes it (the default) or samples from it when
/// `sampling` selects temperature/top-p sampling.
func selectNextToken(logits: ORTValue, sequenceLength: Int, sampling: SamplingConfig) throws -> Int {
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
struct SamplingConfig {
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
