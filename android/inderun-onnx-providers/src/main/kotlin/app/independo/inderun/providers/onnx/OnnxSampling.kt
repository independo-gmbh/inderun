package app.independo.inderun.providers.onnx

import ai.onnxruntime.OnnxTensor
import app.independo.inderun.contracts.Generation
import kotlin.random.Random

/**
 * Reads the last-position logits row directly out of the tensor's backing [java.nio.FloatBuffer]
 * rather than materializing the full `[sequenceLength x vocabSize]` tensor via [OnnxTensor.getValue]
 * -- the decode loop only ever needs the last row -- then either argmaxes it (the default) or
 * samples from it when [sampling] selects temperature/top-p sampling.
 */
internal fun selectNextToken(logits: OnnxTensor, sequenceLength: Int, sampling: SamplingConfig): Long {
    val shape = logits.info.shape
    if (shape.size != 3 || shape[0] != 1L || shape[1] != sequenceLength.toLong()) {
        throw OnnxRuntimeError(
            kind = OnnxRuntimeErrorKind.INTERNAL_FAILURE,
            message = "model output malformed: unexpected logits shape ${shape.toList()}.",
        )
    }
    val vocabSize = shape[2].toInt()

    val buffer = logits.floatBuffer
    val lastPositionOffset = (sequenceLength - 1) * vocabSize
    if (buffer.limit() < lastPositionOffset + vocabSize) {
        throw OnnxRuntimeError(
            kind = OnnxRuntimeErrorKind.INTERNAL_FAILURE,
            message = "model output malformed: logits buffer smaller than expected shape.",
        )
    }

    val lastRow = FloatArray(vocabSize)
    buffer.position(lastPositionOffset)
    buffer.get(lastRow)

    return sampling.selectToken(lastRow)
}

/**
 * Generation controls this runtime honors as an alternative to argmax decoding.
 *
 * `temperature == null` (or `<= 0`) keeps the default, deterministic argmax behavior. Setting
 * `temperature` switches to sampling: logits are scaled by `1 / temperature`, optionally narrowed
 * to the smallest set of tokens whose cumulative probability reaches `topP` (nucleus sampling),
 * then sampled. A `seed` makes sampling reproducible via [kotlin.random.Random], which is natively
 * seedable -- unlike Apple's `SystemRandomNumberGenerator`, no custom seedable generator is needed.
 */
internal class SamplingConfig(generation: Generation?) {
    private val temperature: Double? = generation?.temperature?.takeIf { it > 0 }
    private val topP: Double? = generation?.topP
    private val seed: Long? = generation?.seed
    private val random: Random by lazy { seed?.let { Random(it) } ?: Random.Default }

    fun selectToken(logits: FloatArray): Long {
        val temperature = temperature ?: return argmax(logits).toLong()

        val scaled = FloatArray(logits.size) { (logits[it] / temperature).toFloat() }
        val probabilities = softmax(scaled)
        val candidates = topPFiltered(probabilities, topP)
        return sample(candidates).toLong()
    }

    private fun argmax(logits: FloatArray): Int {
        var bestIndex = 0
        var bestValue = Float.NEGATIVE_INFINITY
        for (index in logits.indices) {
            if (logits[index] > bestValue) {
                bestValue = logits[index]
                bestIndex = index
            }
        }
        return bestIndex
    }

    private fun softmax(logits: FloatArray): FloatArray {
        val maxValue = logits.maxOrNull() ?: 0f
        val exponentiated = FloatArray(logits.size) { kotlin.math.exp((logits[it] - maxValue).toDouble()).toFloat() }
        val sum = exponentiated.sum()
        if (sum <= 0f) {
            return FloatArray(logits.size) { 1f / logits.size }
        }
        return FloatArray(exponentiated.size) { exponentiated[it] / sum }
    }

    /**
     * Narrows `probabilities` to the smallest prefix (sorted descending) whose cumulative mass
     * reaches `topP`, renormalized so the remaining candidates sum to 1. Returns every index when
     * `topP` is unset.
     */
    private fun topPFiltered(probabilities: FloatArray, topP: Double?): List<Pair<Int, Float>> {
        val indexed = probabilities.mapIndexed { index, probability -> index to probability }
        if (topP == null || topP <= 0 || topP >= 1) {
            return indexed
        }

        val sorted = indexed.sortedByDescending { it.second }
        var cumulative = 0f
        var cutoff = sorted.size
        for ((position, entry) in sorted.withIndex()) {
            cumulative += entry.second
            if (cumulative >= topP.toFloat()) {
                cutoff = position + 1
                break
            }
        }
        val selected = sorted.take(cutoff)
        val total = selected.sumOf { it.second.toDouble() }.toFloat()
        if (total <= 0f) {
            return indexed
        }
        return selected.map { (index, probability) -> index to probability / total }
    }

    private fun sample(candidates: List<Pair<Int, Float>>): Int {
        if (candidates.isEmpty()) return 0
        val target = random.nextFloat()
        var cumulative = 0f
        for ((index, probability) in candidates) {
            cumulative += probability
            if (target < cumulative) {
                return index
            }
        }
        return candidates.last().first
    }
}
