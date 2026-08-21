package app.independo.inderun.providers.onnx

import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.Generation
import app.independo.inderun.contracts.MessageRole
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.contracts.TaskResultUsage

/**
 * Availability snapshot reported by an ONNX text generation runtime.
 *
 * The `reason` string uses the provider-internal capability vocabulary documented in
 * `docs/architecture/onnx-runtime-provider-family.md`. It is not a public enum: the provider
 * flattens every failure into a single `capability_unavailable` route rejection and carries the
 * reason as human-readable text.
 */
data class AndroidOnnxRuntimeAvailability(
    val available: Boolean,
    val reason: String? = null,
)

/** Normalized conversation turn handed to an ONNX text generation runtime. */
data class AndroidOnnxGenerationMessage(
    val role: MessageRole,
    val content: String,
)

/** Normalized generation request handed to an ONNX text generation runtime. */
data class AndroidOnnxGenerationInput(
    val modelPackage: ModelPackage,
    val messages: List<AndroidOnnxGenerationMessage>,
    val generation: Generation? = null,
)

/** Normalized generation result returned by an ONNX text generation runtime. */
data class AndroidOnnxGenerationOutput(
    val text: String,
    val finishReason: FinishReason? = null,
    val usage: TaskResultUsage? = null,
)

/**
 * Failure category a runtime can signal so the provider maps it onto the IndeRun error taxonomy.
 *
 * - [CAPABILITY]: model or runtime cannot serve this request (`CapabilityMismatch`).
 * - [UNAVAILABLE]: runtime initialization failure or resource exhaustion (`Unavailable`).
 * - [TIMEOUT]: generation exceeded its budget (`Timeout`).
 * - [INTERNAL_FAILURE]: unexpected runtime failure (`Internal`).
 */
enum class OnnxRuntimeErrorKind {
    CAPABILITY,
    UNAVAILABLE,
    TIMEOUT,
    INTERNAL_FAILURE,
}

/**
 * Error type ONNX runtime implementations throw to steer IndeRun error normalization.
 *
 * Anything else thrown by a runtime is normalized to `Internal`.
 */
class OnnxRuntimeError(
    val kind: OnnxRuntimeErrorKind,
    message: String,
    val originalError: Throwable? = null,
) : Exception(message, originalError)

/**
 * Injectable seam between the IndeRun Android ONNX provider and the actual on-device runtime.
 *
 * IndeRun ships a default runtime backed by ONNX Runtime Mobile
 * (`com.microsoft.onnxruntime:onnxruntime-android`) plus a Hugging Face tokenizer, and a
 * deterministic fixture for tests and demos. Applications can supply their own implementation
 * without touching the provider.
 */
interface AndroidOnnxGenAiRuntime {
    /** Checks runtime package availability, execution backend availability, and model readiness.
     * Implementations must resolve with an availability snapshot rather than throwing. */
    suspend fun prepare(modelPackage: ModelPackage): AndroidOnnxRuntimeAvailability

    /** Runs one Mode-1 generation. */
    suspend fun generate(input: AndroidOnnxGenerationInput): AndroidOnnxGenerationOutput
}
