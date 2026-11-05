package app.independo.inderun.providers.neuralspeech

import app.independo.inderun.contracts.ModelPackage
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.PI
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * What a [FixtureNeuralSpeechRuntime] does.
 *
 * @property availability What [FixtureNeuralSpeechRuntime.availability] reports.
 * @property prepareResult What [FixtureNeuralSpeechRuntime.prepare] reports.
 * @property msPerCharacter Synthetic duration per character of the sentence.
 * @property chunkMs Duration of one chunk; the last chunk of a sentence may be shorter.
 * @property delayMs Wall delay before each chunk.
 * @property failAfterChunks Throw a [NeuralSpeechRuntimeErrorKind.Internal] error after this many
 *   chunks of one sentence.
 */
data class FixtureNeuralSpeechRuntimeOptions(
    val availability: NeuralSpeechAvailability = NeuralSpeechAvailability(true),
    val prepareResult: NeuralSpeechAvailability = NeuralSpeechAvailability(true),
    val msPerCharacter: Int = 50,
    val chunkMs: Int = 100,
    val delayMs: Long = 0,
    val failAfterChunks: Int? = null,
)

/**
 * Deterministic runtime for tests: a 440 Hz sine at -14 dBFS with phase continuous across the
 * chunks of one sentence, [FixtureNeuralSpeechRuntimeOptions.msPerCharacter] times the sentence
 * length (in UTF-16 units, as on Web) long, in chunks of [FixtureNeuralSpeechRuntimeOptions.chunkMs]
 * with `isLast` on the final one, at the package's `speech.sampleRate`. Cancelling the collector
 * ends synthesis between chunks. Records every call. Thread-safe.
 */
class FixtureNeuralSpeechRuntime(
    private val options: FixtureNeuralSpeechRuntimeOptions = FixtureNeuralSpeechRuntimeOptions(),
) : NeuralSpeechRuntime {
    private val recorded = mutableListOf<NeuralSpeechSynthesisInput>()
    private val prepares = AtomicInteger()
    private val availabilities = AtomicInteger()

    /** Every [synthesize] call, in call order. */
    val synthesized: List<NeuralSpeechSynthesisInput>
        get() = synchronized(recorded) { recorded.toList() }

    val prepareCalls: Int get() = prepares.get()

    val availabilityCalls: Int get() = availabilities.get()

    override suspend fun availability(modelPackage: ModelPackage): NeuralSpeechAvailability {
        availabilities.incrementAndGet()
        return options.availability
    }

    override suspend fun prepare(modelPackage: ModelPackage): NeuralSpeechAvailability {
        prepares.incrementAndGet()
        return options.prepareResult
    }

    override fun synthesize(input: NeuralSpeechSynthesisInput): Flow<PcmChunk> = flow {
        synchronized(recorded) { recorded += input }
        val sampleRate = input.modelPackage.speech?.sampleRate?.toInt() ?: DEFAULT_SAMPLE_RATE
        val totalFrames = Math.round(input.text.length.toDouble() * options.msPerCharacter * sampleRate / 1000).toInt()
        val chunkFrames = max(1, Math.round(options.chunkMs.toDouble() * sampleRate / 1000).toInt())

        var produced = 0
        var chunks = 0
        while (produced < totalFrames) {
            currentCoroutineContext().ensureActive()
            if (options.failAfterChunks != null && chunks >= options.failAfterChunks) {
                throw NeuralSpeechRuntimeError(NeuralSpeechRuntimeErrorKind.Internal, "fixture synthesis failed")
            }
            if (options.delayMs > 0) delay(options.delayMs)
            val frames = min(chunkFrames, totalFrames - produced)
            val samples = ShortArray(frames) { i ->
                Math.round(AMPLITUDE * sin(2 * PI * TONE_HZ * (produced + i) / sampleRate)).toInt().toShort()
            }
            produced += frames
            chunks += 1
            emit(PcmChunk(samples, sampleRate, isLast = produced >= totalFrames))
        }
    }

    private companion object {
        const val TONE_HZ = 440.0

        /** About -14 dBFS. */
        const val AMPLITUDE = 0.2 * 32767

        /** Only for a package without a speech block, which the provider never synthesizes. */
        const val DEFAULT_SAMPLE_RATE = 24000
    }
}
