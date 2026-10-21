package app.independo.inderun.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File

/**
 * Runs the shared cross-SDK planner vectors (`contracts/fixtures/routing/planner-conformance.json`)
 * through the JNI boundary: each input must plan to exactly the recorded plan, messages included,
 * and the Kotlin plan parser must keep every reason code (it drops codes it does not know) and
 * every candidate's bound voice.
 * `SharedPlannerInputSerializationCoverageTest` covers the other direction, that `toJson` emits
 * every field these inputs use.
 *
 * Robolectric is required because `org.json` is stubbed in plain Android unit tests.
 */
@RunWith(RobolectricTestRunner::class)
class SharedCoreRoutePlannerConformanceTest {
    @Test
    fun `matches the shared planner conformance vectors`() {
        val cases = JSONObject(fixtureFile().readText(Charsets.UTF_8)).getJSONArray("cases")
        assertTrue(cases.length() > 0)

        for (index in 0 until cases.length()) {
            val case = cases.getJSONObject(index)
            val id = case.getString("id")
            val expected = case.getJSONObject("expected")
            val outputJson = SharedCoreRoutePlanner.planRouteJson(case.getJSONObject("input").toString())

            assertEquals(id, normalize(expected), normalize(JSONObject(outputJson)))

            val parsed = parseSharedPlannerRoutePlan(outputJson)
            val expectedCodes = expected.getJSONArray("rejectedProviders").let { rejected ->
                List(rejected.length()) { rejectedIndex ->
                    val reasons = rejected.getJSONObject(rejectedIndex).getJSONArray("reasons")
                    List(reasons.length()) { reasons.getJSONObject(it).getString("code") }
                }
            }
            assertEquals(id, expectedCodes, parsed.rejectedProviders.map { provider -> provider.reasons.map { it.code.rawValue } })
            assertEquals(id, expected.optString("selectedProviderId").ifEmpty { null }, parsed.selectedProviderId)
            val expectedVoices = expected.getJSONArray("candidates").let { candidates ->
                List(candidates.length()) { candidates.getJSONObject(it).optJSONObject("voice")?.let(::normalize) }
            }
            val parsedVoices = parsed.candidates.map { candidate ->
                candidate.voice?.let { voice ->
                    buildMap {
                        put("locale", voice.locale)
                        voice.gender?.let { put("gender", it.rawValue) }
                        voice.networkRequired?.let { put("networkRequired", it) }
                    }.toSortedMap()
                }
            }
            assertEquals(id, expectedVoices, parsedVoices)
        }
    }

    /** Key order is not significant in JSON, so compare sorted structures. */
    private fun normalize(value: Any?): Any? = when (value) {
        is JSONObject -> value.keys().asSequence().sorted().associateWith { normalize(value.get(it)) }
        is JSONArray -> List(value.length()) { normalize(value.get(it)) }
        else -> value
    }

    private fun fixtureFile(): File {
        // The Gradle test working directory is the module directory; walk up to
        // the repository root rather than hard-coding the depth.
        var directory: File? = File("").absoluteFile
        while (directory != null) {
            val candidate = File(directory, "contracts/fixtures/routing/planner-conformance.json")
            if (candidate.isFile) return candidate
            directory = directory.parentFile
        }
        error("Could not locate contracts/fixtures/routing/planner-conformance.json")
    }
}
