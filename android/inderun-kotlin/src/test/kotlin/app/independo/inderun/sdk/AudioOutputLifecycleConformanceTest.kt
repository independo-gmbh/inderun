package app.independo.inderun.sdk

import app.independo.inderun.core.AudioOutputFormat
import app.independo.inderun.core.createUnavailable
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File

/**
 * The JVM half of the cross-SDK audio output catalog
 * (`contracts/fixtures/host/audio-output-lifecycle.json`, ADR 021), run against the fixture
 * service. The handlers live in `src/sharedTest` so the instrumented run reuses them against the
 * real `AudioTrack` service. The guard test fails when the handler ids and the catalog ids differ.
 *
 * Robolectric is required because `org.json` is stubbed in plain Android unit tests.
 */
@RunWith(RobolectricTestRunner::class)
class AudioOutputLifecycleConformanceTest {
    private fun catalogJson(): String {
        // The Gradle test working directory is the module directory; walk up to the
        // repository root rather than hard-coding the depth.
        var directory: File? = File("").absoluteFile
        while (directory != null) {
            val candidate = File(directory, "contracts/fixtures/host/audio-output-lifecycle.json")
            if (candidate.isFile) return candidate.readText(Charsets.UTF_8)
            directory = directory.parentFile
        }
        error("Could not locate contracts/fixtures/host/audio-output-lifecycle.json")
    }

    @Test
    fun implementsEveryCaseInTheSharedCatalogAndNoOthers() {
        val catalogIds = audioOutputCatalogCases(catalogJson()).map { it.getString("id") }.sorted()
        assertTrue(catalogIds.isNotEmpty())
        assertEquals(catalogIds.toSet().size, catalogIds.size)
        assertEquals(catalogIds, audioOutputHandlers.keys.sorted())
    }

    @Test
    fun fixtureMatchesTheSharedCatalog() = runTest {
        val fixture = FixtureAudioOutputService()
        val stalledFixture = FixtureAudioOutputService(stallsDrain = true)
        val failures = runAudioOutputCatalog(
            catalogJson(),
            AudioOutputTarget(fixture, { fixture.now() }, AudioOutputTarget(stalledFixture, { stalledFixture.now() })),
        )
        assertTrue("Conformance failures:\n${failures.joinToString("\n")}", failures.isEmpty())
    }

    @Test
    fun stopDiscardsTheBufferedAudioInsteadOfPlayingIt() = runTest {
        // Run the case on a fresh fixture so the counter is attributable to it.
        val fixture = FixtureAudioOutputService()
        val failures = runAudioOutputCatalog(
            catalogJson(),
            AudioOutputTarget(fixture, { fixture.now() }),
            setOf("stop_discards_buffered_audio"),
        )
        assertTrue("Conformance failures:\n${failures.joinToString("\n")}", failures.isEmpty())
        // 3000 ms at 24000 Hz.
        assertEquals(72000L, fixture.sessions.single().discardedFrames)
    }

    /**
     * The fixture's two endings, which PR 3's provider tests rely on: after `interrupt` a write
     * and a drain throw its error; after `stop()` they return without effect.
     */
    @Test
    fun fixtureWriteAfterInterruptThrowsAndAfterStopReturns() = runTest {
        val format = AudioOutputFormat(sampleRate = 24000)
        val interrupting = FixtureAudioOutputService()
        val interrupted = interrupting.open(format)
        interrupted.write(ShortArray(4800))
        val error = createUnavailable(
            "Audio output was interrupted by the system.",
            details = mapOf("code" to "audio_output_interrupted"),
        )
        interrupting.sessions.single().interrupt(error)
        assertEquals(error, runCatching { interrupted.write(ShortArray(4800)) }.exceptionOrNull())
        assertEquals(error, runCatching { interrupted.drain() }.exceptionOrNull())
        assertEquals(4800L, interrupting.sessions.single().writtenFrames)
        assertEquals(4800L, interrupting.sessions.single().discardedFrames)

        val stopping = FixtureAudioOutputService()
        val stopped = stopping.open(format)
        stopped.stop()
        stopped.write(ShortArray(4800))
        stopped.drain()
        assertEquals(0L, stopping.sessions.single().writtenFrames)
    }
}
