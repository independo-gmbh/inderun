package app.independo.inderun.providers.systemspeech

/**
 * An installed `android.speech.tts.Voice`, free of platform types. [name] is unique, and the
 * catalog lists it as both id and display name, because the platform has no other label (ADR 018).
 */
data class AndroidSpeechVoice(
    val name: String,
    val locale: String,
    val networkRequired: Boolean,
    /** False while the engine still has to download this voice's data (`KEY_FEATURE_NOT_INSTALLED`). */
    val installed: Boolean = true,
)

/** Why a speech engine cannot be used. */
sealed interface AndroidSpeechReadiness {
    data object Ready : AndroidSpeechReadiness

    data class Unavailable(val reason: String) : AndroidSpeechReadiness
}

/** What one finished utterance reported; either value is null when the engine never sent its callback. */
data class AndroidSpokenAudio(
    /** From `onStart` to `onDone`. */
    val durationMs: Double? = null,
    /**
     * From handing the utterance to the engine to its first `onRangeStart`, the earliest callback
     * that marks a word being spoken. Engines that do not report ranges leave it null.
     */
    val firstAudioMs: Double? = null,
)

/**
 * The seam around `android.speech.tts.TextToSpeech`, kept free of platform types so the provider
 * runs in plain unit tests. Callers use one engine call at a time: the engine's voice selection
 * and its queue are shared state, so the provider serializes them.
 */
interface AndroidSpeechEngine {
    /** Connects to the installed TTS engine, once. Never throws. */
    suspend fun readiness(): AndroidSpeechReadiness

    /**
     * Every usable voice, also those still to be downloaded, best quality first and the engine's default ahead of its
     * equals. Empty when the engine cannot enumerate them, which an older engine may not.
     */
    suspend fun voices(): List<AndroidSpeechVoice>

    /**
     * Selects what the next [speak] or [synthesize] uses: [voice] when known, otherwise the
     * engine's own choice for [locale].
     *
     * Selecting a voice that is not [AndroidSpeechVoice.installed] makes the engine download it.
     *
     * @return false when the engine cannot speak it. Nothing has been audible yet, so the caller
     *   can still fall back.
     */
    suspend fun select(locale: String, voice: AndroidSpeechVoice?): Boolean

    /**
     * Sets the speech rate of the next [speak] or [synthesize] (`TextToSpeech.setSpeechRate`; 1.0 is
     * normal). Like [select] it is shared engine state and stays set for every later utterance, so
     * the provider calls it only for an utterance that applies a rate, and calls [resetSpeechRate]
     * before the next one that does not.
     *
     * @return false when the platform refuses the value (`TextToSpeech.ERROR`).
     */
    suspend fun setSpeechRate(rate: Double): Boolean

    /** [setSpeechRate] for the pitch (`TextToSpeech.setPitch`; 1.0 is normal). */
    suspend fun setPitch(pitch: Double): Boolean

    /**
     * Undoes an earlier [setSpeechRate]: sets the user's own default rate, the one the platform uses
     * for an app that never set one. The platform engine reads it from the system text-to-speech
     * settings. The default sets 1.0, for an engine that cannot tell.
     *
     * @return false when the platform refuses the value.
     */
    suspend fun resetSpeechRate(): Boolean = setSpeechRate(1.0)

    /** [resetSpeechRate] for the pitch. */
    suspend fun resetPitch(): Boolean = setPitch(1.0)

    /**
     * Speaks [text] and returns once it has finished, with how long it played when known.
     * Cancelling the calling coroutine stops the audio immediately.
     */
    suspend fun speak(text: String): Double?

    /**
     * Whether [speakWithTimings] applies its `volume` to the utterance. The provider declares
     * `playback.volume` only when it does, so a request is never told a volume was applied that the
     * engine dropped. False by default, like [speakWithTimings]'s default, which ignores the volume.
     */
    val attenuatesPlayback: Boolean
        get() = false

    /**
     * [speak], also reporting when the first word started. The provider calls this one; an engine
     * that cannot tell when audio starts keeps the default, which reports only the duration.
     *
     * @param volume this utterance's attenuation from 0 to 1 (`KEY_PARAM_VOLUME`), or null to leave
     *   the platform's. Only a playback run passes it; [synthesize] has no volume. The default
     *   ignores it, so an engine that attenuates must override this method.
     */
    suspend fun speakWithTimings(text: String, volume: Double? = null): AndroidSpokenAudio = AndroidSpokenAudio(durationMs = speak(text))

    /**
     * Renders [text] silently and returns the file's bytes; the engine holds no copy. Cancelling
     * the calling coroutine stops rendering.
     *
     * @throws app.independo.inderun.core.IndeRunException `Unavailable` with
     *   `details.code: "artifact_too_large"` when the output exceeds [maxBytes].
     */
    suspend fun synthesize(text: String, maxBytes: Long): ByteArray

    /** Releases the engine connection. */
    fun close()
}
