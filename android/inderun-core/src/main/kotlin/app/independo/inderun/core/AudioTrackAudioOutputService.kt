package app.independo.inderun.core

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.max
import kotlin.math.min

/**
 * The default [AudioOutputService]: one streaming [AudioTrack] per session, with accessibility
 * speech attributes and no audio focus request (the application owns focus).
 *
 * The constructor touches no `AudioTrack`; [open] validates the format before it builds one, and
 * builds it on [ioDispatcher] because building it is a call into the audio server.
 *
 * @param ioDispatcher Where the track is built and the blocking `AudioTrack.write` runs, so
 *   neither blocks the caller.
 * @param drainGraceMs How long past the unplayed audio's duration a write blocked in the track and
 *   [AudioOutputSession.drain] wait
 *   for the playback head before it fails with `audio_output_failed` (ADR 021 section 5).
 * @param drainPollMs How often [AudioOutputSession.drain] reads the playback head.
 */
class AudioTrackAudioOutputService(
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val drainGraceMs: Long = 2_000L,
    private val drainPollMs: Long = 10L,
) : AudioOutputService {
    override suspend fun open(format: AudioOutputFormat): AudioOutputSession {
        val openedAt = SystemClock.elapsedRealtime()
        currentCoroutineContext().ensureActive()
        if (format.channels != 1 || format.encoding != AudioOutputEncoding.PcmS16le || format.sampleRate !in MIN_SAMPLE_RATE..MAX_SAMPLE_RATE) {
            throw formatUnsupported(format)
        }
        val built = AtomicReference<AudioTrack?>(null)
        try {
            withContext(ioDispatcher) { built.set(buildTrack(format)) }
        } catch (cancelled: CancellationException) {
            // Cancelled while the track was being built, or right after: nothing will own it.
            built.getAndSet(null)?.release()
            throw cancelled
        }
        val track = checkNotNull(built.get())
        return AudioTrackAudioOutputSession(track, format, ioDispatcher, openedAt, drainGraceMs, drainPollMs)
    }

    /** Builds an initialized streaming track, or throws `audio_format_unsupported`/`audio_output_failed`. */
    private fun buildTrack(format: AudioOutputFormat): AudioTrack {
        val minBufferSize = AudioTrack.getMinBufferSize(format.sampleRate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minBufferSize <= 0) throw formatUnsupported(format)
        // At least 200 ms of frames, so a short first write is buffered without waiting on the head.
        val bufferSize = max(minBufferSize, format.sampleRate / 5 * BYTES_PER_FRAME)
        val track = try {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .setSampleRate(format.sampleRate)
                        .build(),
                )
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(bufferSize)
                .build()
        } catch (error: Exception) {
            throw outputFailed("Could not create an AudioTrack: ${error.message}")
        }
        if (track.state != AudioTrack.STATE_INITIALIZED) {
            track.release()
            throw outputFailed("The AudioTrack did not initialize.")
        }
        return track
    }

    private fun formatUnsupported(format: AudioOutputFormat) = createCapabilityMismatch(
        "Audio output supports mono pcm_s16le at $MIN_SAMPLE_RATE to $MAX_SAMPLE_RATE Hz, not $format.",
        details = mapOf("code" to "audio_format_unsupported"),
    )

    private companion object {
        const val MIN_SAMPLE_RATE = 8_000
        const val MAX_SAMPLE_RATE = 48_000
        const val BYTES_PER_FRAME = 2
    }
}

