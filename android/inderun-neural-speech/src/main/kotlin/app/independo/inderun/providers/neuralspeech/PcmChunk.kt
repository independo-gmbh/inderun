package app.independo.inderun.providers.neuralspeech

/**
 * One block of mono 16-bit PCM produced by a [NeuralSpeechRuntime].
 *
 * [sampleRate] must equal the package's `speech.sampleRate`; the provider never resamples and
 * treats any other rate as an internal error. Compared by content: two chunks are equal when they
 * carry the same samples at the same rate.
 *
 * @property isLast True on the final chunk of one sentence.
 */
data class PcmChunk(val samples: ShortArray, val sampleRate: Int, val isLast: Boolean) {
    override fun equals(other: Any?): Boolean = other is PcmChunk &&
        sampleRate == other.sampleRate &&
        isLast == other.isLast &&
        samples.contentEquals(other.samples)

    override fun hashCode(): Int {
        var result = samples.contentHashCode()
        result = 31 * result + sampleRate
        result = 31 * result + isLast.hashCode()
        return result
    }

    // Never the samples themselves: they are request-derived audio.
    override fun toString(): String = "PcmChunk(frames=${samples.size}, sampleRate=$sampleRate, isLast=$isLast)"
}
