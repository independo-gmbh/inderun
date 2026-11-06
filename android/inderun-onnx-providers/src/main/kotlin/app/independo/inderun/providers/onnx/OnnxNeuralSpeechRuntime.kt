package app.independo.inderun.providers.onnx

import android.app.ActivityManager
import android.content.Context
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.providers.neuralspeech.DirectoryPackageFiles
import app.independo.inderun.providers.neuralspeech.NeuralSpeechAvailability
import app.independo.inderun.providers.neuralspeech.NeuralSpeechRuntime
import app.independo.inderun.providers.neuralspeech.NeuralSpeechRuntimeError
import app.independo.inderun.providers.neuralspeech.NeuralSpeechRuntimeErrorKind
import app.independo.inderun.providers.neuralspeech.NeuralSpeechSynthesisInput
import app.independo.inderun.providers.neuralspeech.PcmChunk
import app.independo.inderun.providers.neuralspeech.SpeechGraphExecutor
import app.independo.inderun.providers.neuralspeech.SpeechPackageFiles
import app.independo.inderun.providers.neuralspeech.SpeechTensor
import app.independo.inderun.providers.neuralspeech.articulino.ArticulinoRuntime
import app.independo.inderun.providers.neuralspeech.articulino.ArticulinoRuntimeOptions
import app.independo.inderun.providers.neuralspeech.articulino.NoiseSource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Options of an [OnnxNeuralSpeechRuntime].
 *
 * @property threads ONNX Runtime intra-op threads; default `min(4, availableProcessors)`.
 * @property noise Default: Box-Muller over the platform random number generator.
 * @property speed Clamped to 0.7..1.6.
 * @property pauseMs Silence appended after each sentence.
 * @property deviceMemoryBytes The device memory `limits.memBytes` is compared with; default
 *   `ActivityManager.MemoryInfo.totalMem`.
 */
data class OnnxNeuralSpeechRuntimeOptions(
    val threads: Int? = null,
    val noise: NoiseSource? = null,
    val speed: Float = 1.0f,
    val pauseMs: Int = 150,
    val deviceMemoryBytes: (() -> Long)? = null,
)

/**
 * The [NeuralSpeechRuntime] for neural speech packages on Android: resolves the package directory
 * (`filesystem`, `bundled` or `app_managed` sources), checks the declared checksums at `prepare`,
 * and runs the Articulino pipeline through ONNX Runtime. One pipeline runtime is built and cached
 * per package id and version. A package whose `limits.memBytes` exceeds the device's total memory is
 * refused at `availability`, `prepare` and `synthesize`, before anything loads. A bundled source is
 * extracted by `prepare` (or a `synthesize` that loads), never by `availability`.
 */
class OnnxNeuralSpeechRuntime(
    private val context: Context,
    private val options: OnnxNeuralSpeechRuntimeOptions = OnnxNeuralSpeechRuntimeOptions(),
) : NeuralSpeechRuntime {
    private sealed interface Resolution {
        class Ready(val runtime: ArticulinoRuntime) : Resolution

        class Refused(val availability: NeuralSpeechAvailability) : Resolution
    }

    private val directories = OnnxModelDirectory(context)
    private val mutex = Mutex()
    private val runtimes = HashMap<String, ArticulinoRuntime>()

    override suspend fun availability(modelPackage: ModelPackage): NeuralSpeechAvailability = when (val resolution = resolve(modelPackage, verify = false, extract = false)) {
        is Resolution.Ready -> resolution.runtime.availability(modelPackage)
        is Resolution.Refused -> resolution.availability
    }

    override suspend fun prepare(modelPackage: ModelPackage): NeuralSpeechAvailability = when (val resolution = resolve(modelPackage, verify = true, extract = true)) {
        is Resolution.Ready -> resolution.runtime.prepare(modelPackage)
        is Resolution.Refused -> resolution.availability
    }

    override fun synthesize(input: NeuralSpeechSynthesisInput): Flow<PcmChunk> = flow {
        when (val resolution = resolve(input.modelPackage, verify = false, extract = true)) {
            is Resolution.Refused -> throw NeuralSpeechRuntimeError(
                NeuralSpeechRuntimeErrorKind.Unavailable,
                resolution.availability.reason ?: "unavailable",
            )
            is Resolution.Ready -> resolution.runtime.synthesize(input).collect { emit(it) }
        }
    }

    /** The Articulino pipeline's text hook; no model is loaded for it. Other pipelines get the text unchanged. */
    override fun normalizeText(modelPackage: ModelPackage, text: String, locale: String): String = if (modelPackage.speech?.pipeline == "articulino") {
        ARTICULINO_TEXT.normalizeText(modelPackage, text, locale)
    } else {
        text
    }

    private suspend fun resolve(modelPackage: ModelPackage, verify: Boolean, extract: Boolean): Resolution {
        val pipeline = modelPackage.speech?.pipeline
        if (pipeline != "articulino") {
            return Resolution.Refused(NeuralSpeechAvailability(false, "unsupported pipeline '${pipeline.orEmpty()}'"))
        }
        val needed = modelPackage.limits?.memBytes
        if (needed != null && needed > 0) {
            val device = options.deviceMemoryBytes?.invoke() ?: totalDeviceMemory()
            if (device != null && needed > device) {
                return Resolution.Refused(
                    NeuralSpeechAvailability(false, "insufficient memory: package needs $needed bytes, device has $device bytes"),
                )
            }
        }
        val sourceType = modelPackage.source?.sourceType
            ?: return Resolution.Refused(NeuralSpeechAvailability(false, "model source unavailable: no model source was configured."))
        val key = "${modelPackage.id}:${modelPackage.version.orEmpty()}"
        val directory = try {
            // Extracting a bundled source is blocking file work.
            withContext(Dispatchers.IO) {
                directories.resolve(modelPackage, sourceType, key, extract).also {
                    if (verify) directories.verifyChecksums(it, modelPackage)
                }
            }
        } catch (error: OnnxRuntimeError) {
            return Resolution.Refused(NeuralSpeechAvailability(false, error.message))
        }
        val runtime = mutex.withLock {
            runtimes.getOrPut(key) {
                ArticulinoRuntime(
                    ArticulinoRuntimeOptions(
                        executor = OnnxSpeechGraphExecutor(directory, options.threads),
                        files = DirectoryPackageFiles(directory),
                        noise = options.noise,
                        speed = options.speed,
                        pauseMs = options.pauseMs,
                    ),
                )
            }
        }
        return Resolution.Ready(runtime)
    }

    /** `ActivityManager.MemoryInfo.totalMem`, or null when the service is unavailable. */
    private fun totalDeviceMemory(): Long? {
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return null
        return ActivityManager.MemoryInfo().also { manager.getMemoryInfo(it) }.totalMem
    }

    private companion object {
        /** Stateless for [ArticulinoRuntime.normalizeText]: it never touches the executor or the files. */
        val ARTICULINO_TEXT = ArticulinoRuntime(ArticulinoRuntimeOptions(executor = NoGraphs, files = NoFiles))
    }
}

private object NoGraphs : SpeechGraphExecutor {
    override suspend fun load(graphs: Map<String, String>) = error("not used")

    override suspend fun run(role: String, inputs: Map<String, SpeechTensor>): Map<String, SpeechTensor> = error("not used")

    override fun close() = Unit
}

private object NoFiles : SpeechPackageFiles {
    override suspend fun read(file: String): ByteArray = error("not used")
}
