package com.independo.inderun.sdk

import android.content.Context
import com.independo.inderun.contracts.SchemaVersion
import com.independo.inderun.contracts.TaskKind
import com.independo.inderun.contracts.TaskRequest
import com.independo.inderun.contracts.TaskResult
import com.independo.inderun.core.HostServices
import com.independo.inderun.core.HostServicesFactory
import com.independo.inderun.core.ProviderRegistry
import com.independo.inderun.core.Router
import com.independo.inderun.core.RunContext
import com.independo.inderun.core.createInternal
import com.independo.inderun.core.toIndeRunException
import com.independo.inderun.providers.mlkit.AndroidProviderRegistryFactory
import java.util.UUID

/**
 * The primary entry point for the IndeRun Android SDK.
 *
 * This class provides access to all platform-specific [HostServices] required
 * by the IndeRun engine, such as connectivity, secure storage, time, and
 * provider-backed execution.
 */
class IndeRun private constructor(
    private val hostServices: HostServices,
    private val registry: ProviderRegistry
) {
    private val router = Router(registry)

    /** Accessor for connectivity information. */
    val connectivity = hostServices.connectivity

    /** Accessor for secure credential/secret storage. */
    val secureStorage = hostServices.secureStorage

    /** Accessor for the system clock. */
    val clock = hostServices.clock

    suspend fun run(request: TaskRequest): TaskResult {
        val startTime = clock.elapsedRealtimeMillis().toDouble()
        val runId = request.requestId ?: "run_${UUID.randomUUID().toString().take(8).lowercase()}"

        try {
            validateRequest(request, runId)

            val routeSelection = router.selectRoute(request, hostServices)
            val provider = routeSelection.provider

            val result = try {
                provider.run(
                    request = request,
                    context = RunContext(runId = runId, hostServices = hostServices)
                )
            } catch (error: Throwable) {
                throw toIndeRunException(
                    error,
                    fallbackRunId = runId,
                    fallbackProviderId = provider.describe().id
                )
            }

            val totalMs = clock.elapsedRealtimeMillis().toDouble() - startTime
            return result.copy(
                runId = runId,
                telemetry = result.telemetry.copy(
                    providerUsed = provider.describe().id,
                    totalMs = totalMs
                )
            )
        } catch (error: Throwable) {
            throw toIndeRunException(
                error,
                fallbackRunId = runId,
                fallbackDetails = mapOf(
                    "totalMs" to (clock.elapsedRealtimeMillis().toDouble() - startTime)
                )
            )
        }
    }

    private fun validateRequest(request: TaskRequest, runId: String) {
        val validationIssues = mutableListOf<String>()

        if (request.schemaVersion != SchemaVersion.V1_0) {
            validationIssues += "schemaVersion must be '1.0'"
        }
        if (request.task.kind != TaskKind.TEXT_TO_TEXT) {
            validationIssues += "task.kind must be 'text_to_text'"
        }

        val hasPrompt = !request.prompt.isNullOrBlank()
        val hasMessages = !request.messages.isNullOrEmpty()

        if (request.requestId != null && request.requestId!!.isBlank()) {
            validationIssues += "requestId must be non-empty when provided."
        }
        if (request.prompt != null && request.prompt!!.isBlank()) {
            validationIssues += "prompt must be non-empty when provided."
        }
        if (request.authContextRef != null && request.authContextRef!!.isBlank()) {
            validationIssues += "authContextRef must be non-empty when provided."
        }
        if (request.messages?.any { it.content.isBlank() } == true) {
            validationIssues += "messages[].content must be non-empty."
        }
        if (!hasPrompt && !hasMessages) {
            validationIssues += "Either prompt or messages must be provided and non-empty."
        }

        if (validationIssues.isNotEmpty()) {
            throw createInternal(
                message = "Validation failed for TaskRequest: ${validationIssues.joinToString("; ")}",
                runId = runId,
                details = mapOf("validationIssues" to validationIssues)
            )
        }
    }

    companion object {
        /**
         * Initializes the IndeRun SDK with a given Android [Context].
         *
         * @param context The application or activity context.
         * @return A new instance of the [IndeRun] SDK.
         */
        @JvmStatic
        fun initialize(
            context: Context,
            registry: ProviderRegistry? = null
        ): IndeRun {
            val appContext = context.applicationContext
            val services = HostServicesFactory.create(context.applicationContext)
            val providerRegistry = registry ?: AndroidProviderRegistryFactory.makeDefaultRegistry(appContext)
            return IndeRun(services, providerRegistry)
        }
    }
}
