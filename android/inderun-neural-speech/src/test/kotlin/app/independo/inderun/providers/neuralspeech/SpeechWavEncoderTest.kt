package app.independo.inderun.providers.neuralspeech

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class SpeechWavEncoderTest {
    @Test
    fun writesACanonicalMono16BitHeaderFollowedByLittleEndianSamples() {
        val bytes = SpeechWavEncoder.encode(shortArrayOf(0, 1, -1), 24000)
        val view = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        fun ascii(at: Int) = String(bytes, at, 4, Charsets.US_ASCII)

        assertEquals(44, SpeechWavEncoder.HEADER_BYTES)
        assertEquals(50, bytes.size)
        assertEquals("RIFF", ascii(0))
        assertEquals(42, view.getInt(4))
        assertEquals("WAVE", ascii(8))
        assertEquals("fmt ", ascii(12))
        assertEquals(16, view.getInt(16))
        assertEquals(1, view.getShort(20).toInt())
        assertEquals(1, view.getShort(22).toInt())
        assertEquals(24000, view.getInt(24))
        assertEquals(48000, view.getInt(28))
        assertEquals(2, view.getShort(32).toInt())
        assertEquals(16, view.getShort(34).toInt())
        assertEquals("data", ascii(36))
        assertEquals(6, view.getInt(40))
        assertArrayEquals(byteArrayOf(0x00, 0x00, 0x01, 0x00, 0xff.toByte(), 0xff.toByte()), bytes.copyOfRange(44, 50))
    }
}
