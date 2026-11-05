package app.independo.inderun.providers.neuralspeech

/** The element data of a [SpeechTensor]. Compared by content. */
sealed interface SpeechTensorData {
    /** 32-bit floats. */
    data class F32(val values: FloatArray) : SpeechTensorData {
        override fun equals(other: Any?): Boolean = other is F32 && values.contentEquals(other.values)

        override fun hashCode(): Int = values.contentHashCode()
    }

    /** 64-bit integers, e.g. token ids. */
    data class I64(val values: LongArray) : SpeechTensorData {
        override fun equals(other: Any?): Boolean = other is I64 && values.contentEquals(other.values)

        override fun hashCode(): Int = values.contentHashCode()
    }
}

/** A named tensor exchanged with a [SpeechGraphExecutor]. */
data class SpeechTensor(val shape: List<Int>, val data: SpeechTensorData)

/**
 * Runs one graph of a speech model package; implemented by the ONNX Runtime executor (PR 4).
 * [load] receives the package's `speech.graphs` (role to file), [run] executes the graph with that
 * role, and [close] releases what [load] acquired.
 */
interface SpeechGraphExecutor {
    suspend fun load(graphs: Map<String, String>)

    suspend fun run(role: String, inputs: Map<String, SpeechTensor>): Map<String, SpeechTensor>

    fun close()
}
