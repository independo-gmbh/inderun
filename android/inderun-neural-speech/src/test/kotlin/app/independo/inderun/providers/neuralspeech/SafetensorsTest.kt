package app.independo.inderun.providers.neuralspeech

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Robolectric is required because `org.json` is stubbed in plain Android unit tests. */
@RunWith(RobolectricTestRunner::class)
class SafetensorsTest {
    private fun failure(bytes: ByteArray): NeuralSpeechRuntimeError {
        try {
            Safetensors.parse(bytes)
        } catch (error: NeuralSpeechRuntimeError) {
            return error
        }
        fail("expected parse to throw")
        throw IllegalStateException()
    }

    private fun header(json: String) = json.toByteArray(Charsets.UTF_8)

    private fun assertMalformed(error: NeuralSpeechRuntimeError) {
        assertEquals(NeuralSpeechRuntimeErrorKind.Capability, error.kind)
        assertTrue(error.message, error.message!!.startsWith("voice file malformed: "))
    }

    @Test
    fun roundTripsF32AndI64TensorsAndMetadata() {
        val bytes = encodeSafetensors(
            listOf(
                "a" to SpeechTensor(listOf(2, 3), SpeechTensorData.F32(floatArrayOf(1f, 2f, 3f, 4f, 5f, -6.5f))),
                "b" to SpeechTensor(listOf(2), SpeechTensorData.I64(longArrayOf(7, -8))),
            ),
            mapOf("format" to "test/1"),
        )

        val file = Safetensors.parse(bytes)

        assertEquals(mapOf("format" to "test/1"), file.metadata)
        assertEquals(
            SpeechTensor(listOf(2, 3), SpeechTensorData.F32(floatArrayOf(1f, 2f, 3f, 4f, 5f, -6.5f))),
            file.tensors["a"],
        )
        assertEquals(SpeechTensor(listOf(2), SpeechTensorData.I64(longArrayOf(7, -8))), file.tensors["b"])
    }

    @Test
    fun refusesADtypeOtherThanF32AndI64ByName() {
        val bytes = assembleSafetensors(
            header("""{"w":{"dtype":"F16","shape":[1],"data_offsets":[0,2]}}"""),
            listOf(ByteArray(2)),
        )

        val error = failure(bytes)

        assertEquals(NeuralSpeechRuntimeErrorKind.Capability, error.kind)
        assertEquals("voice file unsupported: dtype F16 of 'w'", error.message)
    }

    @Test
    fun refusesOffsetsBeyondTheBuffer() {
        val bytes = assembleSafetensors(
            header("""{"w":{"dtype":"F32","shape":[2],"data_offsets":[0,8]}}"""),
            listOf(ByteArray(4)),
        )

        assertMalformed(failure(bytes))
    }

    @Test
    fun refusesAByteRangeThatDoesNotMatchTheShape() {
        val bytes = assembleSafetensors(
            header("""{"w":{"dtype":"F32","shape":[3],"data_offsets":[0,8]}}"""),
            listOf(ByteArray(8)),
        )

        assertMalformed(failure(bytes))
    }

    @Test
    fun refusesATensorWithoutShapeOrOffsets() {
        val bytes = assembleSafetensors(header("""{"w":{"dtype":"F32"}}"""), emptyList())

        assertMalformed(failure(bytes))
    }

    @Test
    fun refusesATruncatedOrOversizedOrNonJsonHeader() {
        assertMalformed(failure(ByteArray(4)))
        val oversized = ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN).putLong(1000L).array()
        assertMalformed(failure(oversized))
        val negative = ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN).putLong(-1L).array()
        assertMalformed(failure(negative))
        assertMalformed(failure(assembleSafetensors(header("not json"), emptyList())))
    }

    @Test
    fun parsesAnEmptyTensorFile() {
        val file = Safetensors.parse(assembleSafetensors(header("{}"), emptyList()))

        assertTrue(file.tensors.isEmpty())
        assertNotNull(file.metadata)
    }
}
