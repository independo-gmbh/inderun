package app.independo.inderun.capacitor

import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.core.toIndeRunException
import app.independo.inderun.providers.mlkit.AndroidProviderRegistryFactory
import app.independo.inderun.providers.openai.DEFAULT_OPENAI_RESPONSES_ENDPOINT
import app.independo.inderun.providers.openai.OpenAIAuthMode
import app.independo.inderun.providers.openai.OpenAIProvider
import app.independo.inderun.providers.openai.OpenAIProviderOptions
import app.independo.inderun.sdk.IndeRun
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

@CapacitorPlugin(name = "IndeRunCapacitor")
class IndeRunCapacitorPlugin : Plugin() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var configuredRegistry: ProviderRegistry? = null

    @PluginMethod
    fun configure(call: PluginCall) {
        try {
            val options = IndeRunSerializer.parseConfigureOptions(call.data)
            configuredRegistry = createRegistry(options.openAI)
            call.resolve()
        } catch (error: IndeRunException) {
            val contractError = error.toContractError()
            call.reject(
                contractError.message,
                contractError.errorClass.rawValue,
                null,
                runCatching { IndeRunSerializer.encodeError(contractError) }.getOrNull()
            )
        } catch (error: Throwable) {
            val normalized = toIndeRunException(error)
            val contractError = normalized.toContractError()
            call.reject(
                contractError.message,
                contractError.errorClass.rawValue,
                null,
                runCatching { IndeRunSerializer.encodeError(contractError) }.getOrNull()
            )
        }
    }

    @PluginMethod
    fun run(call: PluginCall) {
        val requestJson = call.data

        scope.launch {
            try {
                val registry = configuredRegistry
                    ?: throw toIndeRunException(IllegalStateException("Capacitor IndeRun has not been configured. Configure providers before calling run(request)."))
                val request = IndeRunSerializer.parseTaskRequest(requestJson)
                // IndeRun is stateless; new per call is intentional — registry is cached after configure().
                val result = IndeRun.initialize(context.applicationContext, registry).run(request)
                call.resolve(IndeRunSerializer.encodeTaskResult(result))
            } catch (error: IndeRunException) {
                val contractError = error.toContractError()
                call.reject(
                    contractError.message,
                    contractError.errorClass.rawValue,
                    null,
                    runCatching { IndeRunSerializer.encodeError(contractError) }.getOrNull()
                )
            } catch (error: Throwable) {
                val normalized = toIndeRunException(error)
                val contractError = normalized.toContractError()
                call.reject(
                    contractError.message,
                    contractError.errorClass.rawValue,
                    null,
                    runCatching { IndeRunSerializer.encodeError(contractError) }.getOrNull()
                )
            }
        }
    }

    override fun handleOnDestroy() {
        scope.cancel()
        super.handleOnDestroy()
    }

    private fun createRegistry(openAI: OpenAIProviderBootstrapOptions?): ProviderRegistry {
        val registry = AndroidProviderRegistryFactory.makeDefaultRegistry(context.applicationContext)

        if (openAI != null) {
            registry.register(
                OpenAIProvider(
                    OpenAIProviderOptions(
                        id = "openai",
                        model = openAI.model,
                        endpointUrl = openAI.endpointUrl ?: DEFAULT_OPENAI_RESPONSES_ENDPOINT,
                        auth = if (openAI.auth == "none") OpenAIAuthMode.none else OpenAIAuthMode.authContextRef,
                        authContextRef = openAI.authContextRef,
                        timeoutMs = openAI.timeoutMs
                    )
                )
            )
        }

        return registry
    }
}
