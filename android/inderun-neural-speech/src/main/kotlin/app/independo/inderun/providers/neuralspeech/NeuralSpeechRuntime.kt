package app.independo.inderun.providers.neuralspeech

import app.independo.inderun.contracts.ModelPackage
import kotlinx.coroutines.flow.Flow

/**
 * Availability snapshot reported by a [NeuralSpeechRuntime].
 *
 * @property reason Human-readable detail; the provider surfaces it verbatim when [available] is
 *   false.
 * @property readiness Optional hint, reported until the provider has loaded the model itself; null
 *   keeps the provider's own `cold`.
 */
data class NeuralSpeechAvailability(
    val available: Boolean,
    val reason: String? = null,
    val readiness: NeuralSpeechReadiness? = null,
)

/** How ready a runtime's model is before the provider has loaded it (ADR 019). */
enum class NeuralSpeechReadiness(val rawValue: String) {
    /** A `prepare` is required before a run can succeed. */
    NotPrepared("not_prepared"),

    /** A run works, but the first one is slow. */
    Cold("cold"),
}

/** One sentence handed to a [NeuralSpeechRuntime]. */
data class NeuralSpeechSynthesisInput(
    val modelPackage: ModelPackage,
    val text: String,
    val locale: String,
    val voiceId: String,
)

/**
 * Executes a speech model package.
 *
 * [availability] is also where an unknown `pipeline` is refused, with the reason verbatim; it must
 * not load the model. `limits.memBytes` is refused there by the composed runtime of
 * `inderun-onnx-providers` (`OnnxNeuralSpeechRuntime`), against the device's total memory; the
 * pipeline runtimes (`ArticulinoRuntime`) do not check it. [prepare] loads the model and is
 * idempotent on success: the same package (`id@version`) prepared again returns the remembered
 * outcome; only a failed prepare is retried. [synthesize] is called once per
 * sentence and produces that sentence's PCM; it honours coroutine cancellation between chunks
 * (cancelling the collector ends synthesis), and signals failures with [NeuralSpeechRuntimeError].
 *
 * The provider collects [synthesize] on the caller's dispatcher, which may be Main (`speak` can be
 * called from the UI). A runtime that does real inference must move that work off it, for example
 * with `flowOn(Dispatchers.Default)`. On a timeout the provider cancels the collection and returns
 * without waiting for it to end, so compute still running must stay bounded to that sentence.
 *
 * The provider consumes (copies or hands to the host) a chunk's samples before the emit returns, so
 * a runtime may reuse its buffer afterwards.
 *
 * [synthesize] may be called concurrently: artifact runs do not wait for the playback turn, and two
 * providers may share one runtime instance. A runtime must serialize or isolate its own sessions.
 *
 * [close] ends the runtime's life and releases what it holds (loaded models, executors). It is
 * synchronous, because [AutoCloseable] is: it returns at once, marks the runtime closed and
 * schedules the teardown after any graph call in flight, so a model is never released while one
 * of its graphs runs. The default does nothing, for a runtime that holds nothing. Closing is
 * terminal and idempotent. Afterwards [availability] reports `available = false` with the reason
 * `runtime closed` (it does not throw), and [prepare] and [synthesize] fail with a
 * [NeuralSpeechRuntimeError] of kind `Unavailable`, message `runtime closed` and code
 * [RUNTIME_CLOSED_CODE]; nothing is loaded or created any more, and [normalizeText] returns the
 * text unchanged. A synthesis cut short by [close] fails the same way at its next chunk, unless
 * it already delivered its last chunk (it completes) or its collector was cancelled
 * (cancellation wins). The provider maps the code into the error's `details.code`; before the
 * first sound the engine tries the next provider, after it the run ends `Unavailable`.
 */
interface NeuralSpeechRuntime : AutoCloseable {
    suspend fun availability(modelPackage: ModelPackage): NeuralSpeechAvailability

    suspend fun prepare(modelPackage: ModelPackage): NeuralSpeechAvailability

    fun synthesize(input: NeuralSpeechSynthesisInput): Flow<PcmChunk>

    /**
     * Optional pre-split hook, called once per request on the whole text, before the provider
     * splits it into sentences. [locale] is the tag the text is spoken in (the request's own while
     * the voice speaks its language, else the voice's first locale). The default returns [text]
     * unchanged. A failure is signalled with [NeuralSpeechRuntimeError] and ends the run before any
     * audio output is opened.
     */
    fun normalizeText(modelPackage: ModelPackage, text: String, locale: String): String = text

    override fun close() {}
}

/** The [NeuralSpeechRuntimeError.code] of a closed runtime, mapped into the error's `details.code`. */
const val RUNTIME_CLOSED_CODE = "runtime_closed"

/**
 * Failure category a runtime signals so the provider maps it onto the IndeRun error taxonomy
 * (`CapabilityMismatch`, `Unavailable`, `Timeout`, `Internal`). Anything else a runtime throws is
 * normalized to `Internal`.
 */
enum class NeuralSpeechRuntimeErrorKind { Capability, Unavailable, Timeout, Internal }

/**
 * Error type neural speech runtimes throw to steer IndeRun error normalization.
 *
 * @property code Optional machine-readable code the provider surfaces as the error's `details.code`.
 */
class NeuralSpeechRuntimeError(
    val kind: NeuralSpeechRuntimeErrorKind,
    message: String,
    cause: Throwable? = null,
    val code: String? = null,
) : Exception(message, cause)
