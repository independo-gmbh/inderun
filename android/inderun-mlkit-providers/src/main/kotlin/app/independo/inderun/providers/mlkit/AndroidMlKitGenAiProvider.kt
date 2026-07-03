package app.independo.inderun.providers.mlkit

import android.content.Context
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.Output
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TaskResultTelemetry
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderAdapter
import app.independo.inderun.core.ProviderDescriptor
import app.independo.inderun.core.ProviderDynamicCapabilities
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.createCapabilityMismatch
import app.independo.inderun.core.createInternal
import app.independo.inderun.core.toIndeRunException
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.TextPart
import com.google.mlkit.genai.prompt.generateContentRequest

sealed interface AndroidMlKitGenAiAvailability {
    data object Available : AndroidMlKitGenAiAvailability
    data class Downloadable(val reason: String) : AndroidMlKitGenAiAvailability
    data class Downloading(val reason: String) : AndroidMlKitGenAiAvailability
    data class Unavailable(val reason: String) : AndroidMlKitGenAiAvailability
}

data class AndroidMlKitGenAiGenerationOptions(
    val maxOutputTokens: Long? = null,
    val temperature: Double? = null,
    val seed: Long? = null,
)

interface AndroidMlKitGenAiRuntime {
    suspend fun availability(): AndroidMlKitGenAiAvailability
    suspend fun generateText(prompt: String, options: AndroidMlKitGenAiGenerationOptions): String
}

class AndroidMlKitGenAiProvider internal constructor(
    private val id: String,
    private val runtime: AndroidMlKitGenAiRuntime,
) : ProviderAdapter {

    constructor(id: String = DEFAULT_ID) : this(
        id = id,
        runtime = SystemAndroidMlKitGenAiRuntime(),
    )

    override fun describe(): ProviderDescriptor = ProviderDescriptor(
        id = id,
        type = ProviderDescriptor.ProviderType.local,
        transport = ProviderDescriptor.TransportType.system_service,
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
        tasks = listOf("text_to_text"),
        privacy = ProviderDescriptor.PrivacyDescriptor(dataLeavesDevice = false),
    )

    override suspend fun capabilities(host: HostServices): ProviderDynamicCapabilities = when (val availability = runtime.availability()) {
        AndroidMlKitGenAiAvailability.Available -> ProviderDynamicCapabilities(available = true)
        is AndroidMlKitGenAiAvailability.Downloadable -> ProviderDynamicCapabilities(
            available = false,
            reason = availability.reason,
        )
        is AndroidMlKitGenAiAvailability.Downloading -> ProviderDynamicCapabilities(
            available = false,
            reason = availability.reason,
        )
        is AndroidMlKitGenAiAvailability.Unavailable -> ProviderDynamicCapabilities(
            available = false,
            reason = availability.reason,
        )
    }

    override suspend fun run(request: TaskRequest, context: RunContext): TaskResult = when (val availability = runtime.availability()) {
        AndroidMlKitGenAiAvailability.Available -> executeAvailableRequest(request, context)
        is AndroidMlKitGenAiAvailability.Downloadable -> throw createCapabilityMismatch(
            message = "Android ML Kit GenAI provider is not ready: ${availability.reason}",
            runId = context.runId,
            providerId = id,
            details = mapOf("availability" to "downloadable"),
        )
        is AndroidMlKitGenAiAvailability.Downloading -> throw createCapabilityMismatch(
            message = "Android ML Kit GenAI provider is not ready: ${availability.reason}",
            runId = context.runId,
            providerId = id,
            details = mapOf("availability" to "downloading"),
        )
        is AndroidMlKitGenAiAvailability.Unavailable -> throw createCapabilityMismatch(
            message = "Android ML Kit GenAI provider is unavailable: ${availability.reason}",
            runId = context.runId,
            providerId = id,
            details = mapOf("availability" to availability.reason),
        )
    }

    private suspend fun executeAvailableRequest(
        request: TaskRequest,
        context: RunContext,
    ): TaskResult {
        try {
            val startTime = context.hostServices.clock.elapsedRealtimeMillis()
            val outputText = runtime.generateText(
                prompt = normalizedPrompt(request),
                options = AndroidMlKitGenAiGenerationOptions(
                    maxOutputTokens = request.generation?.maxOutputTokens,
                    temperature = request.generation?.temperature,
                    seed = request.generation?.seed,
                ),
            )
            val duration = context.hostServices.clock.elapsedRealtimeMillis() - startTime

            return TaskResult(
                finishReason = FinishReason.STOP,
                output = Output(text = outputText),
                runId = context.runId,
                schemaVersion = SchemaVersion.V1_0,
                telemetry = TaskResultTelemetry(providerUsed = id, totalMs = duration.toDouble()),
            )
        } catch (error: Throwable) {
            if (error is IndeRunException) {
                throw toIndeRunException(error, fallbackRunId = context.runId, fallbackProviderId = id)
            }

            throw createInternal(
                message = "Android ML Kit GenAI execution failed.",
                runId = context.runId,
                providerId = id,
                details = mapOf("originalError" to (error.localizedMessage ?: error.toString())),
            )
        }
    }

    private fun normalizedPrompt(request: TaskRequest): String {
        val messages = request.messages
        if (!messages.isNullOrEmpty()) {
            return messages.joinToString(separator = "\n") { message ->
                "${message.role.rawValue}: ${message.content}"
            }
        }

        return request.prompt.orEmpty()
    }

    companion object {
        const val DEFAULT_ID = "android_mlkit_genai"
    }
}

