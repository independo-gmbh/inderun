package app.independo.inderun.providers.onnx

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OnnxTensorLike
import ai.onnxruntime.OrtSession
import kotlinx.coroutines.withContext
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.LongBuffer

/**
 * IO tensor names shared by both decode paths and the KV-cache detection logic.
 */
private const val INPUT_IDS = "input_ids"
private const val ATTENTION_MASK = "attention_mask"
private const val POSITION_IDS = "position_ids"
private const val LOGITS = "logits"
private const val PAST_KEY_VALUES_PREFIX = "past_key_values."

/** One decode step: produce a single generated token id given the tokens fed so far. */
internal interface StepDecoder {
    suspend fun step(sampling: SamplingConfig): Long
}

/**
 * Full-sequence-recompute decode step: the plain `input_ids`/`attention_mask`/`logits` IO
 * contract, without KV-cache reuse. Input buffers are preallocated once for the whole generation
 * (sized to `promptLength + maxOutputTokens`, as direct buffers so ORT can reference them without
 * an extra native copy) and written into a growing subrange each step, so only the token-id list
 * grows -- no fresh buffer allocation per token. The `OnnxTensor`/`OrtSession.Result` objects
 * themselves are still recreated every step: the sequence-length axis of their shape changes each
 * step, so the tensor object (not its backing memory) cannot be reused across steps.
 */
internal class FullRecomputeDecoder(
    private val loaded: LoadedSession,
    promptTokenIds: List<Long>,
    maxOutputTokens: Int,
) : StepDecoder {
    private val tokenIds = promptTokenIds.toMutableList()
    private val capacity = promptTokenIds.size + maxOutputTokens
    private val inputIdsBuffer = directLongBuffer(capacity)
    private val attentionMaskBuffer = directLongBuffer(capacity)

    override suspend fun step(sampling: SamplingConfig): Long {
        val sequenceLength = tokenIds.size
        for (index in 0 until sequenceLength) {
            inputIdsBuffer.put(index, tokenIds[index])
            attentionMaskBuffer.put(index, 1L)
        }
        val shape = longArrayOf(1, sequenceLength.toLong())

        val nextToken = withContext(OnnxExecutionDispatcher.dispatcher) {
            OnnxTensor.createTensor(loaded.environment, sliceView(inputIdsBuffer, sequenceLength), shape).use { inputIdsTensor ->
                OnnxTensor.createTensor(loaded.environment, sliceView(attentionMaskBuffer, sequenceLength), shape).use { attentionMaskTensor ->
                    val inputs = mapOf<String, OnnxTensorLike>(INPUT_IDS to inputIdsTensor, ATTENTION_MASK to attentionMaskTensor)
                    runOnnxSession(loaded.session, inputs, setOf(LOGITS)).use { result ->
                        val logitsTensor = requireOutput(result, LOGITS)
                        selectNextToken(logitsTensor, sequenceLength, sampling)
                    }
                }
            }
        }

        tokenIds += nextToken
        return nextToken
    }

    private fun sliceView(source: LongBuffer, length: Int): LongBuffer {
        val view = source.duplicate()
        view.position(0)
        view.limit(length)
        return view.slice()
    }
}

/**
 * KV-cache decode step, following the legacy (non-merged) Hugging Face Optimum
 * `decoder_with_past_model` export convention: exactly one token is fed as `input_ids` per model
 * call (this graph's sequence-length axis is traced fixed at 1), with each call's `present.*`
 * outputs threaded back in as the next call's `past_key_values.*` inputs directly (no copy) --
 * itself the buffer-reuse win for this path, mirroring the Apple member's `KvCacheDecoder`.
 */
