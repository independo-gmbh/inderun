package app.independo.inderun.core

import app.independo.inderun.contracts.ExecutionPolicy
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.Output
import app.independo.inderun.contracts.Policy
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TaskResultTelemetry
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProviderEngineTest {
    @Test
    fun registryRejectsDuplicateIds() {
        val registry = ProviderRegistry()
        registry.register(FakeProvider("provider_a"))

        try {
            registry.register(FakeProvider("provider_a"))
        } catch (error: IllegalStateException) {
            assertTrue(error.message!!.contains("already registered"))
            return
        }

        throw AssertionError("Expected duplicate provider registration to fail.")
    }

    @Test
    fun routerSelectsAvailableLocalProviderDeterministically() = runTest {
        val registry = ProviderRegistry()
        registry.register(FakeProvider("provider_b", available = true))
        registry.register(FakeProvider("provider_a", available = true))

        val selection = Router(registry).selectRoute(
            request = TaskRequest(
                prompt = "Hello",
                policy = Policy(ExecutionPolicy.ON_DEVICE)
            ),
            hostServices = fakeHostServices()
        )

        assertEquals("provider_a", selection.provider.describe().id)
    }

    @Test
    fun routerThrowsCapabilityMismatchWhenOnDeviceProviderUnavailable() = runTest {
        val registry = ProviderRegistry()
        registry.register(FakeProvider("provider_a", available = false))

        try {
            Router(registry).selectRoute(
                request = TaskRequest(
                    prompt = "Hello",
                    policy = Policy(ExecutionPolicy.ON_DEVICE)
                ),
                hostServices = fakeHostServices()
            )
        } catch (error: IndeRunException) {
            assertEquals(app.independo.inderun.contracts.IndeRunErrorClass.CapabilityMismatch, error.errorClass)
            return@runTest
        }

        throw AssertionError("Expected CapabilityMismatch for unavailable on-device provider.")
    }

    @Test
    fun errorStandardizationPreservesFallbackContext() {
        val exception = toIndeRunException(
            IllegalStateException("boom"),
            fallbackRunId = "run_123",
            fallbackProviderId = "provider_a"
        )

        assertEquals("run_123", exception.runId)
        assertEquals("provider_a", exception.providerId)
        assertNotNull(exception.details?.get("originalError"))
    }

    private fun fakeHostServices(): HostServices {
        return HostServices(
            connectivity = object : ConnectivityService {
                override fun isOnline(): Boolean = true
            },
            secureStorage = object : SecureStorageService {
                override fun get(authContextRef: String): String? = null
                override fun put(authContextRef: String, value: String) = Unit
                override fun remove(authContextRef: String) = Unit
            },
            clock = object : ClockService {
                override fun elapsedRealtimeMillis(): Long = 1_000L
            }
        )
    }

    private class FakeProvider(
        private val id: String,
        private val available: Boolean = true
    ) : ProviderAdapter {
        override fun describe(): ProviderDescriptor {
            return ProviderDescriptor(
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
                    multimodal = false
                ),
                cancel = ProviderDescriptor.CancelSemantics.soft,
                tasks = listOf("text_to_text")
            )
        }

        override suspend fun capabilities(host: HostServices): ProviderDynamicCapabilities {
            return ProviderDynamicCapabilities(available = available)
        }

        override suspend fun run(request: TaskRequest, context: RunContext): TaskResult {
            return TaskResult(
                finishReason = FinishReason.STOP,
                output = Output(text = "Hello"),
                runId = context.runId,
                telemetry = TaskResultTelemetry(providerUsed = id, totalMs = 0.0)
            )
        }
    }
}
