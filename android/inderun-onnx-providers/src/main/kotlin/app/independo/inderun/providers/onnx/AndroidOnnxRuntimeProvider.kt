package app.independo.inderun.providers.onnx

import android.content.Context
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.MessageRole
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.contracts.Output
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.SourceType
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TaskResultTelemetry
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderAdapter
import app.independo.inderun.core.ProviderDescriptor
import app.independo.inderun.core.ProviderDynamicCapabilities
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.createCapabilityMismatch
import app.independo.inderun.core.createInternal
import app.independo.inderun.core.createTimeout
import app.independo.inderun.core.createUnavailable
import app.independo.inderun.core.toIndeRunException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout

private const val TEXT_TO_TEXT = "text_to_text"

/**
 * Model source types the Android member of the ONNX Runtime provider family can honor, per the
 * support matrix in `docs/architecture/onnx-runtime-provider-family.md`: `registry` and `remote`
 * are deferred everywhere at this stage; Android additionally supports `filesystem` (unlike Web,
 * which cannot read arbitrary local paths).
 */
val supportedAndroidOnnxModelSourceTypes: List<SourceType> = listOf(
    SourceType.Bundled,
    SourceType.Programmatic,
    SourceType.AppManaged,
    SourceType.Filesystem,
)

/**
 * Local provider adapter that executes Mode-1 text-to-text requests with a developer-supplied
 * ONNX model on Android.
 *
 * The adapter owns the IndeRun-facing contract (descriptor, capability checks, error taxonomy) and
 * delegates execution to an injectable [AndroidOnnxGenAiRuntime]. ONNX Runtime execution backends
 * (CPU, NNAPI, XNNPACK) stay behind that seam and are never public routing concepts.
 */
