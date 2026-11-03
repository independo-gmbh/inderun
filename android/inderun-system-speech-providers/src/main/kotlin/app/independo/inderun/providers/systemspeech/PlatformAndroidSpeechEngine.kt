package app.independo.inderun.providers.systemspeech

import android.content.Context
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import app.independo.inderun.core.createUnavailable
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * [AndroidSpeechEngine] over the device's default TTS engine.
 *
 * One `TextToSpeech` is bound on first use and kept, because the provider's capability check runs
 * on every request. Its asynchronous init is awaited with a bound: a missing or broken engine may
 * never call back. A failed `speak` drops the binding, so a replaced or restarted engine is bound
 * again on the next request.
 *
 * Every utterance has a unique id and a callback for any other id is ignored, so a late event from
 * a stopped utterance cannot settle a newer one.
 *
 * `synthesizeToFile` needs a file. The store holds no temporary files (ADR 017), so this engine
 * owns a directory under `cacheDir` for them: it deletes each file when read, and clears the
 * directory on binding, for what an earlier process left behind.
 */
internal class PlatformAndroidSpeechEngine(context: Context) : AndroidSpeechEngine {
    private val appContext = context.applicationContext
    private val pending = ConcurrentHashMap<String, Pending>()
    private val lock = Any()
    private var binding: Binding? = null
    private var retryAfterNanos: Long? = null

    private class Binding(val tts: TextToSpeech, val ready: CompletableDeferred<Boolean>)

    private class Pending(val continuation: CancellableContinuation<AndroidSpokenAudio>) {
        val issuedAt: Long = System.nanoTime()

        @Volatile
        var startedAt: Long? = null

        @Volatile
        var firstRangeAt: Long? = null

        fun finish() = continuation.resume(
            AndroidSpokenAudio(
                durationMs = startedAt?.let { (System.nanoTime() - it) / 1_000_000.0 },
                firstAudioMs = firstRangeAt?.let { (it - issuedAt) / 1_000_000.0 },
            ),
        )

        fun fail(error: Throwable) = continuation.resumeWithException(error)
    }

    private val listener = object : UtteranceProgressListener() {
        override fun onStart(utteranceId: String) {
            pending[utteranceId]?.startedAt = System.nanoTime()
        }

        override fun onRangeStart(utteranceId: String, start: Int, end: Int, frame: Int) {
            val entry = pending[utteranceId] ?: return
            if (entry.firstRangeAt == null) entry.firstRangeAt = System.nanoTime()
        }

        override fun onDone(utteranceId: String) {
            pending.remove(utteranceId)?.finish()
        }

        @Deprecated("Superseded by the overload with an error code; still abstract.")
        override fun onError(utteranceId: String) = fail(utteranceId)

        override fun onError(utteranceId: String, errorCode: Int) {
            if (errorCode == TextToSpeech.ERROR_NOT_INSTALLED_YET) {
                pending.remove(utteranceId)?.fail(
                    createUnavailable(
                        "The TTS engine is still downloading this voice.",
                        details = mapOf("code" to "not_ready"),
                    ),
                )
            } else {
                fail(utteranceId)
            }
        }

        // A cancelled coroutine removed its own entry first, so this is a stop from outside.
        override fun onStop(utteranceId: String, interrupted: Boolean) = fail(utteranceId)

        private fun fail(utteranceId: String) {
            pending.remove(utteranceId)?.fail(engineError("The TTS engine stopped the utterance."))
        }
    }

    private fun bind(): Binding = synchronized(lock) {
        binding ?: run {
            speechFiles().listFiles()?.forEach { it.delete() }
            val ready = CompletableDeferred<Boolean>()
            val tts = TextToSpeech(appContext) { status -> ready.complete(status == TextToSpeech.SUCCESS) }
            tts.setOnUtteranceProgressListener(listener)
            Binding(tts, ready).also { binding = it }
        }
    }

    private fun unbind(failed: Binding) = synchronized(lock) {
        if (binding === failed) binding = null
        failed.tts.shutdown()
    }

    /**
     * A failed start is remembered for a while: the capability check runs on every request, text
     * included, and each attempt could otherwise cost the whole init timeout.
     */
    private suspend fun readyEngine(): TextToSpeech? {
        val backingOff = synchronized(lock) { retryAfterNanos?.let { System.nanoTime() - it < 0 } == true }
        if (backingOff) return null
        val current = bind()
        if (withTimeoutOrNull(INIT_TIMEOUT_MS) { current.ready.await() } == true) return current.tts
        synchronized(lock) { retryAfterNanos = System.nanoTime() + RETRY_BACKOFF_NANOS }
        unbind(current)
        return null
    }

