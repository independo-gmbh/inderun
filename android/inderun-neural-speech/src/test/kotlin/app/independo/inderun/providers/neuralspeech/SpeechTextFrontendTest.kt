package app.independo.inderun.providers.neuralspeech

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File

/**
 * Runs the shared text frontend vectors (`contracts/fixtures/speech/neural-frontend.json`), which
 * pin the sentence rule and the grapheme tokenizer identically on all three SDKs.
 *
 * Robolectric is required because `org.json` is stubbed in plain Android unit tests.
 */
@RunWith(RobolectricTestRunner::class)
class SpeechTextFrontendTest {
    private fun fixture(): JSONObject {
        // The Gradle test working directory is the module directory; walk up to the
        // repository root rather than hard-coding the depth.
        var directory: File? = File("").absoluteFile
        while (directory != null) {
            val candidate = File(directory, "contracts/fixtures/speech/neural-frontend.json")
            if (candidate.isFile) return JSONObject(candidate.readText(Charsets.UTF_8))
            directory = directory.parentFile
        }
        error("Could not locate contracts/fixtures/speech/neural-frontend.json")
    }

    private fun JSONObject.cases(): List<JSONObject> {
        val cases = getJSONArray("cases")
        return (0 until cases.length()).map { cases.getJSONObject(it) }
    }

    private fun JSONArray.strings(): List<String> = (0 until length()).map { getString(it) }

    private fun JSONArray.ints(): List<Int> = (0 until length()).map { getInt(it) }

    @Test
    fun caseIdsAreUniqueAndNonEmpty() {
        val ids = fixture().cases().map { it.getString("id") }

        assertTrue(ids.isNotEmpty())
        assertTrue(ids.all { it.isNotEmpty() })
        assertEquals(ids.size, ids.toSet().size)
    }

    @Test
    fun splitsAndTokenizesEveryCase() {
        val fixture = fixture()
        val vocabJson = fixture.getJSONObject("vocab")
        val vocab = vocabJson.keys().asSequence().associateWith { vocabJson.getInt(it) }
        val tokenizer = GraphemeTokenizer(vocab)

        for (case in fixture.cases()) {
            val id = case.getString("id")
            val sentences = SpeechTextFrontend.splitSentences(case.getString("text"))
            assertEquals(id, case.getJSONArray("sentences").strings(), sentences)

            val tokens = case.getJSONArray("tokens")
            assertEquals(id, tokens.length(), sentences.size)
            sentences.forEachIndexed { index, sentence ->
                assertEquals("$id[$index]", tokens.getJSONArray(index).ints(), tokenizer.encode(sentence))
            }
        }
    }
}
