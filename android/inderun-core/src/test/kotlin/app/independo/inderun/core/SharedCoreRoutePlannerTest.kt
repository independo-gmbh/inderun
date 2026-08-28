package app.independo.inderun.core

import app.independo.inderun.contracts.Code
import app.independo.inderun.contracts.FailureCode
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.Output
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.TaskKind
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestTask
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TaskResultTelemetry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * `toJson` is hand-written rather than generated, so it is the one place a new
 * planner-input field can be silently dropped on the way into the shared core.
 * These tests pin the wire shape.
 */
@RunWith(RobolectricTestRunner::class)
class SharedCoreRoutePlannerTest {
    @Test
    fun plannerInputJsonCarriesInteractionModeAndStreamingCapability() {
        val descriptor = ProviderDescriptor(
            id = "provider_a",
            type = ProviderDescriptor.ProviderType.local,
            transport = ProviderDescriptor.TransportType.in_process,
            supports = ProviderDescriptor.SupportsCapabilities(
                run = true,
                streaming = true,
                realtime = false,
                tools = false,
                reasoningEvents = false,
                structuredOutput = false,
                multimodal = false,
            ),
            cancel = ProviderDescriptor.CancelSemantics.hard,
            tasks = listOf("text_to_text"),
        )
        val snapshot = ProviderSnapshot(
            provider = StubProvider(descriptor),
            descriptor = descriptor,
            capabilities = ProviderDynamicCapabilities(
                available = true,
                streamingAvailable = false,
                streamingUnavailableReason = "Host has no chunked HTTP capability.",
                cancellationAvailable = true,
            ),
        )

        val json = JSONObject(
            buildSharedPlannerInput(
                request = TaskRequest(
                    schemaVersion = SchemaVersion.V1_0,
                    prompt = "Hello",
                    task = TaskRequestTask(TaskKind.TEXT_TO_TEXT),
                ),
                online = true,
                snapshots = listOf(snapshot),
            ).toJson(),
        )

        assertEquals("run", json.getString("interactionMode"))
        val provider = json.getJSONArray("providers").getJSONObject(0)
        val emittedDescriptor = provider.getJSONObject("descriptor")
        assertEquals(true, emittedDescriptor.getJSONObject("supports").getBoolean("streaming"))
        assertEquals("hard", emittedDescriptor.getString("cancel"))
        val capabilities = provider.getJSONObject("capabilities")
        assertEquals(false, capabilities.getBoolean("streamingAvailable"))
        assertEquals(
            "Host has no chunked HTTP capability.",
            capabilities.getString("streamingUnavailableReason"),
        )
        assertEquals(true, capabilities.getBoolean("cancellationAvailable"))
    }

    @Test
    fun routePlanParsingAcceptsStreamingReasonsAndIgnoresUnknownOnes() {
        val plan = parseSharedPlannerRoutePlan(
            """
            {
              "candidates": [],
              "fallbackProviderIds": [],
              "failureCode": "capability_mismatch",
              "explanation": { "summary": "No provider capable of streaming was found." },
              "rejectedProviders": [
                {
                  "providerId": "provider_a",
                  "reasons": [
                    { "code": "streaming_not_supported", "message": "no streaming" },
                    { "code": "a_code_from_a_newer_core", "message": "ignored" }
                  ]
                }
              ]
            }
            """.trimIndent(),
        )

        assertEquals(FailureCode.CapabilityMismatch, plan.failureCode)
        val reasons = plan.rejectedProviders[0].reasons
        assertEquals(1, reasons.size)
        assertEquals(Code.StreamingNotSupported, reasons[0].code)
    }

    private class StubProvider(private val descriptor: ProviderDescriptor) : ProviderAdapter {
        override fun describe(): ProviderDescriptor = descriptor

        override suspend fun capabilities(host: HostServices): ProviderDynamicCapabilities = ProviderDynamicCapabilities(available = true)

        override suspend fun run(request: TaskRequest, context: RunContext): TaskResult = TaskResult(
            finishReason = FinishReason.STOP,
            output = Output(text = "Hello"),
            runId = context.runId,
            schemaVersion = SchemaVersion.V1_0,
            telemetry = TaskResultTelemetry(providerUsed = descriptor.id, totalMs = 0.0),
        )
    }
}