    override suspend fun readiness(): AndroidSpeechReadiness = if (readyEngine() != null) {
        AndroidSpeechReadiness.Ready
    } else {
        AndroidSpeechReadiness.Unavailable("No text-to-speech engine could be started.")
    }

    override suspend fun voices(): List<AndroidSpeechVoice> {
        // `getVoices` is documented to return null on error and a broken engine may throw.
        val voices = runCatching { readyEngine()?.voices }.getOrNull().orEmpty()
        val default = runCatching { readyEngine()?.defaultVoice?.name }.getOrNull()
        return voices
            .sortedWith(compareByDescending<Voice> { it.quality }.thenByDescending { it.name == default }.thenBy { it.name })
            .map { voice ->
                AndroidSpeechVoice(
                    voice.name,
                    voice.locale.toLanguageTag(),
                    voice.isNetworkConnectionRequired,
                    installed = TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED !in voice.features.orEmpty(),
                )
            }
    }

    override suspend fun select(locale: String, voice: AndroidSpeechVoice?): Boolean {
        val tts = readyEngine() ?: return false
        if (voice != null) {
            val match = tts.voices?.firstOrNull { it.name == voice.name } ?: return false
            return tts.setVoice(match) == TextToSpeech.SUCCESS
        }
        return tts.setLanguage(Locale.forLanguageTag(locale)) >= TextToSpeech.LANG_AVAILABLE
    }

    override suspend fun speak(text: String): Double? = speakWithTimings(text).durationMs

    override suspend fun speakWithTimings(text: String): AndroidSpokenAudio {
        val current = bind()
        return awaitUtterance(current) { id -> current.tts.speak(text, TextToSpeech.QUEUE_ADD, Bundle(), id) }
    }

    override suspend fun synthesize(text: String, maxBytes: Long): ByteArray {
        val current = bind()
        val file = File(speechFiles().apply { mkdirs() }, "${UUID.randomUUID()}.wav")
        try {
            awaitUtterance(current) { id -> current.tts.synthesizeToFile(text, Bundle(), file, id) }
            if (file.length() > maxBytes) throw AndroidSystemSpeechProvider.tooLarge()
            return withContext(Dispatchers.IO) { file.readBytes() }
        } finally {
            file.delete()
        }
    }

    /** Runs one utterance to its end and returns its timings. */
    private suspend fun awaitUtterance(current: Binding, start: (String) -> Int): AndroidSpokenAudio = coroutineScope {
        val id = UUID.randomUUID().toString()
        // Without it an engine that never calls back would hold the provider's turn until the
        // caller cancels.
        val startWatchdog = launch {
            delay(START_TIMEOUT_MS)
            if (pending[id]?.startedAt == null) {
                pending.remove(id)?.fail(engineError("The TTS engine did not start the utterance in time."))
                current.tts.stop()
            }
        }
        try {
            suspendCancellableCoroutine { continuation ->
                pending[id] = Pending(continuation)
                continuation.invokeOnCancellation {
                    pending.remove(id)
                    current.tts.stop()
                }
                // The block runs even when the coroutine is already cancelled.
                if (!continuation.isActive) return@suspendCancellableCoroutine
                if (start(id) != TextToSpeech.SUCCESS) {
                    pending.remove(id)
                    unbind(current)
                    continuation.resumeWithException(engineError("The TTS engine refused the utterance."))
                } else if (!continuation.isActive) {
                    // A cancel that landed during `start` found nothing to stop yet.
                    current.tts.stop()
                }
            }
        } finally {
            startWatchdog.cancel()
        }
    }

    private fun engineError(message: String) = createUnavailable(message, details = mapOf("code" to "speech_engine_error"))

    /** Fails what is still in flight: a shut-down engine owes no callback, and a turn is held. */
    override fun close() {
        pending.keys.toList().forEach { id ->
            pending.remove(id)?.fail(engineError("The speech provider was closed."))
        }
        synchronized(lock) {
            binding?.tts?.shutdown()
            binding = null
        }
    }

    private fun speechFiles() = File(appContext.cacheDir, "inderun-speech")

    private companion object {
        const val INIT_TIMEOUT_MS = 5_000L
        const val START_TIMEOUT_MS = 15_000L
        const val RETRY_BACKOFF_NANOS = 30_000_000_000L
    }
}
