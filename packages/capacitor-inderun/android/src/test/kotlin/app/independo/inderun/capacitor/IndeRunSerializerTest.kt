package app.independo.inderun.capacitor

import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.Output
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestTask
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TaskResultTelemetry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

class IndeRunSerializerTest {
    @Test
    fun `parseRunOptions decodes canonical request fields`() {
        val request = IndeRunSerializer.parseTaskRequest(
            JSONObject(
                """
                {
                  "schemaVersion": "1.0",
                  "task": { "kind": "text_to_text" },
                  "prompt": "Hello",
                  "constraints": { "privacy": "cloud_required" }
                }
                """.trimIndent()
            )
        )
        val options = IndeRunSerializer.parseConfigureOptions(
            JSONObject(
                """
                {
                  "openAI": {
                    "model": "gpt-5.2",
                    "endpointUrl": "/api/inderun/openai-responses",
                    "auth": "none"
                  }
                }
                """.trimIndent()
            )
        )

        assertEquals("Hello", request.prompt)
        assertEquals("gpt-5.2", options.openAI?.model)
        assertEquals("/api/inderun/openai-responses", options.openAI?.endpointUrl)
    }

    @Test
    fun `encodeTaskResult preserves canonical task result shape`() {
        val encoded = IndeRunSerializer.encodeTaskResult(
            TaskResult(
                finishReason = FinishReason.STOP,
                output = Output(text = "Hi"),
                runId = "run_123",
                schemaVersion = SchemaVersion.V1_0,
                telemetry = TaskResultTelemetry(providerUsed = "openai", totalMs = 12.0)
            )
        )

        assertEquals("1.0", encoded.getString("schemaVersion"))
        assertEquals("stop", encoded.getString("finishReason"))
        assertEquals("Hi", encoded.getJSONObject("output").getString("text"))
        assertEquals("openai", encoded.getJSONObject("telemetry").getString("providerUsed"))
    }
}