/**
 * One [AudioTrack] in streaming mode. The first [write] (and the first after a [drain]) starts
 * playback; [write] blocks on the track's buffer on [ioDispatcher], which is the backpressure, and
 * that wait is bounded: a watchdog allows the unplayed audio's duration plus the drain grace, then
 * ends the session (which returns the blocked write) and the write throws `audio_output_failed`
 * (`Unavailable`), with the same semantics as a drain that expires: later writes are ignored, a
 * later [drain] returns at once and [stop] stays a no-op. It writes in slices of at most one buffer and checks for cancellation between them, so a cancelled
 * write returns within about one buffer. [stop] pauses, flushes, stops and releases the track once,
 * which also returns a write blocked in the track; the provider's cancel path is [stop]. A slice
 * write that races the release can throw `IllegalStateException` from the track; it returns once
 * the session has stopped and is `audio_output_failed` otherwise.
 *
 * The system ends the session when the track's server side dies (`ERROR_DEAD_OBJECT` from a
 * write): the track is torn down as by [stop], and that write and every later [write] and [drain]
 * throw `Unavailable` with `details.code` `audio_output_interrupted`. After [stop] they return.
 *
 * [drain] pads the track with one buffer of silence before it waits for the playback head, then
 * pauses, flushes and stops it so the padding never plays out. AudioFlinger holds a streaming
 * track's last partial mix period while another track keeps the mixer busy (TalkBack, music), so
 * without the padding the end of the audio is never heard and the head stops short of the frames
 * written. [drain] returns only once the head has reached the last frame written; a head that
 * stalls short of it (a mixer that stops consuming the track) makes [drain] throw
 * `audio_output_failed` when its timeout runs out, never return as if the audio had played. That
 * failure also ends the session: later writes are ignored, a later [drain] returns at once and
 * [stop] stays a no-op.
 *
 * First audio comes from a playback-head marker at frame 1, delivered on the main looper; the
 * emulator has no HAL timestamps, so `AudioTrack.getTimestamp` is not used.
 */
