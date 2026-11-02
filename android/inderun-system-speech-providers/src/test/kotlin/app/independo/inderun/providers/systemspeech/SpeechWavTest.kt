package app.independo.inderun.providers.systemspeech

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

internal fun wavBytes(dataBytes: Int = 2200, byteRate: Int = 22_000, extraChunk: Int = 0): ByteArray {
    val extra = if (extraChunk > 0) 8 + extraChunk + (extraChunk and 1) else 0
    val buffer = ByteBuffer.allocate(44 + extra + dataBytes).order(ByteOrder.LITTLE_ENDIAN)
    buffer.put("RIFF".toByteArray()).putInt(36 + extra + dataBytes).put("WAVE".toByteArray())
    buffer.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(1).putInt(byteRate / 2).putInt(byteRate)
    buffer.putShort(2).putShort(16)
    if (extraChunk > 0) {
        buffer.put("LIST".toByteArray()).putInt(extraChunk).put(ByteArray(extraChunk + (extraChunk and 1)))
    }
    buffer.put("data".toByteArray()).putInt(dataBytes).put(ByteArray(dataBytes))
    return buffer.array()
}

class SpeechWavTest {
    @Test
    fun measuresACanonicalFile() {
        assertEquals(100.0, SpeechWav.durationMs(wavBytes())!!, 0.001)
    }

    @Test
    fun skipsChunksAheadOfTheData() {
        assertEquals(100.0, SpeechWav.durationMs(wavBytes(extraChunk = 7))!!, 0.001)
    }

    @Test
    fun trustsTheBytesPresentOverTheDeclaredSize() {
        val truncated = wavBytes().copyOf(44 + 1100)

        assertEquals(50.0, SpeechWav.durationMs(truncated)!!, 0.001)
    }

    @Test
    fun refusesWhatIsNotWav() {
        assertNull(SpeechWav.durationMs(ByteArray(64)))
        assertNull(SpeechWav.durationMs("RIFF".toByteArray()))
        assertNull(SpeechWav.durationMs(wavBytes(byteRate = 0)))
    }
}
