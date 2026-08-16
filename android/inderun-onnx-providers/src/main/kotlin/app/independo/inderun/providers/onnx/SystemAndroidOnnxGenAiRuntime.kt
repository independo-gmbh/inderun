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
 * This type only orchestrates; the actual behavior is documented next to where it's implemented,
 * not restated here (kept in one place to avoid the two copies drifting apart):
 * - Decode-strategy auto-detection (plain vs. KV-cache IO contract): [detectDecodeStrategy] in
 *   `OnnxSessionLoadingKvCacheDetection.kt`.
 * - Session/execution-provider setup, bundled-asset extraction, and the KV-cache/NNAPI
 *   incompatibility: `OnnxSessionLoading.kt`.
 * - Sampling (greedy/temperature/top-p): `OnnxSampling.kt`.
 * - The two decode-step loops: `OnnxDecoders.kt`.
 * - Chat-template gap: [formatMessages].
 *
 * `programmatic` model sources are out of scope for this default runtime (no files to resolve,
 * matching the Web/Apple members' own `programmatic` carve-out); it reports *runtime package
 * unavailable* rather than throwing.
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

    /**
     * Chat-template application is not attempted: `ai.djl.huggingface:tokenizers` exposes no
     * `applyChatTemplate`-equivalent API (verified against its `0.33.0` public surface), so this
     * is a permanent gap for this runtime, not an oversight pending evaluation -- unlike the
     * Apple/Web members. Falls back unconditionally to a plain `"role: content"` join.
     */
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
