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
 * Runs the shared German text frontend vectors (`contracts/fixtures/speech/german-frontend.json`)
 * through the Rust route core's JNI export, the same function the Web (WASM) and Swift (FFI)
 * conformance tests exercise. Robolectric is required because `org.json` is stubbed in plain
 * Android unit tests.
 */
@RunWith(RobolectricTestRunner::class)
class GermanFrontendConformanceTest {
    private fun cases(): JSONArray {
        var directory: File? = File("").absoluteFile
        while (directory != null) {
            val candidate = File(directory, "contracts/fixtures/speech/german-frontend.json")
            if (candidate.isFile) return JSONObject(candidate.readText(Charsets.UTF_8)).getJSONArray("cases")
            directory = directory.parentFile
        }
        error("Could not locate contracts/fixtures/speech/german-frontend.json")
    }

    @Test
    fun normalizesEveryCase() {
        val cases = cases()
        assertEquals("fixture case count", 82, cases.length())

        var checked = 0
        for (index in 0 until cases.length()) {
            val case = cases.getJSONObject(index)
            val id = case.getString("id")
            assertEquals(id, case.getString("expected"), SharedCoreSpeechText.normalize(case.getString("input"), case.getString("locale")))
            checked += 1
        }
        assertEquals(cases.length(), checked)
    }

    @Test
    fun leavesOtherLanguagesUntouched() {
        assertTrue(SharedCoreSpeechText.normalize("Meet at 14:30, e.g. 3.", "en-US") == "Meet at 14:30, e.g. 3.")
    }
}
