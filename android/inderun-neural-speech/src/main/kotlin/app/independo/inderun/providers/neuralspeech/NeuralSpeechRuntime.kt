package app.independo.inderun.providers.neuralspeech

import app.independo.inderun.contracts.ModelPackage
import kotlinx.coroutines.flow.Flow

/**
 * Availability snapshot reported by a [NeuralSpeechRuntime].
 *
 * @property reason Human-readable detail; the provider surfaces it verbatim when [available] is
 *   false.
 */
data class NeuralSpeechAvailability(val available: Boolean, val reason: String? = null)

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
 * [availability] is also where an unknown `pipeline` and `limits.memBytes` are refused, with the
 * reason verbatim; it must not load the model. [prepare] loads it. [synthesize] is called once per
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
 */
interface NeuralSpeechRuntime {
    suspend fun availability(modelPackage: ModelPackage): NeuralSpeechAvailability

    suspend fun prepare(modelPackage: ModelPackage): NeuralSpeechAvailability

    fun synthesize(input: NeuralSpeechSynthesisInput): Flow<PcmChunk>
}

/**
 * Failure category a runtime signals so the provider maps it onto the IndeRun error taxonomy
 * (`CapabilityMismatch`, `Unavailable`, `Timeout`, `Internal`). Anything else a runtime throws is
 * normalized to `Internal`.
 */
enum class NeuralSpeechRuntimeErrorKind { Capability, Unavailable, Timeout, Internal }

/** Error type neural speech runtimes throw to steer IndeRun error normalization. */
class NeuralSpeechRuntimeError(
    val kind: NeuralSpeechRuntimeErrorKind,
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)
