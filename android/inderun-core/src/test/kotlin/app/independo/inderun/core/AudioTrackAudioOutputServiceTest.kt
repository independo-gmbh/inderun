package app.independo.inderun.core

import androidx.test.core.app.ApplicationProvider
import app.independo.inderun.contracts.IndeRunErrorClass
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The JVM side of the `AudioTrack` default: the factory wiring and the format rule, which runs
 * before any `AudioTrack` is touched. The playback behaviour runs against a real device in
 * `AudioTrackAudioOutputConformanceTest` (`inderun-kotlin`'s instrumented tests).
 */
@RunWith(RobolectricTestRunner::class)
class AudioTrackAudioOutputServiceTest {
    @Test
    fun factoryProvidesAudioOutput() {
        val host = HostServicesFactory.create(ApplicationProvider.getApplicationContext())
        assertTrue(host.audioOutput is AudioTrackAudioOutputService)
    }

    @Test
    fun openRefusesAnUnsupportedFormatBeforeTouchingAudioTrack() = runTest {
        val error = runCatching { AudioTrackAudioOutputService().open(AudioOutputFormat(sampleRate = 4000)) }
            .exceptionOrNull() as? IndeRunException ?: throw AssertionError("expected an IndeRunException")
        assertEquals(IndeRunErrorClass.CapabilityMismatch, error.errorClass)
        assertEquals("audio_format_unsupported", error.details?.get("code"))
    }

    @Test
    fun openHonoursCancellationBeforeBuildingATrack() = runTest {
        val service = AudioTrackAudioOutputService(StandardTestDispatcher(testScheduler))
        var outcome: Any? = null
        launch {
            cancel()
            outcome = runCatching { service.open(AudioOutputFormat(sampleRate = 24000)) }
                .fold(onSuccess = {
                    it.stop()
                    "returned a session"
                }, onFailure = { it })
        }.join()
        assertTrue("open() did not honour cancellation: $outcome", outcome is CancellationException)
    }
}
