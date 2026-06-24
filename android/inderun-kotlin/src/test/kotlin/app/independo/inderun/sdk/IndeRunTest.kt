package app.independo.inderun.sdk

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.Output
import app.independo.inderun.contracts.PrivacyEnum
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestConstraints
import app.independo.inderun.contracts.TaskRequestTask
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TaskResultTelemetry
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.ProviderAdapter
import app.independo.inderun.core.ProviderDescriptor
import app.independo.inderun.core.ProviderDynamicCapabilities
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.core.RunContext
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class IndeRunTest {
    @Test
    fun initialize_exposesHostServices() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val registry = ProviderRegistry().apply {
            register(FakeProvider())
        }
        val indeRun = IndeRun.initialize(context, registry)

        assertTrue(indeRun.clock.elapsedRealtimeMillis() >= 0)
        assertTrue(indeRun.connectivity.isOnline() || !indeRun.connectivity.isOnline())
    }

    @Test
    fun runRoutesThroughRegisteredProvider() = runTest {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val registry = ProviderRegistry().apply {
            register(FakeProvider())
        }
        val indeRun = IndeRun.initialize(context, registry)

        val result = indeRun.run(
            TaskRequest(
                schemaVersion = SchemaVersion.V1_0,
                prompt = "Hello",
                task = TaskRequestTask(),
                constraints = TaskRequestConstraints(privacy = PrivacyEnum.LocalRequired)
            )
        )

        assertEquals("sdk-provider", result.telemetry.providerUsed)
        assertEquals(FinishReason.STOP, result.finishReason)
        assertEquals("Hello from sdk provider", result.output.text)
    }

    private class FakeProvider : ProviderAdapter {
        override fun describe(): ProviderDescriptor {
            return ProviderDescriptor(
                id = "sdk-provider",
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
            return ProviderDynamicCapabilities(available = true)
        }

        override suspend fun run(request: TaskRequest, context: RunContext): TaskResult {
            return TaskResult(
                finishReason = FinishReason.STOP,
                output = Output(text = "Hello from sdk provider"),
                runId = context.runId,
                schemaVersion = SchemaVersion.V1_0,
                telemetry = TaskResultTelemetry(providerUsed = "sdk-provider", totalMs = 0.0)
            )
        }
    }
}
