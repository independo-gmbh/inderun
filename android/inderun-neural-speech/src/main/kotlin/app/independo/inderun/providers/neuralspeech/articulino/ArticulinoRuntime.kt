// Adapted from eigenhand/articulino-onnx, Apache License 2.0
// (https://huggingface.co/eigenhand/Articulino-DE-EN-Realtime-Stream-TTS-ONNX).

package app.independo.inderun.providers.neuralspeech.articulino

import app.independo.inderun.contracts.FrontendKind
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.providers.neuralspeech.NeuralSpeechAvailability
import app.independo.inderun.providers.neuralspeech.NeuralSpeechRuntime
import app.independo.inderun.providers.neuralspeech.NeuralSpeechRuntimeError
import app.independo.inderun.providers.neuralspeech.NeuralSpeechRuntimeErrorKind
import app.independo.inderun.providers.neuralspeech.NeuralSpeechSynthesisInput
import app.independo.inderun.providers.neuralspeech.PcmChunk
import app.independo.inderun.providers.neuralspeech.Safetensors
import app.independo.inderun.providers.neuralspeech.SharedCoreSpeechText
import app.independo.inderun.providers.neuralspeech.SpeechGraphExecutor
import app.independo.inderun.providers.neuralspeech.SpeechPackageFiles
import app.independo.inderun.providers.neuralspeech.SpeechTensor
import app.independo.inderun.providers.neuralspeech.SpeechTensorData
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Options of an [ArticulinoRuntime].
 *
 * @property noise Default: Box-Muller over the platform random number generator.
 * @property speed Clamped to 0.7..1.6.
 * @property pauseMs Silence appended after the sentence.
 * @property maxLetters Sentences with more letters are split before synthesis.
 */
data class ArticulinoRuntimeOptions(
    val executor: SpeechGraphExecutor,
    val files: SpeechPackageFiles,
    val noise: NoiseSource? = null,
    val speed: Float = 1.0f,
    val pauseMs: Int = 150,
    val maxLetters: Int = 180,
    internal val textNormalizer: (text: String, locale: String) -> String = SharedCoreSpeechText::normalize,
)

/**
 * The Articulino text-to-PCM pipeline over a [SpeechGraphExecutor]: letters, the `text` graph,
 * durations, the `dit_step` flow steps, the `decoder` and the post-processing, one [PcmChunk] per
 * sentence. The math lives in [ArticulinoMath]; this class holds the loaded state (config, voices)
 * and the per-sentence orchestration.
 *
 * Cancelling the collector ends the flow between graph calls without an error.
 */
class ArticulinoRuntime(private val options: ArticulinoRuntimeOptions) : NeuralSpeechRuntime {
    private class Voice(
        val voiceTokens: SpeechTensor,
        val voiceVector: SpeechTensor,
        val voiceCache: SpeechTensor,
        val promptLatents: SpeechTensor,
        val promptLatentValues: FloatArray,
        val letterRate: Float,
        /** Prompt frames P, read from `voice_cache`'s shape. */
        val promptFrames: Int,
    )

    private class Prepared(val config: ArticulinoConfig, val voices: Map<String, Voice>)

    private sealed interface Outcome {
        class Ready(val prepared: Prepared) : Outcome

        class Failed(val reason: String) : Outcome
    }

    private class VoiceError(val why: String) : Exception(why)

    private val noise: NoiseSource = options.noise ?: ArticulinoMath.gaussianNoise
    private val speed: Float = options.speed.coerceIn(0.7f, 1.6f)

    /** What the last prepare of a package left behind. Guarded by [mutex], which also serializes loads. */
    private val mutex = Mutex()
    private var current: Pair<String, Outcome>? = null

    // region NeuralSpeechRuntime

    override suspend fun availability(modelPackage: ModelPackage): NeuralSpeechAvailability = check(modelPackage)

    /** Idempotent on success: a package (`id@version`) already prepared is not loaded again; a failed one is. */
    override suspend fun prepare(modelPackage: ModelPackage): NeuralSpeechAvailability = when (val outcome = outcome(modelPackage, reload = true)) {
        is Outcome.Ready -> NeuralSpeechAvailability(true)
        is Outcome.Failed -> NeuralSpeechAvailability(false, outcome.reason)
    }

    /**
     * Spells out numbers, dates and abbreviations for a grapheme frontend through the shared route
     * core; any other frontend gets the text unchanged. A failure to reach the core (a missing
     * native library, a failed JNI call) is `Unavailable`.
     */
    override fun normalizeText(modelPackage: ModelPackage, text: String, locale: String): String {
        if (modelPackage.speech?.frontend?.kind != FrontendKind.Grapheme || !isGerman(locale)) return text
        return try {
            options.textNormalizer(text, locale)
        } catch (error: Exception) {
            throw frontendUnavailable(error)
        } catch (error: LinkageError) {
            throw frontendUnavailable(error)
        }
    }

