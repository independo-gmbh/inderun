import Foundation
import IndeRunContracts
import Tokenizers

/// Default production `OnnxGenAiRuntime`, backed by the official ONNX Runtime SPM bindings
/// (`microsoft/onnxruntime-swift-package-manager`) for inference and `swift-transformers`'s
/// `Tokenizers` module for tokenization.
///
/// This type only orchestrates; the actual behavior is documented next to where it's implemented,
/// not restated here (kept in one place to avoid the two copies drifting apart):
/// - Decode-strategy auto-detection (plain vs. KV-cache IO contract): `detectDecodeStrategy(session:directory:)`
///   in `OnnxSessionLoading+KvCacheDetection.swift`.
/// - Session/execution-provider setup, including the KV-cache/CoreML incompatibility: `OnnxSessionLoading.swift`.
/// - Sampling (greedy/temperature/top-p): `OnnxSampling.swift`.
/// - The two decode-step loops: `SystemOnnxGenAiRuntime+Decoders.swift`.
/// - Chat template application: `encodeInput(_:tokenizer:)` below.
///
/// Model sources: `bundled` resolves under `Bundle.main.resourceURL`, `filesystem` and
/// `app_managed` resolve `source.ref` as a directory path. `programmatic` has no files to resolve
/// and is reported as unavailable; apps using `programmatic` sources must supply their own runtime.
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
            usage: TaskResultUsage(
                inputTokens: promptLength,
                outputTokens: generatedIds.count,
                totalTokens: promptLength + generatedIds.count
            )
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
