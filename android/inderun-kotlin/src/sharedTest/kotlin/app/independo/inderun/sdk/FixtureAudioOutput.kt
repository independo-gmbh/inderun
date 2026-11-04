package app.independo.inderun.sdk

import app.independo.inderun.core.AudioOutputEncoding
import app.independo.inderun.core.AudioOutputFormat
import app.independo.inderun.core.AudioOutputService
import app.independo.inderun.core.AudioOutputSession
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.createCapabilityMismatch

/** Virtual milliseconds, shared by a service and its sessions. */
internal class FixtureClock {
    var ms: Double = 0.0
}

/**
 * A recording audio output with a virtual clock: [now] starts at 0 and only `drain()` advances
 * it, by the duration of the frames not yet played. `write()` returns at once.
 */
internal class FixtureAudioOutputService : AudioOutputService {
    private val clock = FixtureClock()
    private val lock = Any()
    private val opened = mutableListOf<FixtureAudioOutputSession>()

    val sessions: List<FixtureAudioOutputSession>
        get() = synchronized(lock) { opened.toList() }

    /** Virtual milliseconds; advanced only by `drain()`. */
    fun now(): Double = synchronized(lock) { clock.ms }

    override suspend fun open(format: AudioOutputFormat): AudioOutputSession {
        if (
            format.channels != 1 ||
            format.encoding != AudioOutputEncoding.PcmS16le ||
            format.sampleRate < 8000 ||
            format.sampleRate > 48000
        ) {
            throw createCapabilityMismatch(
                "The audio output does not support this format.",
                details = mapOf("code" to "audio_format_unsupported"),
            )
        }
        return synchronized(lock) {
            FixtureAudioOutputSession(format, clock, lock).also { opened += it }
        }
    }
}

internal class FixtureAudioOutputSession internal constructor(
    val format: AudioOutputFormat,
    private val clock: FixtureClock,
    private val lock: Any,
) : AudioOutputSession {
    private val recorded = mutableListOf<ShortArray>()
    private var written = 0L
    private var played = 0L
    private var discarded = 0L
    private var isPlaying = false
    private var isStopped = false
    private var endError: IndeRunException? = null
    private var firstAudio: Double? = null
    private val openedAt = clock.ms

    val writes: List<ShortArray> get() = synchronized(lock) { recorded.toList() }
    val writtenFrames: Long get() = synchronized(lock) { written }
    val playedFrames: Long get() = synchronized(lock) { played }
    val discardedFrames: Long get() = synchronized(lock) { discarded }
    val playing: Boolean get() = synchronized(lock) { isPlaying }
    val stopped: Boolean get() = synchronized(lock) { isStopped }

    override suspend fun write(samples: ShortArray) = synchronized(lock) {
        endError?.let { throw it }
        if (isStopped) return@synchronized
        recorded += samples
        written += samples.size
        if (firstAudio == null) {
            firstAudio = clock.ms - openedAt
            isPlaying = true
        }
    }

    override suspend fun drain() = synchronized(lock) {
        endError?.let { throw it }
        if (isStopped) return@synchronized
        val pending = written - played
        clock.ms += pending * 1000.0 / format.sampleRate
        played = written
    }

    override fun stop() = end(null)

    /**
     * Ends the session the way the system does (an interruption): buffered audio is discarded,
     * and every later `write()` and `drain()` throws [error]. After `stop()` they return instead.
     */
    fun interrupt(error: IndeRunException) = end(error)

    private fun end(error: IndeRunException?) = synchronized(lock) {
        if (isStopped) return@synchronized
        isStopped = true
        endError = error
        isPlaying = false
        discarded += written - played
    }

    override fun firstAudioMs(): Double? = synchronized(lock) { firstAudio }
}
