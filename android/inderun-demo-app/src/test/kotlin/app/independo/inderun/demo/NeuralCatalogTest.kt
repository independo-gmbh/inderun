package app.independo.inderun.demo

import app.independo.inderun.contracts.ModelPackage
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File

/** Runs the shared catalog-to-package fixture against the demo's own mapping; Robolectric because `org.json` is stubbed otherwise. */
@RunWith(RobolectricTestRunner::class)
class NeuralCatalogTest {
    private fun speechFixture(name: String): String {
        var directory: File? = File("").absoluteFile
        while (directory != null) {
            val candidate = File(directory, "contracts/fixtures/speech/$name")
            if (candidate.isFile) return candidate.readText(Charsets.UTF_8)
            directory = directory.parentFile
        }
        error("Could not locate contracts/fixtures/speech/$name")
    }

    private fun JSONArray.objects() = (0 until length()).map { getJSONObject(it) }

    private fun JSONArray.strings() = (0 until length()).map { getString(it) }

    @Test
    fun everyMappingFixtureCaseProducesTheExpectedPackage() {
        val cases = JSONObject(speechFixture("catalog-to-package.json")).getJSONArray("cases").objects()
        assertTrue(cases.size >= 2)
        for (case in cases) {
            val entry = NeuralCatalogParser.parse("""{"entries":[${case.getJSONObject("entry")}]}""").single()
            val produced = catalogEntryToModelPackage(entry, case.getString("ref"))
            assertPackage(case.getString("id"), case.getJSONObject("expected"), produced)
        }
    }

    // The contract's License has spdx and url only, so restrictions and attribution are compared at the catalog level.
    private fun assertPackage(id: String, expected: JSONObject, actual: ModelPackage) {
        assertEquals(id, expected.getString("id"), actual.id)
        assertEquals(id, expected.getString("version"), actual.version)
        assertEquals(id, expected.getString("format"), actual.format.rawValue)
        assertEquals(id, expected.getString("variant"), actual.variant)
        assertEquals(id, expected.getJSONArray("tasks").strings(), actual.tasks)
        assertEquals(id, expected.getJSONObject("license").getString("spdx"), actual.license?.spdx)
        assertEquals(id, expected.getJSONObject("license").getString("url"), actual.license?.url)
        val runtime = expected.optJSONObject("runtime")
        assertEquals(id, runtime?.getString("minOsVersion"), actual.runtime?.minOsVersion)
        if (runtime == null) assertNull(actual.runtime)
        assertEquals(id, "app_managed", actual.source?.sourceType?.rawValue)
        assertEquals(id, expected.getJSONObject("source").getString("ref"), actual.source?.ref)
        assertNull(id, actual.limits)
        assertNull(id, actual.files)

        val checksums = expected.getJSONObject("integrity").getJSONObject("checksums")
        assertEquals(id, checksums.keys().asSequence().associateWith { checksums.getString(it) }, actual.integrity?.checksums)

        val speech = expected.getJSONObject("speech")
        val got = actual.speech!!
        assertEquals(id, speech.getString("pipeline"), got.pipeline)
        assertEquals(id, speech.getLong("sampleRate"), got.sampleRate)
        assertEquals(id, speech.getLong("channels"), got.channels)
        val graphs = speech.getJSONObject("graphs")
        assertEquals(id, graphs.keys().asSequence().associateWith { graphs.getString(it) }, got.graphs)
        assertEquals(id, speech.getJSONObject("frontend").getString("kind"), got.frontend?.kind?.rawValue)
        val assets = speech.getJSONObject("frontend").getJSONObject("assets")
        assertEquals(id, assets.keys().asSequence().associateWith { assets.getString(it) }, got.frontend?.assets)
        val voices = speech.getJSONArray("voices").objects()
        assertEquals(id, voices.size, got.voices.size)
        voices.zip(got.voices).forEach { (want, have) ->
            assertEquals(id, want.getString("id"), have.id)
            assertEquals(id, want.getString("name"), have.name)
            assertEquals(id, want.getJSONArray("locales").strings(), have.locales)
            assertEquals(id, want.optString("gender").ifEmpty { null }, have.gender?.rawValue)
            assertEquals(id, want.getString("file"), have.file)
            assertEquals(id, want.getJSONObject("license").getString("spdx"), have.license?.spdx)
            assertEquals(id, want.getJSONObject("license").optString("url").ifEmpty { null }, have.license?.url)
        }
    }

    @Test
    fun theCommittedCatalogParsesAndCoreAiIsNotInstallable() {
        val entries = NeuralCatalogParser.parse(speechFixture("neural-model-catalog.json"))
        val onnx = entries.single { it.id == "articulino-de-en-int8" }
        assertTrue(onnx.isInstallable)
        assertEquals("voices-lab/articulino-de-en-int8/1", onnx.ref)
        assertEquals(4 + 7, onnx.allFiles.size)
        val coreAi = entries.single { it.id == "articulino-de-en-coreai" }
        assertTrue(coreAi.files.isNotEmpty())
        assertFalse(coreAi.isInstallable)
        assertEquals("the coreai runtime is not available on Android", coreAi.unavailableReason)
    }

    @Test
    fun theProfileIsNeuralThenAndroidSystemSpeech() {
        assertEquals(
            mapOf("voices-lab:articulino-de-en-int8" to listOf("local.onnx.speech.android:articulino-de-en-int8", "android_system_speech")),
            voicesLabProfiles(listOf("articulino-de-en-int8")),
        )
    }
}
