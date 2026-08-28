package app.independo.inderun.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File

/**
 * Drives [SseParser] from the shared cross-SDK vectors so the three
 * implementations of the protocol cannot drift apart.
 *
 * Robolectric is required because `org.json` is stubbed in plain Android unit
 * tests.
 */
@RunWith(RobolectricTestRunner::class)
class SseParserConformanceTest {
    private fun fixtureFile(): File {
        // The Gradle test working directory is the module directory; walk up to
        // the repository root rather than hard-coding the depth.
        var directory: File? = File("").absoluteFile
        while (directory != null) {
            val candidate = File(directory, "contracts/fixtures/streaming/sse-framing.json")
            if (candidate.isFile) return candidate
            directory = directory.parentFile
        }
        error("Could not locate contracts/fixtures/streaming/sse-framing.json")
    }

    private fun bytesFromHex(hex: String): ByteArray = ByteArray(hex.length / 2) { index ->
        hex.substring(index * 2, index * 2 + 2).toInt(16).toByte()
    }

    @Test
    fun `matches the shared framing vectors`() {
        val fixture = JSONObject(fixtureFile().readText(Charsets.UTF_8))
        val cases = fixture.getJSONArray("cases")
        assertTrue(cases.length() > 0)

        for (caseIndex in 0 until cases.length()) {
            val framingCase = cases.getJSONObject(caseIndex)
            val label = "${framingCase.getString("name")}: ${framingCase.getString("description")}"

            val parser = SseParser()
            val received = mutableListOf<SseEvent>()
            val chunks = framingCase.getJSONArray("chunksHex")
            for (chunkIndex in 0 until chunks.length()) {
                received += parser.consume(bytesFromHex(chunks.getString(chunkIndex)))
            }
            received += parser.finish()

            val expectedJson = framingCase.getJSONArray("expected")
            val expected = (0 until expectedJson.length()).map { index ->
                val entry = expectedJson.getJSONObject(index)
                SseEvent(
                    event = if (entry.has("event")) entry.getString("event") else null,
                    data = entry.getString("data"),
                    id = if (entry.has("id")) entry.getString("id") else null,
                )
            }

            assertEquals(label, expected, received)
        }
    }

    @Test
    fun `is unaffected by how the byte stream is chunked`() {
        val raw = "event: a\ndata: one\n\ndata: two\n\n".toByteArray(Charsets.UTF_8)
        val parser = SseParser()
        val received = mutableListOf<SseEvent>()
        for (byte in raw) {
            received += parser.consume(byteArrayOf(byte))
        }
        received += parser.finish()

        assertEquals(
            listOf(SseEvent(event = "a", data = "one"), SseEvent(data = "two")),
            received,
        )
    }
}