    /** True when the language subtag of [locale] is `de` (case-insensitive, `-` or `_` separated). */
    private fun isGerman(locale: String): Boolean = locale.split('-', '_').first().equals("de", ignoreCase = true)

    private fun frontendUnavailable(error: Throwable) = NeuralSpeechRuntimeError(
        NeuralSpeechRuntimeErrorKind.Unavailable,
        "speech text frontend unavailable: ${error.message ?: error.toString()}",
        error,
    )

    override fun synthesize(input: NeuralSpeechSynthesisInput): Flow<PcmChunk> = flow {
        emit(synthesizeSentence(input))
    }.flowOn(Dispatchers.Default)

    // endregion

    // region Availability and prepare

    private fun check(modelPackage: ModelPackage): NeuralSpeechAvailability {
        val speech = modelPackage.speech
        if (speech == null || speech.pipeline != PIPELINE) {
            return NeuralSpeechAvailability(false, "unsupported pipeline '${speech?.pipeline.orEmpty()}'")
        }
        if (speech.frontend?.assets?.get("config") == null) {
            return NeuralSpeechAvailability(false, "pipeline config missing: speech.frontend.assets.config")
        }
        ROLES.firstOrNull { it !in speech.graphs }?.let { return NeuralSpeechAvailability(false, "graph missing: $it") }
        speech.voices.firstOrNull { it.file == null }?.let {
            return NeuralSpeechAvailability(false, "voice file missing: ${it.id}")
        }
        return NeuralSpeechAvailability(true)
    }

    /**
     * The remembered outcome of the package, else a load. `reload: true` (prepare) loads again after a failed
     * outcome but keeps a ready one; concurrent sentences share one load.
     */
    private suspend fun outcome(modelPackage: ModelPackage, reload: Boolean): Outcome {
        val key = "${modelPackage.id}@${modelPackage.version.orEmpty()}"
        return mutex.withLock {
            current?.takeIf { it.first == key && (!reload || it.second is Outcome.Ready) }?.let { return@withLock it.second }
            load(modelPackage).also { current = key to it }
        }
    }

    private suspend fun load(modelPackage: ModelPackage): Outcome {
        val check = check(modelPackage)
        val speech = modelPackage.speech
        val configFile = speech?.frontend?.assets?.get("config")
        if (!check.available || speech == null || configFile == null) return Outcome.Failed(check.reason ?: "unavailable")
        return try {
            val config = ArticulinoConfig.parse(options.files.read(configFile))
            options.executor.load(speech.graphs.filterKeys { it in ROLES })
            val voices = mutableMapOf<String, Voice>()
            for (voice in speech.voices) {
                val bytes = options.files.read(voice.file.orEmpty())
                try {
                    voices[voice.id] = parseVoice(bytes, config.latentDim)
                } catch (error: VoiceError) {
                    return Outcome.Failed("voice file malformed: ${voice.id}: ${error.why}")
                } catch (error: NeuralSpeechRuntimeError) {
                    val message = error.message.orEmpty()
                    return Outcome.Failed(
                        if (message.startsWith(MALFORMED_PREFIX)) {
                            "$MALFORMED_PREFIX${voice.id}: ${message.removePrefix(MALFORMED_PREFIX)}"
                        } else {
                            "$message (voice '${voice.id}')"
                        },
                    )
                }
            }
            Outcome.Ready(Prepared(config, voices))
        } catch (error: CancellationException) {
            throw error
        } catch (error: NeuralSpeechRuntimeError) {
            Outcome.Failed(error.message.orEmpty())
        } catch (error: Exception) {
            Outcome.Failed(error.message ?: error.toString())
        }
    }

    private fun parseVoice(bytes: ByteArray, latentDim: Int): Voice {
        val file = Safetensors.parse(bytes)
        val format = file.metadata["format"]
        if (format != VOICE_FORMAT) throw VoiceError("unexpected format '${format.orEmpty()}'")
        for ((name, rank) in VOICE_RANKS) {
            val tensor = file.tensors[name] ?: throw VoiceError("missing tensor '$name'")
            if (tensor.data !is SpeechTensorData.F32) throw VoiceError("tensor '$name' is not f32")
            if (tensor.shape.size != rank) throw VoiceError("tensor '$name' has rank ${tensor.shape.size}, expected $rank")
        }
        val promptLatents = file.tensors.getValue("prompt_latents")
        val voiceCache = file.tensors.getValue("voice_cache")
        if (promptLatents.shape[2] != latentDim) {
            throw VoiceError("tensor 'prompt_latents' does not have $latentDim latent channels")
        }
        val letterRates = floats(file.tensors["letter_rate"])
        if (letterRates.size != 1) throw VoiceError("tensor 'letter_rate' is not a scalar")
        val letterRate = letterRates[0]
        if (letterRate != 0f && !(letterRate >= MIN_LETTER_RATE && letterRate <= MAX_LETTER_RATE)) {
            throw VoiceError("letter_rate out of range")
        }
        return Voice(
            voiceTokens = file.tensors.getValue("voice_tokens"),
            voiceVector = file.tensors.getValue("voice_vector"),
            voiceCache = voiceCache,
            promptLatents = promptLatents,
            promptLatentValues = floats(promptLatents),
            letterRate = letterRate,
            promptFrames = voiceCache.shape[4],
        )
    }

