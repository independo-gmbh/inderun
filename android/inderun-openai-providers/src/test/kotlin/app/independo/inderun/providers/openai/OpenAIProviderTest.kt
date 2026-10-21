package app.independo.inderun.providers.openai

import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.HttpRequest
import app.independo.inderun.contracts.HttpResponse
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.Message
import app.independo.inderun.contracts.MessageRole
import app.independo.inderun.contracts.Method
import app.independo.inderun.contracts.Privacy
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestConstraints
import app.independo.inderun.contracts.TaskRequestTask
import app.independo.inderun.core.ClockService
import app.independo.inderun.core.ConnectivityService
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.HttpClientService
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.SecureStorageService
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class OpenAIProviderTest {
    @Test
    fun capabilitiesRequireHttpClientAndSecureStorageWhenAuthEnabled() = runTest {
        val provider = OpenAIProvider(OpenAIProviderOptions(model = "gpt-5.2"))

        val missingHttp = provider.capabilities(
            HostServices(
                connectivity = onlineConnectivity(),
                secureStorage = fakeSecureStorage(),
                clock = fakeClock(),
            ),
        )
        assertFalse(missingHttp.available)

        val available = provider.capabilities(
            HostServices(
                connectivity = onlineConnectivity(),
                secureStorage = fakeSecureStorage(),
                clock = fakeClock(),
                httpClient = FakeHttpClient(
                    listOf(HttpResponse(body = "", headers = emptyMap(), status = 200, statusText = "OK")),
                ),
            ),
        )
        assertTrue(available.available)
    }

    @Test
    fun capabilitiesReportsUnavailableOn5xxReachabilityProbe() = runTest {
        val httpClient = FakeHttpClient(
            listOf(HttpResponse(body = "", headers = emptyMap(), status = 502, statusText = "Bad Gateway")),
        )
        val provider = OpenAIProvider(OpenAIProviderOptions(model = "gpt-5.2", auth = OpenAIAuthMode.none))

        val result = provider.capabilities(fakeHostServices(httpClient = httpClient))

        assertFalse(result.available)
        assertEquals("OpenAI Responses endpoint returned HTTP 502.", result.reason)
        assertEquals(Method.Get, httpClient.requests.single().method)
    }

    @Test
    fun capabilitiesTreatsNon5xxReachabilityResponseAsAvailable() = runTest {
        val httpClient = FakeHttpClient(
            listOf(HttpResponse(body = "", headers = emptyMap(), status = 405, statusText = "Method Not Allowed")),
        )
        val provider = OpenAIProvider(OpenAIProviderOptions(model = "gpt-5.2", auth = OpenAIAuthMode.none))

        val result = provider.capabilities(fakeHostServices(httpClient = httpClient))

        assertTrue(result.available)
    }

    @Test
    fun capabilitiesReportsUnavailableWhenReachabilityProbeThrows() = runTest {
        val httpClient = FakeHttpClient(listOf(IllegalStateException("network down")))
        val provider = OpenAIProvider(OpenAIProviderOptions(model = "gpt-5.2", auth = OpenAIAuthMode.none))

        val result = provider.capabilities(fakeHostServices(httpClient = httpClient))

        assertFalse(result.available)
        assertEquals("OpenAI Responses endpoint is unreachable.", result.reason)
    }

    @Test
    fun capabilitiesCachesReachabilityResultWithinCacheWindow() = runTest {
        val httpClient = FakeHttpClient(
            listOf(HttpResponse(body = "", headers = emptyMap(), status = 200, statusText = "OK")),
        )
        val provider = OpenAIProvider(OpenAIProviderOptions(model = "gpt-5.2", auth = OpenAIAuthMode.none))
        val host = fakeHostServices(httpClient = httpClient)

        val first = provider.capabilities(host)
        val second = provider.capabilities(host)

        assertTrue(first.available)
        assertTrue(second.available)
        assertEquals(1, httpClient.requests.size)
    }

    @Test
    fun runPostsResponsesRequestAndMapsResult() = runTest {
        val httpClient = FakeHttpClient(
            listOf(
                HttpResponse(
                    body = """{"model":"gpt-5.2-2026-08-01","output_text":"Hello from Responses.","status":"completed","usage":{"input_tokens":3,"output_tokens":4,"total_tokens":7}}""",
                    headers = emptyMap(),
                    status = 200,
                    statusText = "OK",
                ),
            ),
        )
        val provider = OpenAIProvider(
            OpenAIProviderOptions(model = "gpt-5.2", authContextRef = "openai-dev", timeoutMs = 30_000L),
        )
        val result = provider.run(
            request = TaskRequest(
                schemaVersion = SchemaVersion.V1_0,
                prompt = "Say hello.",
                task = TaskRequestTask(),
                constraints = TaskRequestConstraints(privacy = Privacy.CloudRequired),
                authContextRef = "openai-dev",
            ),
            context = RunContext("run_123", fakeHostServices(httpClient = httpClient)),
        )

        assertEquals("Hello from Responses.", result.output.text)
        assertEquals(3L, result.usage?.inputTokens)
        assertEquals(4L, result.usage?.outputTokens)
        assertEquals(7L, result.usage?.totalTokens)
        assertEquals("gpt-5.2-2026-08-01", result.telemetry.reportedModel)
        assertEquals("gpt-5.2", provider.describe().model)
        assertEquals(10.0, result.telemetry.totalMs, 0.0)

        val request = httpClient.requests.single()
        assertEquals(Method.Post, request.method)
        assertEquals("Bearer sk-from-slot", request.headers?.get("Authorization"))
        assertEquals(30_000L, request.timeoutMs)

        val body = JSONObject(request.body!!)
        assertEquals("gpt-5.2", body.getString("model"))
        assertEquals("Say hello.", body.getString("input"))
    }

    @Test
    fun runMapsSystemMessagesToDeveloperRole() = runTest {
        val httpClient = FakeHttpClient(
            listOf(
                HttpResponse(
                    body = """{"output_text":"Done."}""",
                    headers = emptyMap(),
                    status = 200,
                    statusText = "OK",
                ),
            ),
        )
        val provider = OpenAIProvider(OpenAIProviderOptions(model = "gpt-5.2", auth = OpenAIAuthMode.none))

        provider.run(
            request = TaskRequest(
                schemaVersion = SchemaVersion.V1_0,
                messages = listOf(
                    Message(MessageRole.SYSTEM, "Be concise."),
                    Message(MessageRole.USER, "Say hello."),
                ),
                task = TaskRequestTask(),
                constraints = TaskRequestConstraints(privacy = Privacy.CloudRequired),
            ),
            context = RunContext("run_messages", fakeHostServices(httpClient = httpClient, includeSecret = false)),
        )

        val input = JSONObject(httpClient.requests.single().body!!).getJSONArray("input")
        assertEquals("developer", input.getJSONObject(0).getString("role"))
        assertEquals("user", input.getJSONObject(1).getString("role"))
    }

    @Test
    fun runMapsRateLimits() = runTest {
        val provider = OpenAIProvider(OpenAIProviderOptions(model = "gpt-5.2", auth = OpenAIAuthMode.none))
        val httpClient = FakeHttpClient(
            listOf(
                HttpResponse(
                    body = """{"error":{"message":"Too many requests","type":"rate_limit"}}""",
                    headers = mapOf("Retry-After" to "2"),
                    status = 429,
                    statusText = "Too Many Requests",
                ),
            ),
        )

        try {
            provider.run(
                request = TaskRequest(
                    schemaVersion = SchemaVersion.V1_0,
                    prompt = "Hello",
                    task = TaskRequestTask(),
                    constraints = TaskRequestConstraints(privacy = Privacy.CloudRequired),
                ),
                context = RunContext("run_rate", fakeHostServices(httpClient = httpClient, includeSecret = false)),
            )
        } catch (error: IndeRunException) {
            assertEquals(IndeRunErrorClass.RateLimited, error.errorClass)
            assertEquals(2_000L, error.retryAfterMs)
            return@runTest
        }

        throw AssertionError("Expected RateLimited.")
    }

    /**
     * Holds the Mode 1 run path to the same shared vectors as the Web and Swift
     * adapters, so HTTP-status, in-body-status and Retry-After mapping cannot drift.
     */
    @Test
    fun matchesTheSharedRunVectors() = runTest {
        val cases = runFixture().getJSONArray("cases")
        assertTrue(cases.length() > 0)

        for (index in 0 until cases.length()) {
            val vector = cases.getJSONObject(index)
            val label = "${vector.getString("name")}: ${vector.getString("description")}"
            val response = vector.getJSONObject("response")
            val responseHeaders = response.getJSONObject("headers")
            val httpClient = FakeHttpClient(
                listOf(
                    HttpResponse(
                        body = response.getString("body"),
                        headers = responseHeaders.keys().asSequence().associateWith { responseHeaders.getString(it) },
                        status = response.getLong("status"),
                        statusText = "",
                    ),
                ),
            )
            val provider = OpenAIProvider(OpenAIProviderOptions(model = "gpt-5.2", auth = OpenAIAuthMode.none))
            val outcome = runCatching {
                provider.run(
                    request = TaskRequest(
                        schemaVersion = SchemaVersion.V1_0,
                        prompt = "Hello",
                        task = TaskRequestTask(),
                        constraints = TaskRequestConstraints(privacy = Privacy.CloudRequired),
                    ),
                    context = RunContext("run_vector", fakeHostServices(httpClient = httpClient, includeSecret = false)),
                )
            }

            val expected = vector.getJSONObject("expected")
            when (expected.getString("kind")) {
                "result" -> {
                    val result = outcome.getOrElse { throw AssertionError("$label: expected a result", it) }
                    assertEquals(label, expected.getString("text"), result.output.text)
                    assertEquals(
                        label,
                        FinishReason.entries.first { it.rawValue == expected.getString("finishReason") },
                        result.finishReason,
                    )
                    assertEquals(
                        label,
                        if (expected.has("reportedModel")) expected.getString("reportedModel") else null,
                        result.telemetry.reportedModel,
                    )
                    val wantUsage = expected.optJSONObject("usage")
                    if (wantUsage == null) {
                        assertNull(label, result.usage)
                    } else {
                        assertEquals(label, wantUsage.getLong("inputTokens"), result.usage?.inputTokens)
                        assertEquals(label, wantUsage.getLong("outputTokens"), result.usage?.outputTokens)
                        assertEquals(label, wantUsage.getLong("totalTokens"), result.usage?.totalTokens)
                    }
                }

                "error" -> {
                    val error = outcome.exceptionOrNull() as? IndeRunException
                        ?: throw AssertionError("$label: expected an IndeRunException, got $outcome")
                    assertEquals(label, IndeRunErrorClass.valueOf(expected.getString("errorClass")), error.errorClass)
                    assertEquals(label, expected.getString("message"), error.message)
                    if (expected.has("retryable")) {
                        assertEquals(label, expected.getBoolean("retryable"), error.retryable)
                    }
                    if (expected.has("retryAfterMs")) {
                        assertEquals(label, expected.getLong("retryAfterMs"), error.retryAfterMs)
                    }
                }

                else -> error("Unknown expected kind in $label")
            }
        }
    }

    @Test
    fun runPropagatesCancellation() = runTest {
        val provider = OpenAIProvider(OpenAIProviderOptions(model = "gpt-5.2", auth = OpenAIAuthMode.none))
        val httpClient = FakeHttpClient(listOf(CancellationException("cancelled")))

        try {
            provider.run(
                request = TaskRequest(
                    schemaVersion = SchemaVersion.V1_0,
                    prompt = "Hello",
                    task = TaskRequestTask(),
                    constraints = TaskRequestConstraints(privacy = Privacy.CloudRequired),
                ),
                context = RunContext("run_cancel", fakeHostServices(httpClient = httpClient, includeSecret = false)),
            )
        } catch (error: CancellationException) {
            return@runTest
        }

        throw AssertionError("Expected CancellationException.")
    }

    @Test
    fun registryFactoryRegistersOneTargetPerModel() {
        val registry = AndroidCloudProviderRegistryFactory.makeOpenAIRegistry(
            OpenAIFactoryOptions(models = listOf("gpt-5.2", "gpt-5-mini"), auth = OpenAIAuthMode.none),
        )

        assertEquals(2, registry.list().size)
        assertEquals("gpt-5.2", registry.get("openai:gpt-5.2")?.describe()?.model)
        assertEquals("gpt-5-mini", registry.get("openai:gpt-5-mini")?.describe()?.model)
    }

    @Test(expected = IllegalArgumentException::class)
    fun registryFactoryRefusesAnEmptyModelList() {
        AndroidCloudProviderRegistryFactory.makeOpenAIRegistry(OpenAIFactoryOptions(models = emptyList()))
    }

    private fun runFixture(): JSONObject {
        var directory: File? = File("").absoluteFile
        while (directory != null) {
            val candidate = File(directory, "contracts/fixtures/openai-compatible/responses-run.json")
            if (candidate.isFile) return JSONObject(candidate.readText(Charsets.UTF_8))
            directory = directory.parentFile
        }
        error("Could not locate contracts/fixtures/openai-compatible/responses-run.json")
    }

    private fun fakeHostServices(
        httpClient: HttpClientService,
        includeSecret: Boolean = true,
    ): HostServices = HostServices(
        connectivity = onlineConnectivity(),
        secureStorage = fakeSecureStorage(includeSecret),
        clock = fakeClock(),
        httpClient = httpClient,
    )

    private fun fakeSecureStorage(includeSecret: Boolean = true): SecureStorageService = object : SecureStorageService {
        override fun get(authContextRef: String): String? = if (includeSecret) "sk-from-slot" else null
        override fun put(authContextRef: String, value: String) = Unit
        override fun remove(authContextRef: String) = Unit
    }

    private fun onlineConnectivity(): ConnectivityService = object : ConnectivityService {
        override fun isOnline(): Boolean = true
    }

    private fun fakeClock(): ClockService {
        var now = 1_000L
        return object : ClockService {
            override fun elapsedRealtimeMillis(): Long {
                now += 10L
                return now
            }
        }
    }

    private class FakeHttpClient(
        responses: List<Any>,
    ) : HttpClientService {
        val requests = mutableListOf<HttpRequest>()
        private val queue = responses.toMutableList()

        override suspend fun send(request: HttpRequest): HttpResponse {
            requests += request
            return when (val next = queue.removeFirst()) {
                is HttpResponse -> next
                is Throwable -> throw next
                else -> error("Unsupported queued response type: ${next::class.java.name}")
            }
        }
    }
}
