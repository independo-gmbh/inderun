import Foundation
import IndeRunContracts
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
