package app.independo.inderun.providers.neuralspeech

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Encodes mono 16-bit PCM as a canonical little-endian WAV file. */
object SpeechWavEncoder {
    /** Size of the canonical header [encode] writes. */
    const val HEADER_BYTES = 44

    fun encode(samples: ShortArray, sampleRate: Int): ByteArray {
        val dataBytes = samples.size * 2
        val buffer = ByteBuffer.allocate(HEADER_BYTES + dataBytes).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put("RIFF".toByteArray(Charsets.US_ASCII)).putInt(36 + dataBytes)
        buffer.put("WAVE".toByteArray(Charsets.US_ASCII))
        buffer.put("fmt ".toByteArray(Charsets.US_ASCII)).putInt(16)
        buffer.putShort(1) // PCM
        buffer.putShort(1) // mono
        buffer.putInt(sampleRate)
        buffer.putInt(sampleRate * 2) // byte rate
        buffer.putShort(2) // block align
        buffer.putShort(16) // bits per sample
        buffer.put("data".toByteArray(Charsets.US_ASCII)).putInt(dataBytes)
        buffer.asShortBuffer().put(samples)
        return buffer.array()
    }
}
