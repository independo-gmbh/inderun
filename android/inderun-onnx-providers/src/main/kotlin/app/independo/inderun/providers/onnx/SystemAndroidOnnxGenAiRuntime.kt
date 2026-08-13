package app.independo.inderun.providers.onnx

import android.content.Context
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.ModelPackage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ensureActive
import kotlin.coroutines.coroutineContext

/**
 * Production [AndroidOnnxGenAiRuntime] backed by ONNX Runtime Mobile
 * (`com.microsoft.onnxruntime:onnxruntime-android`) and a Hugging Face tokenizer
 * (`ai.djl.huggingface:tokenizers`).
 *
 * **IO contract**: this runtime auto-detects, from the loaded graph's declared input names, which
 * of two decoder-only export shapes a model uses -- no [ModelPackage] field or app-facing
 * configuration selects it (see [detectDecodeStrategy] in `OnnxSessionLoadingKvCacheDetection.kt`).
 * Both require `input_ids`/`attention_mask` (`int64`) and a `logits` output (`float32`, `[1,
 * sequenceLength, vocabSize]`):
 *
 * - **Plain** (no `past_key_values.*` inputs, [DecodeStrategy.FullRecompute]): the full sequence
 *   is recomputed on every decode step. Always supported; the fallback when KV-cache detection
 *   can't establish every assumption below.
 * - **KV-cache** ([DecodeStrategy.KvCache], matching the legacy (non-merged) Hugging Face Optimum
 *   `decoder_with_past_model` export convention): exactly one token is fed as `input_ids` per
 *   model call, the prompt replayed one token at a time first. Requires `num_hidden_layers` (or
 *   GPT-2-style `n_layer`), `num_attention_heads`/`n_head` (or `num_key_value_heads`), and
 *   `hidden_size`/`n_embd` (or `head_dim`) to be readable from `config.json`. Mirrors the Apple
 *   member's `KvCacheDecoder`; see `OnnxDecoders.kt`.
 *
 * **Decode loop.** Generation defaults to greedy (argmax); `generation.temperature`/`topP`/`seed`
 * select sampling instead (see `OnnxSampling.kt`). `generation.stop` sequences are honored. Session
 * creation and every `run()` call execute on a dedicated single-thread dispatcher rather than
 * [kotlinx.coroutines.Dispatchers.IO]/[kotlinx.coroutines.Dispatchers.Default], since
 * `OrtSession.run()` is a blocking synchronous call (`OnnxTensorExecution.kt`). `OrtEnvironment` is
 * already a process-wide singleton per its own Java API contract (`OrtEnvironment.getEnvironment()`),
 * so no separate shared-instance wrapper is needed, unlike the Apple member's `ORTEnv`. The NNAPI
 * execution provider is configured by default on the plain decode path, falling back to XNNPACK
 * and then ORT's default CPU EP if NNAPI is unavailable on the host; the KV-cache path never uses
 * NNAPI (see `OnnxSessionLoading.kt`). See
 * `docs/architecture/onnx-runtime-provider-family.md` for the full specification and residual
 * risks -- none of the above has been exercised on a real device or model; that remains #88.
 *
 * **Chat formatting.** Chat-template application is not attempted: `ai.djl.huggingface:tokenizers`
 * exposes no `applyChatTemplate`-equivalent API (verified against its `0.33.0` public surface), so
 * this is a permanent gap for this runtime, not an oversight pending evaluation -- unlike the
 * Apple/Web members. Input always falls back to a plain `"role: content"` join.
 *
 * **Bundled asset extraction.** `bundled` sources are copied from Android assets into app-private
 * storage under a directory keyed by the session cache key (id/format/version/source/checksums), so
 * a changed `version`/`ref`/checksum extracts into a fresh directory rather than silently reusing
 * stale bytes. Extraction is atomic (copied into a temp directory, marked complete, then moved into
 * place) so an interrupted copy cannot poison a later load.
 *
 * `programmatic` model sources are out of scope for this default runtime (no files to resolve,
 * matching the Web/Apple members' own `programmatic` carve-out); it reports *runtime package
 * unavailable* rather than throwing. This default runtime has not been run against a real model
 * on-device -- real-device verification is tracked alongside the Apple member's own follow-up (#88).
 */