object AndroidProviderRegistryFactory {
    fun makeDefaultRegistry(context: Context): ProviderRegistry {
        val registry = ProviderRegistry()
        registry.register(
            AndroidMlKitGenAiProvider(
                id = AndroidMlKitGenAiProvider.DEFAULT_ID,
                runtime = SystemAndroidMlKitGenAiRuntime(context),
            ),
        )
        return registry
    }
}

private class SystemAndroidMlKitGenAiRuntime(
    @Suppress("UNUSED_PARAMETER") private val context: Context? = null,
) : AndroidMlKitGenAiRuntime {
    private val generativeModel = Generation.getClient()

    override suspend fun availability(): AndroidMlKitGenAiAvailability = try {
        when (generativeModel.checkStatus()) {
            FeatureStatus.AVAILABLE -> AndroidMlKitGenAiAvailability.Available
            FeatureStatus.DOWNLOADABLE -> AndroidMlKitGenAiAvailability.Downloadable(
                "Gemini Nano can be downloaded on this device, but is not currently installed.",
            )
            FeatureStatus.DOWNLOADING -> AndroidMlKitGenAiAvailability.Downloading(
                "Gemini Nano is currently downloading.",
            )
            FeatureStatus.UNAVAILABLE -> AndroidMlKitGenAiAvailability.Unavailable(
                "Gemini Nano is unsupported on this device or AICore is not ready.",
            )
            else -> AndroidMlKitGenAiAvailability.Unavailable(
                "ML Kit returned an unknown availability status.",
            )
        }
    } catch (error: Throwable) {
        AndroidMlKitGenAiAvailability.Unavailable(
            error.localizedMessage ?: "Failed to query ML Kit GenAI availability.",
        )
    }

    override suspend fun generateText(
        prompt: String,
        options: AndroidMlKitGenAiGenerationOptions,
    ): String {
        val response = generativeModel.generateContent(
            generateContentRequest(TextPart(prompt)) {
                temperature = options.temperature?.toFloat()
                seed = options.seed?.toInt()
                maxOutputTokens = options.maxOutputTokens?.toInt()
            },
        )

        return response.candidates.firstOrNull()?.text.orEmpty()
    }
}
