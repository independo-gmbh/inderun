package app.independo.inderun.sdk

import android.content.Context
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.TaskKind
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.HostServicesFactory
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.core.Router
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.createInternal
import app.independo.inderun.core.toIndeRunException
import app.independo.inderun.providers.mlkit.AndroidProviderRegistryFactory
import java.util.UUID
import kotlinx.coroutines.CancellationException

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
            val providers = listOf(routeSelection.provider) + routeSelection.fallbackProviders
            val attemptedProviderIds = mutableListOf<String>()

            for ((index, provider) in providers.withIndex()) {
                val providerId = provider.describe().id
                attemptedProviderIds += providerId

                try {
                    val result = provider.run(
                        request = request,
                        context = RunContext(runId = runId, hostServices = hostServices)
                    )

                    val totalMs = clock.elapsedRealtimeMillis().toDouble() - startTime
                    return result.copy(
                        runId = runId,
                        telemetry = result.telemetry.copy(
                            providerUsed = providerId,
                            totalMs = totalMs
                        )
                    )
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    if (index == providers.lastIndex) {
                        throw toIndeRunException(
                            error,
                            fallbackRunId = runId,
                            fallbackProviderId = providerId,
                            fallbackDetails = mapOf(
                                "attemptedProviderIds" to attemptedProviderIds,
                                "fallbackOccurred" to (providers.size > 1),
                                "routePlan" to routeSelection.routePlan
                            )
                        )
                    }
                }
            }

            throw createInternal(
                message = "No providers were attempted.",
                runId = runId,
                details = mapOf(
                    "attemptedProviderIds" to attemptedProviderIds
                )
            )
        } catch (error: CancellationException) {
            throw error
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
