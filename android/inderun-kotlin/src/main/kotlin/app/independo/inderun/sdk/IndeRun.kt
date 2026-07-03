package app.independo.inderun.sdk

import android.content.Context
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.TaskKind
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TelemetryEvent
import app.independo.inderun.contracts.TelemetryEventType
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.HostServicesFactory
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.core.Router
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.TelemetryService
import app.independo.inderun.core.createInternal
import app.independo.inderun.core.toIndeRunException
import app.independo.inderun.providers.mlkit.AndroidProviderRegistryFactory
import java.util.UUID
import kotlinx.coroutines.CancellationException

/**
 * The primary entry point for the IndeRun Android SDK.
 *
 * Mirrors the TypeScript/Web and Swift engine surface: it is constructed with a
 * [ProviderRegistry], the platform [HostServices], and an optional
 * [TelemetryService]. Use [initialize] for the batteries-included Android setup
 * that builds the default host services and ML Kit provider registry.
 *
 * @param registry Registry filled with active providers.
 * @param hostServices Platform services wrapping OS interfaces (connectivity, secure storage, clock, HTTP).
 * @param telemetry Optional telemetry sink. Falls back to [HostServices.telemetry] when not provided.
 */
class IndeRun(
    private val registry: ProviderRegistry,
    private val hostServices: HostServices,
    telemetry: TelemetryService? = null
) {
    private val router = Router(registry)
    private val telemetryService: TelemetryService? = telemetry ?: hostServices.telemetry

    suspend fun run(request: TaskRequest): TaskResult {
        val startTime = hostServices.clock.elapsedRealtimeMillis().toDouble()
        val runId = request.requestId ?: "run_${UUID.randomUUID().toString().take(8).lowercase()}"

        try {
            validateRequest(request, runId)

            val routeSelection = router.selectRoute(request, hostServices)
            val providers = listOf(routeSelection.provider) + routeSelection.fallbackProviders
            val attemptedProviderIds = mutableListOf<String>()

            safeEmit(
                TelemetryEvent(
                    type = TelemetryEventType.RouteDecided,
                    runId = runId,
                    timestamp = System.currentTimeMillis().toDouble(),
                    payload = mapOf(
                        "selectedProviderId" to routeSelection.routePlan.selectedProviderId,
                        "fallbackProviderIds" to routeSelection.routePlan.fallbackProviderIds,
                        "rejectedProviderIds" to routeSelection.routePlan.rejectedProviders.map { it.providerId },
                        "fallbackAvailable" to (providers.size > 1),
                        "taskKind" to request.task.kind.rawValue,
                        "explanation" to routeSelection.explanation
                    )
                )
            )

            for ((index, provider) in providers.withIndex()) {
                val providerId = provider.describe().id
                attemptedProviderIds += providerId

                try {
                    val result = provider.run(
                        request = request,
                        context = RunContext(runId = runId, hostServices = hostServices)
                    )

                    val totalMs = hostServices.clock.elapsedRealtimeMillis().toDouble() - startTime

                    safeEmit(
                        TelemetryEvent(
                            type = TelemetryEventType.AttemptSucceeded,
                            runId = runId,
                            timestamp = System.currentTimeMillis().toDouble(),
                            payload = mapOf(
                                "providerId" to providerId,
                                "durationMs" to totalMs,
                                "fallbackOccurred" to (index > 0),
                                "attemptedProviderIds" to attemptedProviderIds.toList()
                            )
                        )
                    )

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
            val totalMs = hostServices.clock.elapsedRealtimeMillis().toDouble() - startTime
            val exception = toIndeRunException(
                error,
                fallbackRunId = runId,
                fallbackDetails = mapOf(
                    "totalMs" to totalMs
                )
            )

            safeEmit(
                TelemetryEvent(
                    type = TelemetryEventType.AttemptFailed,
                    runId = runId,
                    timestamp = System.currentTimeMillis().toDouble(),
                    payload = mapOf(
                        "providerId" to exception.providerId,
                        "durationMs" to totalMs,
                        "errorClass" to exception.errorClass.rawValue,
                        "message" to getStableMessage(exception.errorClass)
                    )
                )
            )

            throw exception
        }
    }

    /**
     * Emits a telemetry event, swallowing any sink failures so telemetry can
     * never disrupt primary execution flows.
     */
    private fun safeEmit(event: TelemetryEvent) {
        val telemetry = telemetryService ?: return
        try {
            telemetry.emit(event)
        } catch (_: Throwable) {
            // Telemetry failures must never disrupt primary execution flows.
        }
    }

    /**
     * Returns a stable, generic message for an error class for privacy-preserving telemetry.
     */
    private fun getStableMessage(errorClass: IndeRunErrorClass): String = when (errorClass) {
        IndeRunErrorClass.CapabilityMismatch -> "Provider capability mismatch."
        IndeRunErrorClass.Offline -> "Device is offline."
        IndeRunErrorClass.AuthError -> "Authentication failed."
        IndeRunErrorClass.RateLimited -> "Rate limit exceeded."
        IndeRunErrorClass.Timeout -> "Execution timed out."
        IndeRunErrorClass.Unavailable -> "Provider is unavailable."
        IndeRunErrorClass.Internal -> "An internal engine error occurred."
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
         * Initializes the IndeRun SDK with the default Android host services and,
         * unless overridden, the default ML Kit provider registry.
         *
         * @param context The application or activity context.
         * @param registry Optional provider registry override.
         * @return A new [IndeRun] instance.
         */
        @JvmStatic
        fun initialize(
            context: Context,
            registry: ProviderRegistry? = null
        ): IndeRun {
            val appContext = context.applicationContext
            val services = HostServicesFactory.create(appContext)
            val providerRegistry = registry ?: AndroidProviderRegistryFactory.makeDefaultRegistry(appContext)
            return IndeRun(providerRegistry, services)
        }
    }
}
