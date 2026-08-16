package app.independo.inderun.providers.onnx

import ai.onnxruntime.OnnxTensorLike
import ai.onnxruntime.OrtException
import ai.onnxruntime.OrtSession
import kotlinx.coroutines.asCoroutineDispatcher
import java.util.concurrent.Executors

/**
 * Runs ONNX Runtime session creation and `run()` calls on a dedicated single-thread dispatcher
 * rather than [kotlinx.coroutines.Dispatchers.IO]/[kotlinx.coroutines.Dispatchers.Default]:
 * `OrtSession.run()` and session construction are blocking synchronous calls, and sharing them
 * with the general-purpose coroutine pools has no dedicated thread-policy story. A single thread
 * is sufficient -- a single generation is inherently sequential token-by-token -- and gives
 * cancellation-adjacent work one well-defined place to execute, mirroring the Apple member's
 * `OnnxExecutionQueue`.
 */
internal object OnnxExecutionDispatcher {
    val dispatcher = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "inderun-onnx-execution")
    }.asCoroutineDispatcher()
}

/**
 * Runs `session.run(inputs, outputNames)` and wraps any raw [OrtException] (missing/mistyped
 * input, shape mismatch, and similar) into an [OnnxRuntimeError] carrying the original error as
 * detail, rather than letting an opaque native error propagate uncaught up to the provider's
 * generic "execution failed" fallback.
 */
internal fun runOnnxSession(
    session: OrtSession,
    inputs: Map<String, OnnxTensorLike>,
    outputNames: Set<String>,
): OrtSession.Result = try {
    session.run(inputs, outputNames)
} catch (error: OrtException) {
    throw OnnxRuntimeError(
        kind = OnnxRuntimeErrorKind.UNAVAILABLE,
        message = "ONNX Runtime session execution failed.",
        originalError = error,
    )
}
