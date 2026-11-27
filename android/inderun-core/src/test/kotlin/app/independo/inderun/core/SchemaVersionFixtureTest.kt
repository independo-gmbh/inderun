package app.independo.inderun.core

import app.independo.inderun.contracts.SchemaVersion
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File

/**
 * ADR 025 section 5: every run-scoped document carries exactly one schema version. The Kotlin
 * contracts have no JSON decoder, so a payload can only carry a version [SchemaVersion] can
 * represent; this test holds that enum to the shared fixture the Web and Swift suites decode.
 *
 * Robolectric is required because `org.json` is stubbed in plain Android unit tests.
 */
@RunWith(RobolectricTestRunner::class)
class SchemaVersionFixtureTest {
    @Test
    fun `only the accepted versions are representable`() {
        val fixture = JSONObject(fixtureFile().readText(Charsets.UTF_8))
        val accepted = fixture.getJSONArray("accepted").let { array -> List(array.length()) { array.getString(it) } }
        val rejected = fixture.getJSONArray("rejected").let { array -> List(array.length()) { array.getString(it) } }

        assertEquals(accepted, SchemaVersion.entries.map { it.rawValue })
        for (version in rejected) {
            assertNull(version, SchemaVersion.fromRawValue(version))
        }
        val documents = fixture.getJSONArray("documents")
        for (index in 0 until documents.length()) {
            val payload = documents.getJSONObject(index).getJSONObject("payload")
            assertEquals(SchemaVersion.V1_1, SchemaVersion.fromRawValue(payload.getString("schemaVersion")))
        }
    }

    private fun fixtureFile(): File {
        var directory: File? = File("").absoluteFile
        while (directory != null) {
            val candidate = File(directory, "contracts/fixtures/versioning/schema-versions.json")
            if (candidate.isFile) return candidate
            directory = directory.parentFile
        }
        error("contracts/fixtures/versioning/schema-versions.json not found above ${File("").absolutePath}")
    }
}
