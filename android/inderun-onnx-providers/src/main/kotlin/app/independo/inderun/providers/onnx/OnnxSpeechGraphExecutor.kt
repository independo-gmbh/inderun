package app.independo.inderun.providers.onnx

import ai.onnxruntime.OnnxJavaType
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtException
import ai.onnxruntime.OrtSession
import app.independo.inderun.providers.neuralspeech.NeuralSpeechRuntimeError
import app.independo.inderun.providers.neuralspeech.NeuralSpeechRuntimeErrorKind
import app.independo.inderun.providers.neuralspeech.SpeechGraphExecutor
import app.independo.inderun.providers.neuralspeech.SpeechTensor
import app.independo.inderun.providers.neuralspeech.SpeechTensorData
import app.independo.inderun.providers.neuralspeech.checkPackageFileName
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** A loaded graph with its session options, which must outlive the session. */
private class LoadedSpeechGraph(val session: OrtSession, val options: OrtSession.SessionOptions) {
    val outputNames: Set<String> = session.outputNames

    fun close() {
        session.close()
        options.close()
    }
}

/**
 * Runs the graphs of a speech model package through ONNX Runtime, on the CPU execution provider
 * only. Sessions are created and run on [OnnxExecutionDispatcher], one per role, so graph calls
 * are serialized; intra-op spinning is off, so the worker threads sleep between graph calls. The
 * tensors are f32 or i64 only (see [SpeechTensor]); a graph output of any other element type is
 * refused. No ONNX Runtime type appears in this class's signatures.
 *
 * [load] replaces the loaded graphs and [close] drops them. A run looks its session up on the
 * dispatcher and the dropped sessions are closed there too, after the swap, so a session is never
 * closed while a run uses it.
 *
 * @param threads ONNX Runtime intra-op threads; default `min(4, availableProcessors)`.
 */
class OnnxSpeechGraphExecutor(private val directory: File, threads: Int? = null) : SpeechGraphExecutor {
    private val threads: Int = (threads ?: minOf(4, Runtime.getRuntime().availableProcessors())).coerceAtLeast(1)
    private val lock = Any()
    private var graphs: Map<String, LoadedSpeechGraph> = emptyMap()

    override suspend fun load(graphs: Map<String, String>) {
        val loaded = LinkedHashMap<String, LoadedSpeechGraph>()
        try {
            for ((role, file) in graphs.toSortedMap()) {
                loaded[role] = withContext(OnnxExecutionDispatcher.dispatcher) { createGraph(role, file) }
            }
        } catch (error: Throwable) {
            loaded.values.forEach { it.close() }
            throw error
        }
        val previous = synchronized(lock) { this.graphs.also { this.graphs = loaded } }
        if (previous.isEmpty()) return
        // The dispatcher is single-threaded and every run reads its session on it (see [run]), so a run
        // that saw a replaced session has returned before this task starts; NonCancellable so they are
        // closed even when the caller is cancelled now.
        withContext(NonCancellable + OnnxExecutionDispatcher.dispatcher) { previous.values.forEach { it.close() } }
    }

    override suspend fun run(role: String, inputs: Map<String, SpeechTensor>): Map<String, SpeechTensor> = withContext(OnnxExecutionDispatcher.dispatcher) {
        val graph = synchronized(lock) { graphs[role] }
            ?: throw NeuralSpeechRuntimeError(NeuralSpeechRuntimeErrorKind.Internal, "graph not loaded: $role")
        runGraph(role, graph, inputs)
    }

    override fun close() {
        val previous = synchronized(lock) { graphs.also { graphs = emptyMap() } }
        closeOnExecutionThread(previous.values.map { graph -> { graph.close() } })
    }

    private fun createGraph(role: String, file: String): LoadedSpeechGraph {
        try {
            checkPackageFileName(file)
            val path = File(directory, file)
            if (!path.exists()) throw NeuralSpeechRuntimeError(NeuralSpeechRuntimeErrorKind.Unavailable, "model files missing: $file")
            val options = OrtSession.SessionOptions()
            try {
                options.setIntraOpNumThreads(threads)
                options.addConfigEntry("session.intra_op.allow_spinning", "0")
                return LoadedSpeechGraph(OrtEnvironment.getEnvironment().createSession(path.absolutePath, options), options)
            } catch (error: Throwable) {
                options.close()
                throw error
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            val message = (error as? NeuralSpeechRuntimeError)?.message ?: error.message ?: error.toString()
            throw NeuralSpeechRuntimeError(NeuralSpeechRuntimeErrorKind.Unavailable, "graph failed to load: $role: $message", error)
        }
    }

    private fun runGraph(role: String, graph: LoadedSpeechGraph, inputs: Map<String, SpeechTensor>): Map<String, SpeechTensor> {
        val environment = OrtEnvironment.getEnvironment()
        val tensors = ArrayList<OnnxTensor>(inputs.size)
        try {
            val named = LinkedHashMap<String, OnnxTensor>()
            for ((name, tensor) in inputs) named[name] = createTensor(environment, tensor).also { tensors += it }
            graph.session.run(named, graph.outputNames).use { return copyOutputs(role, it) }
        } catch (error: NeuralSpeechRuntimeError) {
            throw error
        } catch (error: OrtException) {
            throw NeuralSpeechRuntimeError(
                NeuralSpeechRuntimeErrorKind.Unavailable,
                "graph failed: $role: ${error.message ?: error}",
                error,
            )
        } finally {
            tensors.forEach { it.close() }
        }
    }

    private fun copyOutputs(role: String, result: OrtSession.Result): Map<String, SpeechTensor> {
        val outputs = LinkedHashMap<String, SpeechTensor>()
        for (entry in result) {
            val name = entry.key
            val unsupported = { NeuralSpeechRuntimeError(NeuralSpeechRuntimeErrorKind.Internal, "graph output unsupported: $role.$name") }
            val tensor = entry.value as? OnnxTensor ?: throw unsupported()
            val shape = tensor.info.shape.map { it.toInt() }
            outputs[name] = when (tensor.info.type) {
                OnnxJavaType.FLOAT -> {
                    val buffer = tensor.floatBuffer
                    val values = FloatArray(buffer.remaining())
                    buffer.get(values)
                    SpeechTensor(shape, SpeechTensorData.F32(values))
                }
                OnnxJavaType.INT64 -> {
                    val buffer = tensor.longBuffer
                    val values = LongArray(buffer.remaining())
                    buffer.get(values)
                    SpeechTensor(shape, SpeechTensorData.I64(values))
                }
                else -> throw unsupported()
            }
        }
        return outputs
    }

    private fun createTensor(environment: OrtEnvironment, tensor: SpeechTensor): OnnxTensor {
        val shape = LongArray(tensor.shape.size) { tensor.shape[it].toLong() }
        return when (val data = tensor.data) {
            is SpeechTensorData.F32 -> {
                val buffer = direct(data.values.size * Float.SIZE_BYTES).asFloatBuffer().put(data.values).also { it.rewind() }
                OnnxTensor.createTensor(environment, buffer, shape)
            }
            is SpeechTensorData.I64 -> {
                val buffer = direct(data.values.size * Long.SIZE_BYTES).asLongBuffer().put(data.values).also { it.rewind() }
                OnnxTensor.createTensor(environment, buffer, shape)
            }
        }
    }

    private fun direct(bytes: Int): ByteBuffer = ByteBuffer.allocateDirect(bytes).order(ByteOrder.nativeOrder())
}
