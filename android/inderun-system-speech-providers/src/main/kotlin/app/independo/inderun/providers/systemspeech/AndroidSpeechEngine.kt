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
     * Speaks [text] and returns once it has finished, with how long it played when known.
     * Cancelling the calling coroutine stops the audio immediately.
     */
    suspend fun speak(text: String): Double?

    /**
     * [speak], also reporting when the first word started. The provider calls this one; an engine
     * that cannot tell when audio starts keeps the default, which reports only the duration.
     */
    suspend fun speakWithTimings(text: String): AndroidSpokenAudio = AndroidSpokenAudio(durationMs = speak(text))

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
