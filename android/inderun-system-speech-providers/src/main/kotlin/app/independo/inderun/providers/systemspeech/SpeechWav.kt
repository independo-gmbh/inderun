package app.independo.inderun.providers.systemspeech

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Reads what a RIFF/WAVE file says about itself. `synthesizeToFile` promises a file, not a format,
 * so the provider checks that the bytes are what it declares before it hands them over.
 */
internal object SpeechWav {
    /** The audio's duration, or null when [bytes] is not a WAV file it can measure. */
    fun durationMs(bytes: ByteArray): Double? {
        if (bytes.size < 12 || tag(bytes, 0) != "RIFF" || tag(bytes, 8) != "WAVE") return null
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        var byteRate: Int? = null
        var offset = 12
        while (offset + 8 <= bytes.size) {
            val id = tag(bytes, offset)
            val size = buffer.getInt(offset + 4)
            if (size < 0) return null
            when (id) {
                "fmt " -> if (offset + 20 <= bytes.size) byteRate = buffer.getInt(offset + 16)
                "data" -> {
                    val rate = byteRate?.takeIf { it > 0 } ?: return null
                    val available = minOf(size, bytes.size - offset - 8)
                    return available.toDouble() / rate * 1000
                }
            }
            // Chunks are padded to an even size.
            offset += 8 + size + (size and 1)
        }
        return null
    }

    private fun tag(bytes: ByteArray, offset: Int) = String(bytes, offset, 4, Charsets.US_ASCII)
}