class SystemAndroidOnnxGenAiRuntime(context: Context) : AndroidOnnxGenAiRuntime {

    private val session = LoadedSessionBox(context)

    override suspend fun prepare(modelPackage: ModelPackage): AndroidOnnxRuntimeAvailability = try {
        session.loaded(modelPackage)
        AndroidOnnxRuntimeAvailability(available = true)
    } catch (error: CancellationException) {
        throw error
    } catch (error: OnnxRuntimeError) {
        AndroidOnnxRuntimeAvailability(available = false, reason = error.message)
    } catch (error: Throwable) {
        AndroidOnnxRuntimeAvailability(
            available = false,
            reason = "runtime initialization failed: ${error.localizedMessage ?: error}",
        )
    }

    override suspend fun generate(input: AndroidOnnxGenerationInput): AndroidOnnxGenerationOutput {
        val loaded = session.loaded(input.modelPackage)
        val prompt = formatMessages(input.messages)
        val text = decode(loaded, prompt, input)
        return AndroidOnnxGenerationOutput(text = text, finishReason = FinishReason.STOP)
    }

    private fun formatMessages(messages: List<AndroidOnnxGenerationMessage>): String = messages.joinToString(separator = "\n") { "${it.role.rawValue}: ${it.content}" }

    private suspend fun decode(loaded: LoadedSession, prompt: String, input: AndroidOnnxGenerationInput): String {
        val maxNewTokens = (input.generation?.maxOutputTokens ?: DEFAULT_MAX_NEW_TOKENS).toInt()
        val stopSequences = input.generation?.stop.orEmpty().filter { it.isNotEmpty() }
        val sampling = SamplingConfig(input.generation)

        val promptTokenIds = loaded.tokenizer.encode(prompt).ids.toList()
        val decoder = makeDecoder(loaded, promptTokenIds, maxNewTokens)
        val generatedIds = mutableListOf<Long>()
        var matchedStop: String? = null

        while (generatedIds.size < maxNewTokens) {
            coroutineContext.ensureActive()

            val nextTokenId = decoder.step(sampling)
            generatedIds += nextTokenId

            if (isEosToken(nextTokenId, loaded.eosTokenId)) {
                break
            }

            if (stopSequences.isNotEmpty()) {
                val decodedSoFar = loaded.tokenizer.decode(generatedIds.toLongArray(), true)
                val stop = matchStopSequence(decodedSoFar, stopSequences)
                if (stop != null) {
                    matchedStop = stop
                    break
                }
            }
        }

        var text = loaded.tokenizer.decode(generatedIds.toLongArray(), true)
        if (matchedStop != null && text.endsWith(matchedStop)) {
            text = text.removeSuffix(matchedStop)
        }
        return text
    }

    private fun makeDecoder(loaded: LoadedSession, promptTokenIds: List<Long>, maxOutputTokens: Int): StepDecoder = when (val strategy = loaded.decodeStrategy) {
        is DecodeStrategy.FullRecompute -> FullRecomputeDecoder(loaded, promptTokenIds, maxOutputTokens)
        is DecodeStrategy.KvCache -> KvCacheDecoder(loaded, strategy.layout, promptTokenIds)
    }

    private companion object {
        const val DEFAULT_MAX_NEW_TOKENS = 256L
    }
}

/** Whether the just-generated token is the tokenizer's end-of-sequence token. */
internal fun isEosToken(tokenId: Long, eosTokenId: Long?): Boolean = eosTokenId != null && tokenId == eosTokenId

/** Returns the first `generation.stop` sequence the decoded-so-far text ends with, or `null`. */
internal fun matchStopSequence(decodedSoFar: String, stopSequences: List<String>): String? = stopSequences.firstOrNull { decodedSoFar.endsWith(it) }
