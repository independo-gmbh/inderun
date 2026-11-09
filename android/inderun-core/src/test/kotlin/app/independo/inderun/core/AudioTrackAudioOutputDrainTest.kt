package app.independo.inderun.core

import android.media.AudioTrack
import app.independo.inderun.contracts.IndeRunErrorClass
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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

    @Test
    fun drainBoundCountsOnlyUnplayedAudio() = runTest {
        // One second written; the head reaches half of it and stalls. The bound is the 500 ms
        // still unplayed plus the grace, not the full second.
        HeadControlledAudioTrack.headPositions = ArrayDeque(listOf(12_000))
        val session = AudioTrackAudioOutputService(StandardTestDispatcher(testScheduler)).open(format)
        session.write(ShortArray(24_000))
        val from = testScheduler.currentTime
        val error = runCatching { session.drain() }.exceptionOrNull() as? IndeRunException
        val elapsed = testScheduler.currentTime - from
        assertEquals("audio_output_failed", error?.details?.get("code"))
        assertEquals(IndeRunErrorClass.Unavailable, error?.errorClass)
        assertEquals(500L + 2_000L, elapsed)
    }

    @Test
    fun drainBoundsAreInjectable() = runTest {
        HeadControlledAudioTrack.headPositions = ArrayDeque(listOf(12_000))
        val service = AudioTrackAudioOutputService(StandardTestDispatcher(testScheduler), drainGraceMs = 300L, drainPollMs = 50L)
        val session = service.open(format)
        session.write(ShortArray(24_000))
        val from = testScheduler.currentTime
        val error = runCatching { session.drain() }.exceptionOrNull() as? IndeRunException
        assertEquals("audio_output_failed", error?.details?.get("code"))
        assertEquals(500L + 300L, testScheduler.currentTime - from)
    }

    @Test
    fun theSessionEndsWhenTheDrainExpires() = runTest {
        HeadControlledAudioTrack.headPositions = ArrayDeque(listOf(0))
        val session = AudioTrackAudioOutputService(StandardTestDispatcher(testScheduler)).open(format)
        session.write(ShortArray(2_400))
        assertEquals("audio_output_failed", (runCatching { session.drain() }.exceptionOrNull() as? IndeRunException)?.details?.get("code"))
        val writesAtExpiry = HeadControlledAudioTrack.writeCalls
        val expiredAt = testScheduler.currentTime
        session.write(ShortArray(2_400))
        session.drain()
        session.stop()
        session.stop()
        assertEquals("a write after expiry reached the track", writesAtExpiry, HeadControlledAudioTrack.writeCalls)
        assertEquals("a drain after expiry waited", expiredAt, testScheduler.currentTime)
    }

    @Test
    fun stopReleasesAStalledDrainWithoutFailing() = runTest {
        HeadControlledAudioTrack.headPositions = ArrayDeque(listOf(0))
        val session = AudioTrackAudioOutputService(StandardTestDispatcher(testScheduler)).open(format)
        session.write(ShortArray(24_000))
        val drain = async { runCatching { session.drain() }.exceptionOrNull() }
        advanceTimeBy(1_000L)
        session.stop()
        advanceUntilIdle()
        assertNull("stop() during a stalled drain must release it without a failure", drain.await())
        assertEquals("the drain outlived stop()", true, testScheduler.currentTime < 3_000L)
    }

    @Test
    fun aWriteBlockedInTheTrackIsBoundedAndEndsTheSession() {
        // The track accepts the first second, then the next write parks until the head moves; the
        // head never does. Unplayed audio at wait start is the 1 s already written plus the 1 s
        // being written, so the bound is 2 s plus the grace. The write blocks a real IO thread, so
        // the virtual clock is advanced by hand rather than by runTest (which would skip it ahead).
        val scheduler = TestCoroutineScheduler()
        val clock = StandardTestDispatcher(scheduler)
        runBlocking {
            val session = AudioTrackAudioOutputService(Dispatchers.IO).open(format)
            suspend fun <T> inVirtualTime(block: suspend () -> T): Deferred<T> = async(clock) { block() }
            fun settle(job: Deferred<*>, untilBlocked: Boolean) {
                val deadline = System.nanoTime() + 10_000_000_000L
                while (!job.isCompleted && !(untilBlocked && HeadControlledAudioTrack.blockedWrites > 0) && System.nanoTime() < deadline) {
                    scheduler.runCurrent()
                    Thread.sleep(1)
                }
            }
            val first = inVirtualTime { session.write(ShortArray(24_000)) }
            settle(first, untilBlocked = false)
            first.await()
            HeadControlledAudioTrack.blockWritesUntilHeadAtLeast = 1_000_000
            val second = inVirtualTime { runCatching { session.write(ShortArray(24_000)) }.exceptionOrNull() }
            settle(second, untilBlocked = true)
            scheduler.advanceTimeBy(4_000L - 1)
            scheduler.runCurrent()
            assertTrue("the write gave up before its bound", second.isActive)
            scheduler.advanceTimeBy(1L)
            scheduler.runCurrent()
            settle(second, untilBlocked = false)
            val error = second.await() as? IndeRunException
            assertEquals("audio_output_failed", error?.details?.get("code"))
            assertEquals(IndeRunErrorClass.Unavailable, error?.errorClass)
            val writesAtExpiry = HeadControlledAudioTrack.writeCalls
            val expiredAt = scheduler.currentTime
            val later = inVirtualTime {
                session.write(ShortArray(2_400))
                session.drain()
                session.stop()
                session.stop()
            }
            settle(later, untilBlocked = false)
            later.await()
            assertEquals("a write after expiry reached the track", writesAtExpiry, HeadControlledAudioTrack.writeCalls)
            assertEquals("a drain after expiry waited", expiredAt, scheduler.currentTime)
        }
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
    protected fun write(audioData: ShortArray, offsetInShorts: Int, sizeInShorts: Int, writeMode: Int): Int {
        writeCalls++
        // A blocking write parks until the head moves or the session ends (stop() releases it).
        val deadline = System.nanoTime() + BLOCK_CAP_NANOS
        if (blockWritesUntilHeadAtLeast > lastHead) blockedWrites++
        while (blockWritesUntilHeadAtLeast > lastHead && !trackStopped && System.nanoTime() < deadline) {
            Thread.sleep(1)
        }
        return sizeInShorts
    }

    @Implementation
    protected fun stop() {
        trackStopped = true
    }

    @Implementation
    override fun getPlaybackHeadPosition(): Int {
        headPositions.removeFirstOrNull()?.let { lastHead = it }
        return lastHead
    }

    companion object {
        var headPositions: ArrayDeque<Int> = ArrayDeque()
        var writeCalls = 0

        /** Writes park while the head is below this and the track has not been stopped. */
        @Volatile var blockWritesUntilHeadAtLeast = 0

        /** How many writes have parked. */
        @Volatile var blockedWrites = 0

        @Volatile private var trackStopped = false
        private var lastHead = 0
        private const val BLOCK_CAP_NANOS = 5_000_000_000L

        fun reset() {
            headPositions = ArrayDeque()
            lastHead = 0
            writeCalls = 0
            blockWritesUntilHeadAtLeast = 0
            blockedWrites = 0
            trackStopped = false
        }
    }
}
