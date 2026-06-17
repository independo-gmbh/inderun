package com.independo.inderun.sdk

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.independo.inderun.contracts.ExecutionPolicy
import com.independo.inderun.contracts.FinishReason
import com.independo.inderun.contracts.Output
import com.independo.inderun.contracts.Policy
import com.independo.inderun.contracts.TaskRequest
import com.independo.inderun.contracts.TaskResult
import com.independo.inderun.contracts.TaskResultTelemetry
import com.independo.inderun.core.HostServices
import com.independo.inderun.core.ProviderAdapter
import com.independo.inderun.core.ProviderDescriptor
import com.independo.inderun.core.ProviderDynamicCapabilities
import com.independo.inderun.core.ProviderRegistry
import com.independo.inderun.core.RunContext
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
                prompt = "Hello",
                policy = Policy(ExecutionPolicy.ON_DEVICE)
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
                telemetry = TaskResultTelemetry(providerUsed = "sdk-provider", totalMs = 0.0)
            )
        }
    }
}