internal class KvCacheDecoder(
    private val loaded: LoadedSession,
    private val layout: KvCacheLayout,
    promptTokenIds: List<Long>,
) : StepDecoder {
    private val tokenIds = promptTokenIds.toMutableList()
    private var pastKeyValues: Map<String, OnnxTensor> = layout.emptyPastKeyValues(loaded.environment)

    /**
     * Prompt tokens not yet fed to the model. This graph traces `input_ids` with a
     * sequence-length axis fixed at 1 -- there is no separate no-past graph to prefill the prompt
     * in one call -- so the prompt must be replayed through the same with-past session one token
     * at a time to build up `past_key_values` before generation can begin.
     */
    private val remainingPromptTokens = ArrayDeque(promptTokenIds)

    /** Number of tokens already fed into the model (== the current `past_key_values` length). */
    private var fedCount = 0

    override suspend fun step(sampling: SamplingConfig): Long {
        // Replay every remaining prompt token except the last, discarding logits -- only the
        // last prompt token's logits (fed with every earlier token already in `past_key_values`)
        // predict the first generated token.
        while (remainingPromptTokens.size > 1) {
            feedToken(remainingPromptTokens.removeFirst(), wantLogits = false, sampling = sampling)
        }

        val tokenToFeed = if (remainingPromptTokens.isEmpty()) tokenIds.last() else remainingPromptTokens.removeFirst()
        val nextToken = feedToken(tokenToFeed, wantLogits = true, sampling = sampling)
            ?: throw OnnxRuntimeError(kind = OnnxRuntimeErrorKind.INTERNAL_FAILURE, message = "model output malformed: missing '$LOGITS' output.")
        tokenIds += nextToken
        return nextToken
    }

    /**
     * Feeds exactly one token (`input_ids`/`attention_mask` shape `[1, 1]`, matching this
     * graph's fixed sequence-length-1 trace) and advances `pastKeyValues`/`fedCount`. Returns the
     * sampled next token when `wantLogits` is set (the `logits` output is only requested then, to
     * avoid computing/transferring it for the discarded prompt-replay steps), `null` otherwise.
     */
    private suspend fun feedToken(token: Long, wantLogits: Boolean, sampling: SamplingConfig): Long? {
        val totalLength = fedCount + 1

        return withContext(OnnxExecutionDispatcher.dispatcher) {
            val inputIdsTensor = OnnxTensor.createTensor(loaded.environment, LongBuffer.wrap(longArrayOf(token)), longArrayOf(1, 1))
            val attentionMaskTensor = OnnxTensor.createTensor(
                loaded.environment,
                LongBuffer.wrap(LongArray(totalLength) { 1L }),
                longArrayOf(1, totalLength.toLong()),
            )
            val positionIdsTensor = if (layout.hasPositionIds) {
                OnnxTensor.createTensor(loaded.environment, LongBuffer.wrap(longArrayOf(fedCount.toLong())), longArrayOf(1, 1))
            } else {
                null
            }

            try {
                val inputs = mutableMapOf<String, OnnxTensorLike>(INPUT_IDS to inputIdsTensor, ATTENTION_MASK to attentionMaskTensor)
                positionIdsTensor?.let { inputs[POSITION_IDS] = it }
                inputs.putAll(pastKeyValues)

                val outputNames = layout.presentOutputNames.toMutableSet()
                if (wantLogits) outputNames += LOGITS

                // The result's `present.*` outputs become the next step's `past_key_values.*`
                // inputs -- not closed here, unlike the full-recompute path's result, since those
                // tensors must outlive this call.
                val result = runOnnxSession(loaded.session, inputs, outputNames)

                val previousPastKeyValues = pastKeyValues
                val nextPastKeyValues = mutableMapOf<String, OnnxTensor>()
                for (layer in 0 until layout.numLayers) {
                    for (part in listOf("key", "value")) {
                        val presentName = "present.$layer.$part"
                        val pastName = "$PAST_KEY_VALUES_PREFIX$layer.$part"
                        nextPastKeyValues[pastName] = requireOutput(result, presentName)
                    }
                }
                pastKeyValues = nextPastKeyValues
                previousPastKeyValues.values.forEach { it.close() }
                fedCount += 1

                if (!wantLogits) return@withContext null
                val logitsTensor = requireOutput(result, LOGITS)
                selectNextToken(logitsTensor, sequenceLength = 1, sampling = sampling).also { logitsTensor.close() }
            } finally {
                inputIdsTensor.close()
                attentionMaskTensor.close()
                positionIdsTensor?.close()
            }
        }
    }
}

private fun requireOutput(result: OrtSession.Result, name: String): OnnxTensor = result.get(name).orElseThrow {
    OnnxRuntimeError(kind = OnnxRuntimeErrorKind.INTERNAL_FAILURE, message = "model output malformed: missing '$name' output.")
} as OnnxTensor

private fun directLongBuffer(capacity: Int): LongBuffer = ByteBuffer.allocateDirect(capacity * java.lang.Long.BYTES).order(ByteOrder.nativeOrder()).asLongBuffer()
