package app.independo.inderun.core

import app.independo.inderun.contracts.SpeechControlState
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
                        voice.id?.let { put("id", it) }
                        voice.name?.let { put("name", it) }
                        put("locale", voice.locale)
                        voice.locales?.let { put("locales", it) }
                        voice.gender?.let { put("gender", it.rawValue) }
                        voice.networkRequired?.let { put("networkRequired", it) }
                        voice.readiness?.let { put("readiness", it.rawValue) }
                        voice.controlStates?.let { states -> put("controlStates", states.map(::controlStateMap)) }
                    }.toSortedMap()
                }
            }
            assertEquals(id, expectedVoices, parsedVoices)

            // Every candidate's control application plan, field by field. org.json may parse a
            // whole number as an Integer, so numbers are compared as Doubles on both sides.
            val expectedControls = expected.getJSONArray("candidates").let { candidates ->
                List(candidates.length()) { candidates.getJSONObject(it).optJSONArray("controls")?.let(::numbersAsDoubles) }
            }
            val parsedControls = parsed.candidates.map { candidate ->
                candidate.controls?.map { plan ->
                    buildMap<String, Any> {
                        put("decision", plan.decision.rawValue)
                        put("id", plan.id.rawValue)
                        plan.reason?.let { put("reason", it.rawValue) }
                        put("requirement", plan.requirement.rawValue)
                        put("value", plan.value)
                    }.toSortedMap()
                }
            }
            assertEquals(id, expectedControls, parsedControls)
        }
    }

    /** A parsed voice control override in the fixture's JSON shape, for comparing bound voices. */
    private fun controlStateMap(state: SpeechControlState): Map<String, Any> = buildMap<String, Any> {
        state.available?.let { put("available", it) }
        put("delivery", state.delivery.rawValue)
        put("id", state.id.rawValue)
        state.range?.let { range ->
            put(
                "range",
                buildMap<String, Any> {
                    range.default?.let { put("default", it) }
                    put("max", range.max)
                    put("min", range.min)
                    range.step?.let { put("step", it) }
                }.toSortedMap(),
            )
        }
        state.reason?.let { put("reason", it) }
    }.toSortedMap()

    /** [normalize] with every number as a Double. */
    private fun numbersAsDoubles(value: Any?): Any? = toDoubles(normalize(value))

    private fun toDoubles(value: Any?): Any? = when (value) {
        is Number -> value.toDouble()
        is Map<*, *> -> value.mapValues { toDoubles(it.value) }.toSortedMap(compareBy { it as String })
        is List<*> -> value.map(::toDoubles)
        else -> value
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
