package app.independo.inderun.sdk

import android.content.Context
import android.os.SystemClock
import android.util.Log
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import app.independo.inderun.core.AudioOutputFormat
import app.independo.inderun.core.AudioTrackAudioOutputService
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The shared audio output catalog (`contracts/fixtures/host/audio-output-lifecycle.json`, ADR 021)
 * against the real `AudioTrack` default. The stop and refusal cases do not depend on the playback
 * head and run everywhere; the cases that wait for audio to play skip when a probe shows the head
 * does not advance (the CI emulator runs with `-noaudio`). Every wait is bounded, so a silent
 * audio HAL fails or skips a case rather than hanging the run. Failures and the probe outcome are
 * logged under the `IndeRunAudioOutput` tag.
 *
 * Run with `./gradlew :inderun-kotlin:connectedAndroidTest` against an emulator or device.
 */
@RunWith(AndroidJUnit4::class)
class AudioTrackAudioOutputConformanceTest {
    private val context: Context = ApplicationProvider.getApplicationContext()

    private fun catalogJson() = context.assets.open("audio-output-lifecycle.json").bufferedReader().use { it.readText() }

    private fun target() = AudioOutputTarget(AudioTrackAudioOutputService(), { SystemClock.elapsedRealtime().toDouble() })

    private val headIndependent = setOf(
        "unsupported_format_refused",
        "open_makes_no_sound",
        "stop_is_idempotent",
        "write_after_stop_is_ignored",
        "drain_after_stop_resolves_at_once",
        "stop_discards_buffered_audio",
    )

    /** Needs an output that stops rendering on demand, which a device cannot do; the JVM run and the drain unit tests cover it. */
    private val stallOnly = setOf("drain_fails_when_output_stalls")
    private val playback = setOf("first_write_starts_playback", "drain_waits_for_everything_written", "sessions_are_independent")

    @Test
    fun implementsEveryCaseInTheSharedCatalogAndNoOthers() {
        val ids = audioOutputCatalogCases(catalogJson()).map { it.getString("id") }.sorted()
        assertEquals(ids, audioOutputHandlers.keys.sorted())
        assertEquals(ids, (headIndependent + playback + stallOnly).sorted())
    }

    @Test
    fun headIndependentCasesMatchTheSharedCatalog() = runBlocking {
        val failures = runAudioOutputCatalog(catalogJson(), target(), headIndependent)
        failures.forEach { Log.w(TAG, it) }
        assertTrue("Conformance failures:\n${failures.joinToString("\n")}", failures.isEmpty())
    }

    @Test
    fun playbackCasesMatchTheSharedCatalogWhenTheDeviceRendersAudio() = runBlocking {
        assumeTrue("AudioTrack's playback head does not advance on this device (emulator -noaudio?)", probeRenders())
        val failures = runAudioOutputCatalog(catalogJson(), target(), playback)
        failures.forEach { Log.w(TAG, it) }
        assertTrue("Conformance failures:\n${failures.joinToString("\n")}", failures.isEmpty())
    }

    /**
     * Opens a session, writes 200 ms of silence and waits up to 2 s for the first frame to leave the
     * output. The whole probe is bounded: a watchdog stops the session at the deadline, which also
     * returns a write the server never accepted, and a probe that times out counts as not rendering.
     */
    private suspend fun probeRenders(): Boolean {
        val session = AudioTrackAudioOutputService().open(AudioOutputFormat(sampleRate = PROBE_SAMPLE_RATE))
        try {
            val firstAudioMs = coroutineScope {
                val watchdog = launch {
                    delay(PROBE_TIMEOUT_MS)
                    session.stop()
                }
                val observed = withTimeoutOrNull(PROBE_TIMEOUT_MS) {
                    session.write(ShortArray(PROBE_SAMPLE_RATE / 5))
                    val deadline = SystemClock.elapsedRealtime() + PROBE_WAIT_MS
                    while (session.firstAudioMs() == null && SystemClock.elapsedRealtime() < deadline) delay(10)
                    session.firstAudioMs()
                }
                watchdog.cancel()
                observed
            }
            Log.i(TAG, "probe: firstAudioMs=$firstAudioMs (playback cases ${if (firstAudioMs != null) "run" else "skip"})")
            return firstAudioMs != null
        } finally {
            session.stop()
        }
    }

    private companion object {
        const val TAG = "IndeRunAudioOutput"
        const val PROBE_SAMPLE_RATE = 24_000
        const val PROBE_WAIT_MS = 2_000L
        const val PROBE_TIMEOUT_MS = 3_000L
    }
}
