package app.independo.inderun.core

import android.media.AudioTrack
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.shadows.ShadowAudioTrack

/**
 * What `drain()` does with the playback head, on an [AudioTrack] whose head the test moves. The
 * head cannot be driven on the JVM otherwise, and a stalled head cannot be produced on demand on
 * a device.
 */
@RunWith(RobolectricTestRunner::class)
@Config(shadows = [HeadControlledAudioTrack::class])
class AudioTrackAudioOutputDrainTest {
    private val format = AudioOutputFormat(sampleRate = 24_000)

    @After
    fun resetHead() = HeadControlledAudioTrack.reset()

    @Test
    fun drainReturnsOnceTheHeadReachesTheLastFrameWritten() = runTest {
        HeadControlledAudioTrack.headPositions = ArrayDeque(listOf(0, 12_000, 24_000))
        val session = AudioTrackAudioOutputService(StandardTestDispatcher(testScheduler)).open(format)
        session.write(ShortArray(24_000))
        session.drain()
        session.stop()
        assertTrue("drain() returned before the head reached the last frame", HeadControlledAudioTrack.headPositions.isEmpty())
    }

    @Test
    fun drainFailsRatherThanReturningWhenTheHeadStallsShortOfTheLastFrame() = runTest {
        // Moves, then stalls within one buffer of the end: the last 100 frames never play.
        HeadControlledAudioTrack.headPositions = ArrayDeque(listOf(1_000, 23_900))
        val session = AudioTrackAudioOutputService(StandardTestDispatcher(testScheduler)).open(format)
        session.write(ShortArray(24_000))
        val outcome = runCatching { session.drain() }
        session.stop()
        assertTrue("drain() returned as if everything had played", outcome.isFailure)
        val error = outcome.exceptionOrNull() as? IndeRunException
        assertEquals("audio_output_failed", error?.details?.get("code"))
    }
}

/**
 * An [AudioTrack] whose playback head the test scripts: each `getPlaybackHeadPosition()` call
 * takes the next value of [headPositions] and the last value repeats, so a head that reaches a
 * value and stays there is a stall. Every write is accepted whole.
 */
@Implements(AudioTrack::class)
class HeadControlledAudioTrack : ShadowAudioTrack() {
    @Implementation
    protected fun write(audioData: ShortArray, offsetInShorts: Int, sizeInShorts: Int, writeMode: Int): Int = sizeInShorts

    @Implementation
    override fun getPlaybackHeadPosition(): Int {
        headPositions.removeFirstOrNull()?.let { lastHead = it }
        return lastHead
    }

    companion object {
        var headPositions: ArrayDeque<Int> = ArrayDeque()
        private var lastHead = 0

        fun reset() {
            headPositions = ArrayDeque()
            lastHead = 0
        }
    }
}
