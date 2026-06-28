package app.independo.inderun.capacitor

import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.IndeRunError
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.Output
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestTask
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TaskResultTelemetry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
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

    // --- Unknown enum values throw ---

    @Test(expected = IllegalArgumentException::class)
    fun `parseTaskRequest throws on unknown schemaVersion`() {
        IndeRunSerializer.parseTaskRequest(
            JSONObject("""{"schemaVersion":"9.9","task":{"kind":"text_to_text"},"prompt":"Hello"}""")
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun `parseTaskRequest throws on unknown task kind`() {
        IndeRunSerializer.parseTaskRequest(
            JSONObject("""{"schemaVersion":"1.0","task":{"kind":"image_to_text"},"prompt":"Hello"}""")
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun `parseTaskRequest throws on unknown cloud constraint`() {
        IndeRunSerializer.parseTaskRequest(
            JSONObject("""{"schemaVersion":"1.0","task":{"kind":"text_to_text"},"prompt":"Hi","constraints":{"cloud":"maybe"}}""")
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun `parseTaskRequest throws on unknown privacy constraint`() {
        IndeRunSerializer.parseTaskRequest(
            JSONObject("""{"schemaVersion":"1.0","task":{"kind":"text_to_text"},"prompt":"Hi","constraints":{"privacy":"some_value"}}""")
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun `parseTaskRequest throws on unknown message role`() {
        IndeRunSerializer.parseTaskRequest(
            JSONObject("""{"schemaVersion":"1.0","task":{"kind":"text_to_text"},"prompt":"Hi","messages":[{"role":"moderator","content":"Hi"}]}""")
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun `parseTaskRequest throws on unknown optimizeFor`() {
        IndeRunSerializer.parseTaskRequest(
            JSONObject("""{"schemaVersion":"1.0","task":{"kind":"text_to_text"},"prompt":"Hi","preferences":{"optimizeFor":"turbo"}}""")
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun `parseTaskRequest throws on unknown telemetry level`() {
        IndeRunSerializer.parseTaskRequest(
            JSONObject("""{"schemaVersion":"1.0","task":{"kind":"text_to_text"},"prompt":"Hi","telemetry":{"level":"verbose"}}""")
        )
    }

    // --- Absent optional fields ---

    @Test
    fun `parseTaskRequest accepts minimal request with all optionals absent`() {
        val request = IndeRunSerializer.parseTaskRequest(
            JSONObject("""{"schemaVersion":"1.0","task":{"kind":"text_to_text"},"prompt":"Hi"}""")
        )
        assertNull(request.authContextRef)
        assertNull(request.constraints)
        assertNull(request.generation)
        assertNull(request.messages)
        assertNull(request.preferences)
        assertNull(request.requestId)
        assertNull(request.telemetry)
    }

    @Test
    fun `parseConfigureOptions accepts empty object`() {
        val options = IndeRunSerializer.parseConfigureOptions(JSONObject("{}"))
        assertNull(options.openAI)
    }

    // --- encodeError ---

    @Test
    fun `encodeError produces correct shape with required fields only`() {
        val encoded = IndeRunSerializer.encodeError(
            IndeRunError(
                errorClass = IndeRunErrorClass.Unavailable,
                message = "Not configured."
            )
        )
        assertEquals("1.0", encoded.getString("schemaVersion"))
        assertEquals("Unavailable", encoded.getString("errorClass"))
        assertEquals("Not configured.", encoded.getString("message"))
        assertFalse(encoded.has("providerId"))
        assertFalse(encoded.has("retryable"))
        assertFalse(encoded.has("retryAfterMs"))
        assertFalse(encoded.has("runId"))
    }

    @Test
    fun `encodeError includes all optional fields when set`() {
        val encoded = IndeRunSerializer.encodeError(
            IndeRunError(
                errorClass = IndeRunErrorClass.RateLimited,
                message = "Rate limit exceeded.",
                providerId = "openai",
                retryable = true,
                retryAfterMs = 2000L,
                runId = "run_abc"
            )
        )
        assertEquals("RateLimited", encoded.getString("errorClass"))
        assertEquals("openai", encoded.getString("providerId"))
        assertEquals(true, encoded.getBoolean("retryable"))
        assertEquals(2000L, encoded.getLong("retryAfterMs"))
        assertEquals("run_abc", encoded.getString("runId"))
    }
}