    // endregion

    // region Synthesis

    private fun floats(tensor: SpeechTensor?): FloatArray = (tensor?.data as? SpeechTensorData.F32)?.values ?: FloatArray(0)

    private fun internalFailure(message: String, cause: Throwable? = null) = NeuralSpeechRuntimeError(NeuralSpeechRuntimeErrorKind.Internal, "pipeline failed: $message", cause)

    private fun requireFloats(tensor: SpeechTensor?, what: String, role: String): FloatArray = (tensor?.data as? SpeechTensorData.F32)?.values ?: throw internalFailure("$role.$what is not an f32 tensor")

    /**
     * The most frames a piece of [letters] letters can span once config and voice are range-checked: every
     * duration is at most `max(max_duration_units, 100 / letter_rate) / speed`, plus the prompt placeholder;
     * and no tensor of the piece may outgrow [MAX_TENSOR_ELEMENTS].
     */
    private fun maxFrames(letters: Int, promptFrames: Int, lead: Int, stride: Int, config: ArticulinoConfig): Int {
        val perLetter = (maxOf(config.maxDurationUnits, 100f / MIN_LETTER_RATE) / MIN_SPEED).toDouble()
        val byDurations = promptFrames + Math.ceil(letters * perLetter / config.durationUnitsPerFrame) + 1
        val widest = maxOf(config.samplesPerFrame, config.latentDim, stride, 1)
        val byBuffers = promptFrames - lead + MAX_TENSOR_ELEMENTS / widest
        return minOf(byDurations, byBuffers.toDouble()).toInt()
    }

    /** The f32 elements of an output of [role], which must number [count]. */
    private fun requireFloats(tensor: SpeechTensor?, what: String, role: String, count: Int): FloatArray {
        val values = requireFloats(tensor, what, role)
        if (values.size != count) throw internalFailure("$role.$what has ${values.size} elements, expected $count")
        return values
    }

