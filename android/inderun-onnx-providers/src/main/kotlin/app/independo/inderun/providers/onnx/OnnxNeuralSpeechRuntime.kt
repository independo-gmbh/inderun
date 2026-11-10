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
import app.independo.inderun.providers.neuralspeech.RUNTIME_CLOSED_CODE
import app.independo.inderun.providers.neuralspeech.SpeechGraphExecutor
import app.independo.inderun.providers.neuralspeech.SpeechPackageFiles
import app.independo.inderun.providers.neuralspeech.SpeechTensor
import app.independo.inderun.providers.neuralspeech.articulino.ArticulinoRuntime
import app.independo.inderun.providers.neuralspeech.articulino.ArticulinoRuntimeOptions
import app.independo.inderun.providers.neuralspeech.articulino.NoiseSource
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

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
 *
 * [close] returns at once: it marks the runtime closed, drops the cached pipelines and closes each
 * executor, whose sessions are released on the ONNX execution thread after the graph call in flight
 * (see [OnnxSpeechGraphExecutor]). Nothing is created after it, and a synthesis cut short by it
 * fails with `runtime_closed` (see [NeuralSpeechRuntime.close]).
 */
class OnnxNeuralSpeechRuntime internal constructor(
    private val context: Context,
    private val options: OnnxNeuralSpeechRuntimeOptions,
    private val executorFactory: (directory: File, threads: Int?) -> SpeechGraphExecutor,
    private val pipelineFactory: (executor: SpeechGraphExecutor, directory: File) -> NeuralSpeechRuntime,
) : NeuralSpeechRuntime {
    constructor(
        context: Context,
        options: OnnxNeuralSpeechRuntimeOptions = OnnxNeuralSpeechRuntimeOptions(),
    ) : this(
        context,
        options,
        { directory, threads -> OnnxSpeechGraphExecutor(directory, threads) },
        { executor, directory ->
            ArticulinoRuntime(
                ArticulinoRuntimeOptions(
                    executor = executor,
                    files = DirectoryPackageFiles(directory),
                    noise = options.noise,
                    speed = options.speed,
                    pauseMs = options.pauseMs,
                ),
            )
        },
    )

    private sealed interface Resolution {
        class Ready(val runtime: NeuralSpeechRuntime) : Resolution

        class Refused(val availability: NeuralSpeechAvailability) : Resolution
    }

    private val directories = OnnxModelDirectory(context)
    private val lock = Any()
    private val closed = AtomicBoolean(false)
    private val runtimes = HashMap<String, NeuralSpeechRuntime>()
    private val cachedExecutors = ArrayList<LifecycleExecutor>()

    override fun close() {
        val toClose = synchronized(lock) {
            if (!closed.compareAndSet(false, true)) return
            runtimes.clear()
            cachedExecutors.toList().also { cachedExecutors.clear() }
        }
        // Each executor releases its sessions on the execution thread, behind a graph call in flight.
        toClose.forEach { runCatching { it.close() } }
    }

    override suspend fun availability(modelPackage: ModelPackage): NeuralSpeechAvailability = when (val resolution = resolve(modelPackage, verify = false, extract = false)) {
        is Resolution.Ready -> resolution.runtime.availability(modelPackage)
        is Resolution.Refused -> resolution.availability
    }

    override suspend fun prepare(modelPackage: ModelPackage): NeuralSpeechAvailability {
        if (closed.get()) throw closedError()
        return when (val resolution = resolve(modelPackage, verify = true, extract = true)) {
            is Resolution.Ready -> resolution.runtime.prepare(modelPackage).also { if (closed.get()) throw closedError() }
            is Resolution.Refused -> if (closed.get()) throw closedError() else resolution.availability
        }
    }

    override fun synthesize(input: NeuralSpeechSynthesisInput): Flow<PcmChunk> = flow {
        if (closed.get()) throw closedError()
        when (val resolution = resolve(input.modelPackage, verify = false, extract = true)) {
            is Resolution.Refused -> throw if (closed.get()) {
                closedError()
            } else {
                NeuralSpeechRuntimeError(NeuralSpeechRuntimeErrorKind.Unavailable, resolution.availability.reason ?: "unavailable")
            }
            is Resolution.Ready -> {
                var lastDelivered = false
                try {
                    resolution.runtime.synthesize(input)
                        // Only failures of the pipeline flow: `catch` never sees the collector's own.
                        .catch { error ->
                            // The released graphs surface as an internal failure; to the caller the close is the cause.
                            if (!closed.get()) throw error
                            if (!lastDelivered) throw closedError()
                        }
                        .collect {
                            // A chunk computed before the close is not delivered unless it ends the sentence.
                            if (closed.get() && !it.isLast) throw closedError()
                            emit(it)
                            if (it.isLast) lastDelivered = true
                        }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                }
            }
        }
    }

    /** The Articulino pipeline's text hook; no model is loaded for it. Other pipelines get the text unchanged. */
    override fun normalizeText(modelPackage: ModelPackage, text: String, locale: String): String = if (!closed.get() && modelPackage.speech?.pipeline == "articulino") {
        ARTICULINO_TEXT.normalizeText(modelPackage, text, locale)
    } else {
        text
    }

    private suspend fun resolve(modelPackage: ModelPackage, verify: Boolean, extract: Boolean): Resolution {
        if (closed.get()) return Resolution.Refused(CLOSED)
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
        val runtime = synchronized(lock) {
            // Checked under the lock close() takes, so no executor is created after it.
            if (closed.get()) return Resolution.Refused(CLOSED)
            runtimes.getOrPut(key) {
                val executor = LifecycleExecutor(executorFactory(directory, options.threads))
                cachedExecutors += executor
                pipelineFactory(executor, directory)
            }
        }
        return Resolution.Ready(runtime)
    }

    /** `ActivityManager.MemoryInfo.totalMem`, or null when the service is unavailable. */
    private fun totalDeviceMemory(): Long? {
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return null
        return ActivityManager.MemoryInfo().also { manager.getMemoryInfo(it) }.totalMem
    }

    /**
     * Guards an executor against a close racing its calls: [close] releases the delegate only once
     * no [load] or [run] is in flight, so a model is never released under a running graph and a
     * load that finishes after the close does not leave sessions behind. A call that starts or
     * finishes after the close fails with `runtime_closed`.
     */
    private class LifecycleExecutor(private val delegate: SpeechGraphExecutor) : SpeechGraphExecutor {
        private val lock = Any()
        private var inFlight = 0
        private var closed = false
        private var released = false

        private fun enter() = synchronized(lock) {
            if (closed) throw closedError()
            inFlight += 1
        }

        private fun exit() {
            val release = synchronized(lock) {
                inFlight -= 1
                (closed && inFlight == 0 && !released).also { if (it) released = true }
            }
            if (release) delegate.close()
        }

        override suspend fun load(graphs: Map<String, String>) {
            enter()
            try {
                delegate.load(graphs)
            } finally {
                exit()
            }
            if (synchronized(lock) { closed }) throw closedError()
        }

        override suspend fun run(role: String, inputs: Map<String, SpeechTensor>): Map<String, SpeechTensor> {
            enter()
            try {
                return delegate.run(role, inputs)
            } finally {
                exit()
            }
        }

        override fun close() {
            val release = synchronized(lock) {
                closed = true
                (inFlight == 0 && !released).also { if (it) released = true }
            }
            if (release) delegate.close()
        }
    }

    private companion object {
        val CLOSED = NeuralSpeechAvailability(false, CLOSED_REASON)

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

private const val CLOSED_REASON = "runtime closed"

private fun closedError() = NeuralSpeechRuntimeError(NeuralSpeechRuntimeErrorKind.Unavailable, CLOSED_REASON, code = RUNTIME_CLOSED_CODE)