class AndroidOnnxRuntimeProvider(
    private val modelPackage: ModelPackage,
    private val runtime: AndroidOnnxGenAiRuntime,
    private val id: String = DEFAULT_ID,
    private val timeoutMs: Long? = null,
) : ProviderAdapter {

    /** Convenience constructor wiring the default ORT-Mobile-backed runtime. */
    constructor(
        context: Context,
        modelPackage: ModelPackage,
        id: String = DEFAULT_ID,
        timeoutMs: Long? = null,
    ) : this(
        modelPackage = modelPackage,
        runtime = SystemAndroidOnnxGenAiRuntime(context),
        id = id,
        timeoutMs = timeoutMs,
    )

    override fun describe(): ProviderDescriptor = ProviderDescriptor(
        id = id,
        type = ProviderDescriptor.ProviderType.local,
        transport = ProviderDescriptor.TransportType.in_process,
        supports = ProviderDescriptor.SupportsCapabilities(
            run = true,
            streaming = false,
            realtime = false,
            tools = false,
            reasoningEvents = false,
            structuredOutput = false,
            multimodal = false,
        ),
        cancel = ProviderDescriptor.CancelSemantics.soft,
        tasks = declaredTasks(modelPackage),
        privacy = ProviderDescriptor.PrivacyDescriptor(dataLeavesDevice = false),
    )

    /**
     * Reports dynamic provider availability for the current host.
     *
     * Every failure below is provider-internal detail: the shared route planner flattens it into
     * a single `capability_unavailable` rejection carrying the returned reason.
     */
    override suspend fun capabilities(host: HostServices): ProviderDynamicCapabilities {
        val issues = getModelPackageValidationIssues(modelPackage)
        if (issues.isNotEmpty()) {
            val summary = issues.joinToString(separator = "; ") { "${it.path} ${it.message}" }
            return ProviderDynamicCapabilities(available = false, reason = "model package malformed: $summary")
        }

        val sourceType = modelPackage.source?.sourceType
        if (sourceType != null && sourceType !in supportedAndroidOnnxModelSourceTypes) {
            val supported = supportedAndroidOnnxModelSourceTypes.joinToString(separator = ", ") { it.rawValue() }
            val reason = if (sourceType == SourceType.Registry || sourceType == SourceType.Remote) {
                "model source unavailable: '${sourceType.rawValue()}' model sources are deferred on Android; " +
                    "supply model files as $supported."
            } else {
                "model source unavailable: '${sourceType.rawValue()}' model sources are unsupported on Android."
            }
            return ProviderDynamicCapabilities(available = false, reason = reason)
        }

        val platforms = modelPackage.runtime?.platforms
        if (!platforms.isNullOrEmpty() && "android" !in platforms) {
            return ProviderDynamicCapabilities(
                available = false,
                reason = "platform unsupported: the model package targets ${platforms.joinToString(", ")} " +
                    "and does not list 'android'.",
            )
        }

        val tasks = declaredTasks(modelPackage)
        if (TEXT_TO_TEXT !in tasks) {
            return ProviderDynamicCapabilities(
                available = false,
                reason = "unsupported task: the model package declares ${tasks.joinToString(", ")} " +
                    "and does not support '$TEXT_TO_TEXT'.",
            )
        }

        val availability = runtime.prepare(modelPackage)
        return ProviderDynamicCapabilities(available = availability.available, reason = availability.reason)
    }

    /**
     * Executes a normalized text-to-text task on the developer-supplied local ONNX model.
     *
     * @throws IndeRunException mapped to the standard error taxonomy.
     */
    override suspend fun run(request: TaskRequest, context: RunContext): TaskResult {
        val availability = capabilities(context.hostServices)
        if (!availability.available) {
            throw createCapabilityMismatch(
                message = availability.reason ?: "ONNX Runtime Android provider is unavailable on this host.",
                runId = context.runId,
                providerId = id,
            )
        }

        val messages = createMessages(request)
        if (messages.isEmpty()) {
            throw createInternal(
                message = "ONNX Runtime Android provider requires a prompt or messages.",
                runId = context.runId,
                providerId = id,
            )
        }

        val effectiveTimeoutMs = requestTimeoutMs(request) ?: timeoutMs
        val input = AndroidOnnxGenerationInput(modelPackage = modelPackage, messages = messages, generation = request.generation)

        val output = try {
            if (effectiveTimeoutMs != null) {
                withTimeout(effectiveTimeoutMs) { runtime.generate(input) }
            } else {
                runtime.generate(input)
            }
        } catch (timeout: TimeoutCancellationException) {
            throw createTimeout(
                message = "ONNX Runtime Android generation timed out.",
                runId = context.runId,
                providerId = id,
            )
        } catch (cancellation: CancellationException) {
            // Real coroutine cancellation (the caller cancelling its own job, as opposed to the
            // timeout above) propagates raw, uncaught -- it is not normalized into an
            // IndeRunException, matching the established Kotlin-side convention.
            throw cancellation
        } catch (error: Throwable) {
            throw mapRuntimeError(error, context)
        }

        if (output.text.isEmpty()) {
            throw createInternal(
                message = "ONNX Runtime Android provider returned no text output.",
                runId = context.runId,
                providerId = id,
            )
        }

        return TaskResult(
            runId = context.runId,
            schemaVersion = SchemaVersion.V1_0,
            output = Output(text = output.text),
            finishReason = output.finishReason ?: FinishReason.STOP,
            usage = output.usage,
            telemetry = TaskResultTelemetry(providerUsed = id, totalMs = 0.0),
        )
    }

    private fun mapRuntimeError(error: Throwable, context: RunContext): IndeRunException {
        if (error is OnnxRuntimeError) {
            val details = error.originalError?.let {
                mapOf("originalError" to (it.localizedMessage ?: it.toString()))
            }
            return when (error.kind) {
                OnnxRuntimeErrorKind.CAPABILITY -> createCapabilityMismatch(
                    message = error.message ?: "ONNX Runtime Android capability failure.",
                    runId = context.runId,
                    providerId = id,
                    details = details,
                )
                OnnxRuntimeErrorKind.UNAVAILABLE -> createUnavailable(
                    message = error.message ?: "ONNX Runtime Android provider is unavailable.",
                    runId = context.runId,
                    providerId = id,
                    details = details,
                )
                OnnxRuntimeErrorKind.TIMEOUT -> createTimeout(
                    message = error.message ?: "ONNX Runtime Android generation timed out.",
                    runId = context.runId,
                    providerId = id,
                    details = details,
                )
                OnnxRuntimeErrorKind.INTERNAL_FAILURE -> createInternal(
                    message = error.message ?: "ONNX Runtime Android internal failure.",
                    runId = context.runId,
                    providerId = id,
                    details = details,
                )
            }
        }

        if (error is IndeRunException) {
            return toIndeRunException(error, fallbackRunId = context.runId, fallbackProviderId = id)
        }

        return createInternal(
            message = "ONNX Runtime Android provider execution failed.",
            runId = context.runId,
            providerId = id,
            details = mapOf("originalError" to (error.localizedMessage ?: error.toString())),
        )
    }

    companion object {
        /** Default provider id of the Android member of the ONNX Runtime provider family. */
        const val DEFAULT_ID = "local.onnx.genai.android"
    }
}

private fun declaredTasks(modelPackage: ModelPackage): List<String> {
    val tasks = modelPackage.tasks
    return if (tasks.isNullOrEmpty()) listOf(TEXT_TO_TEXT) else tasks
}

private fun createMessages(request: TaskRequest): List<AndroidOnnxGenerationMessage> {
    val messages = request.messages
    if (!messages.isNullOrEmpty()) {
        return messages.map { AndroidOnnxGenerationMessage(role = it.role, content = it.content) }
    }

    val prompt = request.prompt
    if (prompt.isNullOrEmpty()) return emptyList()
    return listOf(AndroidOnnxGenerationMessage(role = MessageRole.USER, content = prompt))
}

private fun requestTimeoutMs(request: TaskRequest): Long? {
    val timeoutMs = request.constraints?.timeoutMs
    return if (timeoutMs != null && timeoutMs > 0) timeoutMs else null
}

private fun SourceType.rawValue(): String = when (this) {
    SourceType.AppManaged -> "app_managed"
    SourceType.Bundled -> "bundled"
    SourceType.Filesystem -> "filesystem"
    SourceType.Programmatic -> "programmatic"
    SourceType.Registry -> "registry"
    SourceType.Remote -> "remote"
}
