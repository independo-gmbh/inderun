package app.independo.inderun.providers.onnx

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.security.MessageDigest

class SystemAndroidOnnxGenAiRuntimeTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    @Test
    fun verifyChecksumAcceptsMatchingSha256() {
        val file = tempFolder.newFile("model.onnx").apply { writeBytes("hello".toByteArray()) }
        val expected = "sha256:" + sha256Hex("hello".toByteArray())

        verifyChecksum(file, "model.onnx", expected)
    }

    @Test
    fun verifyChecksumRejectsMismatchedSha256() {
        val file = tempFolder.newFile("model.onnx").apply { writeBytes("hello".toByteArray()) }

        try {
            verifyChecksum(file, "model.onnx", "sha256:0000000000000000000000000000000000000000000000000000000000000000")
            fail("Expected a checksum mismatch to throw.")
        } catch (error: OnnxRuntimeError) {
            assertEquals(OnnxRuntimeErrorKind.CAPABILITY, error.kind)
        }
    }

    @Test
    fun verifyChecksumRejectsUnsupportedAlgorithmInsteadOfSkipping() {
        val file = tempFolder.newFile("model.onnx").apply { writeBytes("hello".toByteArray()) }

        try {
            verifyChecksum(file, "model.onnx", "md5:5d41402abc4b2a76b9719d911017c592")
            fail("Expected an unsupported checksum algorithm to be a capability failure, not a no-op.")
        } catch (error: OnnxRuntimeError) {
            assertEquals(OnnxRuntimeErrorKind.CAPABILITY, error.kind)
        }
    }

    @Test
    fun parseEosTokenIdReadsPlainIntegerField() {
        val eosTokenId = parseEosTokenId("""{"eos_token_id": 2}""")

        assertEquals(2L, eosTokenId)
    }

    @Test
    fun parseEosTokenIdReadsFirstEntryOfArrayField() {
        val eosTokenId = parseEosTokenId("""{"eos_token_id": [2, 32000]}""")

        assertEquals(2L, eosTokenId)
    }

    @Test
    fun parseEosTokenIdReturnsNullWhenFieldAbsent() {
        val eosTokenId = parseEosTokenId("""{"vocab_size": 32001}""")

        assertNull(eosTokenId)
    }

    @Test
    fun cacheKeyDigestDiffersForDifferentCacheKeys() {
        val first = cacheKeyDigest("phi-3|onnx|1.0.0|bundled|models/phi-3|")
        val second = cacheKeyDigest("phi-3|onnx|2.0.0|bundled|models/phi-3|")

        assertNotEquals(first, second)
    }

    @Test
    fun cacheKeyDigestIsStableForTheSameCacheKey() {
        val key = "phi-3|onnx|1.0.0|bundled|models/phi-3|"

        assertEquals(cacheKeyDigest(key), cacheKeyDigest(key))
    }

    @Test
    fun isEosTokenMatchesConfiguredEosId() {
        assertEquals(true, isEosToken(tokenId = 2L, eosTokenId = 2L))
        assertEquals(false, isEosToken(tokenId = 2L, eosTokenId = 3L))
        assertEquals(false, isEosToken(tokenId = 2L, eosTokenId = null))
    }

    @Test
    fun matchStopSequenceFindsASuffixMatch() {
        val stop = matchStopSequence("The answer is 42.\n", stopSequences = listOf("\n", "STOP"))

        assertEquals("\n", stop)
    }

    @Test
    fun matchStopSequenceReturnsNullWhenNoneMatch() {
        val stop = matchStopSequence("still generating", stopSequences = listOf("\n", "STOP"))

        assertNull(stop)
    }

    private fun sha256Hex(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString(separator = "") { "%02x".format(it) }
}
