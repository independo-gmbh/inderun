import Foundation
import IndeRunNeuralSpeech

/// What the exported Articulino `.aimodel` accepts (#279). The export fixes every axis but one per
/// input (batch 1, the feature sizes, the voice cache's prompt length ``promptFrames``) and gives the
/// variable axis a range. Core AI does not refuse a shape outside that but returns wrong numbers or
/// aborts, so the executor checks these before any Core AI call. This table is the only copy; keep it
/// in step with the export.
enum CoreAIArticulinoSignature {
    /// The prompt length (`voice_cache` axis 4) the export fixes. A voice whose cache differs is refused
    /// at `availability`, `prepare`, and here.
    static let promptFrames = 125

    /// The variable axis of an input that has one, here always axis 1, with its upper bound. The export
    /// minimum is 2, but the spike measured length 1 correct against eager (125 dB; `dit_step` runs at
    /// L = 1 when one new frame is left), so the check accepts 1 and refuses 0.
    struct Bound {
        let input: String
        let axis: Int
        let max: Int
    }

    /// Per role: `text` N <= 257, `dit_step` L <= 1024, `decoder` F <= 1036.
    static let bounds: [String: Bound] = [
        "text": Bound(input: "text_ids", axis: 1, max: 257),
        "dit_step": Bound(input: "x", axis: 1, max: 1024),
        "decoder": Bound(input: "latents", axis: 1, max: 1036)
    ]

    /// The exact shape of each input; `nil` is the variable axis (axis 1 where there is one).
    static let shapes: [String: [String: [Int?]]] = [
        "text": ["text_ids": [1, nil], "language": [1, nil], "text_mask": [1, nil], "voice_vector": [1, 768]],
        "dit_step": [
            "x": [1, nil, 96], "t": [1], "frame_cond": [1, nil, 512], "voice_tokens": [1, 32, 768], "voice_vector": [1, 768],
            "voice_cache": [8, 2, 1, 6, promptFrames, 64]
        ],
        "decoder": ["latents": [1, nil, 96]]
    ]

    /// Zero inputs of the declared dtypes at the smallest shapes (N = L = F = 2), one set per role.
    /// `text_ids`, `language` and `text_mask` are int64 here; the tensor bridge narrows them to int32.
    static func warmUpInputs(role: String) -> [String: SpeechTensor]? {
        func zeros(_ shape: [Int]) -> SpeechTensor {
            SpeechTensor(shape: shape, data: .f32([Float](repeating: 0, count: shape.reduce(1, *))))
        }
        func ints(_ shape: [Int]) -> SpeechTensor {
            SpeechTensor(shape: shape, data: .i64([Int64](repeating: 0, count: shape.reduce(1, *))))
        }
        switch role {
        case "text":
            return ["text_ids": ints([1, 2]), "language": ints([1, 2]), "text_mask": ints([1, 2]), "voice_vector": zeros([1, 768])]
        case "dit_step":
            return [
                "x": zeros([1, 2, 96]), "t": zeros([1]), "frame_cond": zeros([1, 2, 512]), "voice_tokens": zeros([1, 32, 768]),
                "voice_vector": zeros([1, 768]), "voice_cache": zeros([8, 2, 1, 6, 125, 64])
            ]
        case "decoder":
            return ["latents": zeros([1, 2, 96])]
        default:
            return nil
        }
    }
}

/// Throws (`capability`, before Core AI is touched) when an input of `role` has another rank or fixed
/// dimension than the export, `input shape unsupported by the Core AI export: <role>.<name> <shape>,
/// expected <shape>` (`*` is the variable axis), or when its variable axis is empty or longer than the
/// export allows, `input exceeds the Core AI bound: <role>.<name> <n> > <max>`. Inputs not present are
/// not checked here.
func checkCoreAIBounds(role: String, inputs: [String: SpeechTensor]) throws {
    for (name, expected) in (CoreAIArticulinoSignature.shapes[role] ?? [:]).sorted(by: { $0.key < $1.key }) {
        guard let shape = inputs[name]?.shape else { continue }
        let matches = shape.count == expected.count && zip(shape, expected).allSatisfy { $1 == nil ? $0 >= 1 : $0 == $1 }
        guard matches else {
            let want = expected.map { $0.map(String.init) ?? "*" }.joined(separator: ",")
            let got = shape.map(String.init).joined(separator: ",")
            throw NeuralSpeechRuntimeError(
                kind: .capability,
                message: "input shape unsupported by the Core AI export: \(role).\(name) [\(got)], expected [\(want)]"
            )
        }
    }
    guard let bound = CoreAIArticulinoSignature.bounds[role],
          let shape = inputs[bound.input]?.shape, shape.indices.contains(bound.axis) else { return }
    let size = shape[bound.axis]
    guard size <= bound.max else {
        throw NeuralSpeechRuntimeError(
            kind: .capability, message: "input exceeds the Core AI bound: \(role).\(bound.input) \(size) > \(bound.max)"
        )
    }
}

/// The prompt length (`voice_cache` axis 4) a voice bundle declares in its safetensors header, `nil` when
/// the file cannot be read or has no such tensor (the pipeline's own parse reports those). Reads the
/// header only, so it is cheap on the routing path.
func voicePromptFrames(at url: URL) -> Int? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let prefix = try? handle.read(upToCount: 8), prefix.count == 8 else { return nil }
    let length = prefix.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    guard length > 0, length <= 1 << 20, let header = try? handle.read(upToCount: Int(length)), header.count == Int(length),
          let json = (try? JSONSerialization.jsonObject(with: header)) as? [String: Any],
          let cache = json["voice_cache"] as? [String: Any], let shape = cache["shape"] as? [Int], shape.count > 4 else { return nil }
    return shape[4]
}

/// Runs each of `roles` once on zero inputs at the smallest shapes, so Core AI loads and compiles each
/// function during `prepare`. The first sentence's own shapes (and the first call after prepare) can
/// still take longer than later ones: the phone measured 2,045 ms to first audio after prepare against
/// 603 ms later. Returns `warm-up failed: <role>: <message>` for the first failure, `nil` when all ran.
func warmUpCoreAIGraphs(executor: any SpeechGraphExecutor, roles: [String]) async -> String? {
    for role in roles.sorted() {
        guard let inputs = CoreAIArticulinoSignature.warmUpInputs(role: role) else { continue }
        do {
            _ = try await executor.run(role: role, inputs: inputs)
        } catch {
            let message = (error as? NeuralSpeechRuntimeError)?.message ?? error.localizedDescription
            return "warm-up failed: \(role): \(message)"
        }
    }
    return nil
}
