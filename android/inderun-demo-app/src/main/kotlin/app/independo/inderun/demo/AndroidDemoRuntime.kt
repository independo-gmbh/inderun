package app.independo.inderun.demo

import android.content.Context
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.HttpRequest
import app.independo.inderun.contracts.Method
import app.independo.inderun.contracts.Policy
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.HostServicesFactory
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderAdapter
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.providers.mlkit.AndroidMlKitGenAiProvider
import app.independo.inderun.providers.mlkit.AndroidProviderRegistryFactory
import app.independo.inderun.providers.openai.OpenAIAuthMode
import app.independo.inderun.providers.openai.OpenAIProvider
import app.independo.inderun.providers.openai.OpenAIProviderOptions
import app.independo.inderun.sdk.IndeRun

internal interface DemoRuntime {
    suspend fun refreshAvailability(settings: DemoSettings): DemoAvailabilitySnapshot
    suspend fun run(
        prompt: String,
        executionMode: DemoExecutionMode,
        settings: DemoSettings
    ): DemoExecutionOutcome
}

internal class AndroidDemoRuntime(
    private val context: Context,
    private val hostServices: HostServices = HostServicesFactory.create(context.applicationContext)
) : DemoRuntime {
    override suspend fun refreshAvailability(settings: DemoSettings): DemoAvailabilitySnapshot {
        return DemoAvailabilitySnapshot(
            onDevice = probeOnDeviceAvailability(),
            cloud = probeCloudAvailability(settings)
        )
    }

    override suspend fun run(
        prompt: String,
        executionMode: DemoExecutionMode,
        settings: DemoSettings
    ): DemoExecutionOutcome {
        val request = TaskRequest(
            prompt = prompt.trim(),
            policy = Policy(execution = executionMode.policy)
        )

        return try {
            val result = IndeRun.initialize(
                context = context.applicationContext,
                registry = createRegistry(settings)
            ).run(request)

            DemoExecutionOutcome.Success(
                outputText = result.output.text,
                metadata = AttemptMetadata(
                    runId = result.runId,
                    providerUsed = result.telemetry.providerUsed,
                    totalMs = result.telemetry.totalMs,
                    providerId = result.telemetry.providerUsed,
                    retryAfterMs = null
                )
            )
        } catch (error: IndeRunException) {
            DemoExecutionOutcome.Failure(
                error = DemoErrorState(
                    title = "Normalized Error",
                    body = "${error.errorClass.rawValue}\n\n${error.message}",
                    metadata = AttemptMetadata(
                        runId = error.runId ?: "n/a",
                        providerUsed = error.providerId ?: executionMode.providerFallback,
                        totalMs = error.details?.get("totalMs").toDoubleOrNull(),
                        providerId = error.providerId,
                        retryAfterMs = error.retryAfterMs
                    )
                ),
                onDeviceStatusOverride = when {
                    executionMode == DemoExecutionMode.OnDevice -> DemoAvailabilityState.unavailable(error.message)
                    else -> null
                },
                cloudStatusOverride = when {
                    executionMode != DemoExecutionMode.Cloud -> null
                    error.errorClass == IndeRunErrorClass.Offline ->
                        DemoAvailabilityState.unavailable("Device is offline. Reconnect or switch to on-device mode.")

                    error.errorClass == IndeRunErrorClass.Unavailable ->
                        DemoAvailabilityState.unavailable(unavailableCloudMessage(settings.endpointUrl.trim()))

                    else -> null
                }
            )
        } catch (error: Throwable) {
            DemoExecutionOutcome.Failure(
                error = DemoErrorState(
                    title = "Unexpected Error",
                    body = error.localizedMessage ?: error.toString(),
                    metadata = null
                )
            )
        }
    }

    private suspend fun probeOnDeviceAvailability(): DemoAvailabilityState {
        val capabilities = onDeviceProvider().capabilities(hostServices)
        if (capabilities.available) {
            return DemoAvailabilityState.available(
                "Android ML Kit GenAI reported availability for this device and current system state."
            )
        }

        val reason = capabilities.reason ?: "Android ML Kit GenAI is currently unavailable."
        return when {
            reason.contains("can be downloaded", ignoreCase = true) ->
                DemoAvailabilityState.downloadable(reason)

            reason.contains("currently downloading", ignoreCase = true) ->
                DemoAvailabilityState.downloading(reason)

            else -> DemoAvailabilityState.unavailable(reason)
        }
    }

    private suspend fun probeCloudAvailability(settings: DemoSettings): DemoAvailabilityState {
        val endpointUrl = settings.endpointUrl.trim()
        val model = settings.model.trim()

        if (endpointUrl.isEmpty()) {
            return DemoAvailabilityState.unavailable(
                "Enter a cloud endpoint URL. The default emulator proxy URL is ${DemoDefaults.defaultCloudEndpointUrl}."
            )
        }

        if (!isValidEndpointUrl(endpointUrl)) {
            return DemoAvailabilityState.unavailable("The configured cloud endpoint URL is not valid.")
        }

        if (model.isEmpty()) {
            return DemoAvailabilityState.unavailable("Enter a model name for the cloud request.")
        }

        if (!hostServices.connectivity.isOnline()) {
            return DemoAvailabilityState.unavailable(
                "Device is offline. The cloud route will fail before the endpoint is contacted."
            )
        }

        val httpClient = hostServices.httpClient
            ?: return DemoAvailabilityState.unavailable(
                "The host is missing the HTTP support required for cloud execution."
            )

        return try {
            val response = httpClient.send(
                HttpRequest(
                    method = Method.Get,
                    url = createProbeUrl(endpointUrl),
                    timeoutMs = 2_000L
                )
            )
            DemoAvailabilityState.available(
                "Cloud execution is configured and the endpoint is reachable. Probe status: ${response.status}. Requests use app-side auth disabled."
            )
        } catch (_: Throwable) {
            DemoAvailabilityState.unavailable(unavailableCloudMessage(endpointUrl))
        }
    }

    private fun createRegistry(settings: DemoSettings): ProviderRegistry {
        val registry = AndroidProviderRegistryFactory.makeDefaultRegistry(context.applicationContext)
        registry.register(
            OpenAIProvider(
                OpenAIProviderOptions(
                    id = "openai_compatible_cloud",
                    model = settings.model.trim(),
                    endpointUrl = settings.endpointUrl.trim(),
                    auth = OpenAIAuthMode.none
                )
            )
        )
        return registry
    }

    private fun onDeviceProvider(): ProviderAdapter {
        return AndroidProviderRegistryFactory
            .makeDefaultRegistry(context.applicationContext)
            .get(AndroidMlKitGenAiProvider.DEFAULT_ID)
            ?: AndroidMlKitGenAiProvider()
    }
}

private fun Any?.toDoubleOrNull(): Double? {
    return when (this) {
        is Double -> this
        is Float -> toDouble()
        is Int -> toDouble()
        is Long -> toDouble()
        is String -> toDoubleOrNull()
        else -> null
    }
}
