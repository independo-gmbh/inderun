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
 * Runs the shared speech text frontend vectors (`contracts/fixtures/speech/german-frontend.json` and
 * `english-frontend.json`) through the Rust route core's JNI export, the same function the Web
 * (WASM) and Swift (FFI) conformance tests exercise. Robolectric is required because `org.json` is
 * stubbed in plain Android unit tests.
 */
@RunWith(RobolectricTestRunner::class)
class SpeechTextFrontendConformanceTest {
    private fun cases(name: String): JSONArray {
        var directory: File? = File("").absoluteFile
        while (directory != null) {
            val candidate = File(directory, "contracts/fixtures/speech/$name")
            if (candidate.isFile) return JSONObject(candidate.readText(Charsets.UTF_8)).getJSONArray("cases")
            directory = directory.parentFile
        }
        error("Could not locate contracts/fixtures/speech/$name")
    }

    @Test
    fun normalizesEveryCase() {
        // Each fixture with its case count, which guards against a fixture that lost cases.
        for ((name, expectedCount) in listOf("german-frontend.json" to 88, "english-frontend.json" to 37)) {
            val cases = cases(name)
            assertEquals("$name case count", expectedCount, cases.length())

            val ids = mutableSetOf<String>()
            for (index in 0 until cases.length()) {
                val case = cases.getJSONObject(index)
                val id = case.getString("id")
                assertTrue("$name: duplicate id $id", ids.add(id))
                assertEquals(
                    "$name $id",
                    case.getString("expected"),
                    SharedCoreSpeechText.normalize(case.getString("input"), case.getString("locale")),
                )
            }
            assertEquals(cases.length(), ids.size)
        }
    }

    @Test
    fun leavesOtherLanguagesUntouched() {
        assertTrue(SharedCoreSpeechText.normalize("Rendez-vous à 14:30, p. ex. 3.", "fr") == "Rendez-vous à 14:30, p. ex. 3.")
    }
}