internal class AudioTrackAudioOutputSession(
    private val track: AudioTrack,
    private val format: AudioOutputFormat,
    private val ioDispatcher: CoroutineDispatcher,
    private val openedAt: Long,
    private val drainGraceMs: Long,
    private val drainPollMs: Long,
) : AudioOutputSession {
    private val stopped = AtomicBoolean(false)

    /** Set when the watchdog of a blocked [write] ended the session. */
    private val writeExpired = AtomicBoolean(false)

    /** Set before [stopped] when the system ended the session; `null` after [stop]. */
    @Volatile private var endError: IndeRunException? = null
    private val framesWritten = AtomicLong(0)
    private val firstAudioAt = AtomicLong(NOT_YET)
    private val bufferFrames = track.bufferSizeInFrames.coerceAtLeast(1)

    /** Guards `play()`, the drain's `stop()` and the teardown, so none runs on a released track. */
    private val lock = Any()
    private var playing = false

    private val markerListener = object : AudioTrack.OnPlaybackPositionUpdateListener {
        override fun onMarkerReached(track: AudioTrack) {
            if (!stopped.get()) firstAudioAt.compareAndSet(NOT_YET, SystemClock.elapsedRealtime())
        }

        override fun onPeriodicNotification(track: AudioTrack) = Unit
    }

    init {
        track.setPlaybackPositionUpdateListener(markerListener, Handler(Looper.getMainLooper()))
        track.setNotificationMarkerPosition(1)
    }

    override suspend fun write(samples: ShortArray) {
        if (hasEnded() || samples.isEmpty() || !startPlaying()) return
        // A blocking write that never returns (a mixer that stops consuming the track) is bounded like
        // drain(): the unplayed audio plus this write, plus the grace. Ending the session returns it.
        val head = headPosition() ?: return
        val unplayed = max(0L, framesWritten.get() + samples.size - head)
        val boundMs = unplayed * MILLIS_PER_SECOND / format.sampleRate + drainGraceMs
        val written = coroutineScope {
            val watchdog = launch {
                delay(boundMs)
                writeExpired.set(true)
                end(null)
            }
            try {
                withContext(ioDispatcher) { writeSlices(samples) }
            } finally {
                watchdog.cancel()
            }
        }
        if (writeExpired.get()) {
            throw outputFailed("The audio output did not accept audio within $boundMs ms.")
        }
        if (written == AudioTrack.ERROR_DEAD_OBJECT) end(interrupted())
        if (hasEnded()) return
        when {
            written < 0 -> throw outputFailed("AudioTrack.write failed with $written.")

            written < samples.size -> throw outputFailed("AudioTrack.write took $written of ${samples.size} frames.")
        }
    }

    /** The blocking slice loop of [write]: the frames written, or the negative error code of a slice. */
    private suspend fun writeSlices(samples: ShortArray): Int {
        var offset = 0
        while (offset < samples.size) {
            currentCoroutineContext().ensureActive()
            val count = min(bufferFrames, samples.size - offset)
            val result = try {
                track.write(samples, offset, count, AudioTrack.WRITE_BLOCKING)
            } catch (error: IllegalStateException) {
                // `release()` frees the native track before it marks the Java object
                // uninitialized, so a slice write in that window passes the state check.
                if (stopped.get()) break
                throw outputFailed("AudioTrack.write failed: ${error.message}")
            }
            if (result < 0) return result
            framesWritten.addAndGet(result.toLong())
            offset += result
            if (result < count) break
        }
        return offset
    }

    override suspend fun drain() {
        val target = framesWritten.get()
        if (hasEnded() || target == 0L) return
        val head = headPosition()
        if (head == null) {
            hasEnded()
            return
        }
        val remainingMs = max(0L, target - head) * MILLIS_PER_SECOND / format.sampleRate
        val padding = ShortArray(bufferFrames)
        var padded = 0
        val reached = withTimeoutOrNull(remainingMs + drainGraceMs) {
            while (true) {
                // Never blocks, so the timeout bounds the padding too; it does not count toward target.
                if (padded < padding.size) padded += writePadding(padding, padded) ?: break
                val position = headPosition() ?: break
                if (position >= target) break
                delay(drainPollMs)
            }
        }
        if (hasEnded()) return
        if (reached == null) {
            // The output is not rendering: end the session (as Web and Swift do), so later writes are
            // ignored, a later drain returns at once and the track is released.
            end(null)
            throw outputFailed("The audio output did not finish playing within ${remainingMs + drainGraceMs} ms.")
        }
        synchronized(lock) {
            if (hasEnded()) return
            // Discards the padding and resets the head position; the next write calls play() again.
            track.pause()
            track.flush()
            track.stop()
            playing = false
            framesWritten.set(0)
        }
    }

    override fun stop() = end(null)

    /**
     * Ends the session once: with [error] when the system ended it, so later calls throw it.
     * Tears the track down under [lock], which also returns a write blocked in the track.
     */
    private fun end(error: IndeRunException?) {
        synchronized(lock) {
            if (stopped.get()) return
            endError = error
            stopped.set(true)
            playing = false
            track.setPlaybackPositionUpdateListener(null)
            try {
                // pause() and flush() discard what is buffered; stop() returns a blocked write.
                track.pause()
                track.flush()
                track.stop()
            } finally {
                track.release()
            }
        }
    }

    /** True once the session has ended by [stop]; throws the ending error when the system ended it. */
    private fun hasEnded(): Boolean {
        if (!stopped.get()) return false
        endError?.let { throw it }
        return true
    }

    override fun firstAudioMs(): Double? {
        val at = firstAudioAt.get()
        return if (at == NOT_YET) null else (at - openedAt).toDouble()
    }

    /** Starts playback if it is not running; false once the session has stopped. */
    private fun startPlaying(): Boolean = synchronized(lock) {
        if (hasEnded()) return false
        if (!playing) {
            try {
                track.play()
            } catch (error: IllegalStateException) {
                throw outputFailed("AudioTrack.play failed: ${error.message}")
            }
            playing = true
        }
        true
    }

    /**
     * Writes what fits of [padding] from [offset] without blocking: the count written (all of the
     * rest after an error, so padding stops), or null once the session has stopped.
     */
    private fun writePadding(padding: ShortArray, offset: Int): Int? = synchronized(lock) {
        if (stopped.get()) return null
        val result = track.write(padding, offset, padding.size - offset, AudioTrack.WRITE_NON_BLOCKING)
        if (result == AudioTrack.ERROR_DEAD_OBJECT) {
            end(interrupted())
            return null
        }
        if (result < 0) padding.size - offset else result
    }

    /** The playback head in frames, or null once the session has stopped. */
    private fun headPosition(): Long? = synchronized(lock) {
        if (stopped.get()) null else track.playbackHeadPosition.toLong() and 0xFFFF_FFFFL
    }

    private companion object {
        const val NOT_YET = -1L
        const val MILLIS_PER_SECOND = 1_000L
    }
}

private fun outputFailed(message: String) = createUnavailable(message, details = mapOf("code" to "audio_output_failed"))

private fun interrupted() = createUnavailable(
    "The audio output was interrupted.",
    details = mapOf("code" to "audio_output_interrupted"),
)