    private suspend fun synthesizeSentence(input: NeuralSpeechSynthesisInput): PcmChunk {
        val prepared = when (val outcome = outcome(input.modelPackage, reload = false)) {
            is Outcome.Ready -> outcome.prepared
            is Outcome.Failed -> throw NeuralSpeechRuntimeError(NeuralSpeechRuntimeErrorKind.Unavailable, outcome.reason)
        }
        val config = prepared.config
        val language = input.locale.split('-', '_').first().lowercase()
        val languageId = config.languages[language]
            ?: throw NeuralSpeechRuntimeError(NeuralSpeechRuntimeErrorKind.Capability, "locale unsupported: ${input.locale}")
        val voice = prepared.voices[input.voiceId]
            ?: throw NeuralSpeechRuntimeError(NeuralSpeechRuntimeErrorKind.Capability, "voice not found: ${input.voiceId}")

        val normalized = ArticulinoMath.normalizeLetters(input.text, config.charset)
        var body = FloatArray(0)
        try {
            val pieces = if (normalized.isEmpty()) emptyList() else ArticulinoMath.splitLongSentence(normalized, options.maxLetters)
            for (piece in pieces) {
                currentCoroutineContext().ensureActive()
                body += synthesizePiece(piece, languageId, config, voice)
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: NeuralSpeechRuntimeError) {
            throw error
        } catch (error: Exception) {
            throw internalFailure(error.message ?: error.toString(), error)
        }
        currentCoroutineContext().ensureActive()
        val padded = ArticulinoMath.padSilence(body, options.pauseMs, config.sampleRate)
        return PcmChunk(ArticulinoMath.toInt16(padded), config.sampleRate, isLast = true)
    }

    /** One piece through the graphs; cancellation is checked before every graph call. */
    private suspend fun synthesizePiece(text: String, languageId: Int, config: ArticulinoConfig, voice: Voice): FloatArray {
        val letters = ArticulinoMath.encodeLetters(text, languageId, config)
        if (letters.ids.isEmpty()) return FloatArray(0)
        val count = letters.ids.size + 1
        val textIds = LongArray(count) { if (it == 0) 0L else letters.ids[it - 1].toLong() }
        val mask = LongArray(count) { if (it == 0) 0L else 1L }
        val languages = LongArray(count) { languageId.toLong() }

        currentCoroutineContext().ensureActive()
        val encoded = options.executor.run(
            "text",
            mapOf(
                "text_ids" to SpeechTensor(listOf(1, count), SpeechTensorData.I64(textIds)),
                "language" to SpeechTensor(listOf(1, count), SpeechTensorData.I64(languages)),
                "text_mask" to SpeechTensor(listOf(1, count), SpeechTensorData.I64(mask)),
                "voice_vector" to voice.voiceVector,
            ),
        )
        val stride = (encoded["text_features"]?.shape?.lastOrNull() ?: 0).coerceAtLeast(0)
        val featureCount = (count.toLong() * stride).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
        val features = requireFloats(encoded["text_features"], "text_features", "text", featureCount)
        val logDurations = requireFloats(encoded["log_durations"], "log_durations", "text", count)

        val units = config.durationUnitsPerFrame
        val d = ArticulinoMath.clampDurations(logDurations, mask, speed, config.maxDurationUnits)
        if (voice.letterRate > 0f) {
            ArticulinoMath.equalizeLetterRate(d, IntArray(count) { textIds[it].toInt() }, config.charset, 1, voice.letterRate * speed)
        }
        d[0] = (units * voice.promptFrames).toFloat()
        if (!d.all { it.isFinite() }) throw internalFailure("text.log_durations yields non-finite durations")
        val lead = minOf(voice.promptLatents.shape[1], config.decoderLeadInFrames)
        val frames = ArticulinoMath.frameCount(d, units)
        val limit = maxFrames(letters.ids.size, voice.promptFrames, lead, stride, config)
        if (frames > limit) throw internalFailure("text.log_durations yields $frames frames, more than $limit")
        val newFrames = frames - voice.promptFrames
        if (newFrames <= 0) return FloatArray(0)
        val condition = ArticulinoMath.frameCondition(features, stride, d, voice.promptFrames, frames, units)
        val frameCond = SpeechTensor(listOf(1, newFrames, stride), SpeechTensorData.F32(condition))

        val latentShape = listOf(1, newFrames, config.latentDim)
        val latentCount = newFrames * config.latentDim
        var x = noise(latentCount)
        var x1 = x
        config.times.forEachIndexed { k, t ->
            currentCoroutineContext().ensureActive()
            val out = options.executor.run(
                "dit_step",
                mapOf(
                    "x" to SpeechTensor(latentShape, SpeechTensorData.F32(x)),
                    "t" to SpeechTensor(listOf(1), SpeechTensorData.F32(floatArrayOf(t))),
                    "frame_cond" to frameCond,
                    "voice_tokens" to voice.voiceTokens,
                    "voice_vector" to voice.voiceVector,
                    "voice_cache" to voice.voiceCache,
                ),
            )
            val hasNext = k + 1 < config.times.size
            val step = ArticulinoMath.flowStep(
                x,
                t,
                requireFloats(out["velocity"], "velocity", "dit_step", latentCount),
                if (hasNext) config.times[k + 1] else null,
                if (hasNext) noise(latentCount) else null,
            )
            x1 = step.x1
            step.next?.let { x = it }
        }

        val prompt = voice.promptLatentValues
        val latents = prompt.copyOfRange(prompt.size - lead * config.latentDim, prompt.size) + x1

        currentCoroutineContext().ensureActive()
        val decoded = options.executor.run(
            "decoder",
            mapOf("latents" to SpeechTensor(listOf(1, lead + newFrames, config.latentDim), SpeechTensorData.F32(latents))),
        )
        val waveform = requireFloats(decoded["waveform"], "waveform", "decoder", (lead + newFrames) * config.samplesPerFrame)
        return ArticulinoMath.shapeWaveform(waveform, lead * config.samplesPerFrame, config)
    }

    // endregion

    private companion object {
        const val PIPELINE = "articulino"
        val ROLES = listOf("text", "dit_step", "decoder")
        const val VOICE_FORMAT = "inderun.articulino.voice/1"
        const val MALFORMED_PREFIX = "voice file malformed: "

        /** The slowest `speed` and the non-zero voice `letter_rate` band the runtime accepts. */
        const val MIN_SPEED = 0.7f
        const val MIN_LETTER_RATE = 1f
        const val MAX_LETTER_RATE = 100f

        /** Largest element count of one tensor a pipeline allocates (the JVM array limit, on every SDK). */
        const val MAX_TENSOR_ELEMENTS = Int.MAX_VALUE
        val VOICE_RANKS = listOf("voice_tokens" to 3, "voice_vector" to 2, "voice_cache" to 6, "prompt_latents" to 3, "letter_rate" to 1)
    }
}
