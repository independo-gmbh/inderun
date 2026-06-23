package app.independo.inderun.providers.openai

import app.independo.inderun.contracts.ExecutionPolicy
import app.independo.inderun.contracts.HttpRequest
import app.independo.inderun.contracts.HttpResponse
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.Message
import app.independo.inderun.contracts.MessageRole
import app.independo.inderun.contracts.Method
import app.independo.inderun.contracts.Policy
import app.independo.inderun.contracts.TaskRequest
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
import org.junit.Assert.assertTrue
import org.junit.Test

class OpenAIProviderTest {
    @Test
    fun capabilitiesRequireHttpClientAndSecureStorageWhenAuthEnabled() = runTest {
        val provider = OpenAIProvider(OpenAIProviderOptions(model = "gpt-5.2"))

        val missingHttp = provider.capabilities(
            HostServices(
                connectivity = onlineConnectivity(),
                secureStorage = fakeSecureStorage(),
                clock = fakeClock()
            )
        )
        assertFalse(missingHttp.available)

        val available = provider.capabilities(
            HostServices(
                connectivity = onlineConnectivity(),
                secureStorage = fakeSecureStorage(),
                clock = fakeClock(),
                httpClient = FakeHttpClient(emptyList())
            )
        )
        assertTrue(available.available)
    }

    @Test
    fun runPostsResponsesRequestAndMapsResult() = runTest {
        val httpClient = FakeHttpClient(
            listOf(
                HttpResponse(
                    body = """{"output_text":"Hello from Responses.","status":"completed","usage":{"input_tokens":3,"output_tokens":4,"total_tokens":7}}""",
                    headers = emptyMap(),
                    status = 200,
                    statusText = "OK"
                )
            )
        )
        val provider = OpenAIProvider(
            OpenAIProviderOptions(model = "gpt-5.2", authContextRef = "openai-dev", timeoutMs = 30_000L)
        )
        val result = provider.run(
            request = TaskRequest(
                prompt = "Say hello.",
                policy = Policy(ExecutionPolicy.CLOUD),
                authContextRef = "openai-dev"
            ),
            context = RunContext("run_123", fakeHostServices(httpClient = httpClient))
        )

        assertEquals("Hello from Responses.", result.output.text)
        assertEquals(3L, result.usage?.inputTokens)
        assertEquals(4L, result.usage?.outputTokens)
        assertEquals(7L, result.usage?.totalTokens)
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
                    statusText = "OK"
                )
            )
        )
        val provider = OpenAIProvider(OpenAIProviderOptions(model = "gpt-5.2", auth = OpenAIAuthMode.none))

        provider.run(
            request = TaskRequest(
                messages = listOf(
                    Message(MessageRole.SYSTEM, "Be concise."),
                    Message(MessageRole.USER, "Say hello.")
                ),
                policy = Policy(ExecutionPolicy.CLOUD)
            ),
            context = RunContext("run_messages", fakeHostServices(httpClient = httpClient, includeSecret = false))
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
                    statusText = "Too Many Requests"
                )
            )
        )

        try {
            provider.run(
                request = TaskRequest(prompt = "Hello", policy = Policy(ExecutionPolicy.CLOUD)),
                context = RunContext("run_rate", fakeHostServices(httpClient = httpClient, includeSecret = false))
            )
        } catch (error: IndeRunException) {
            assertEquals(IndeRunErrorClass.RateLimited, error.errorClass)
            assertEquals(2_000L, error.retryAfterMs)
            return@runTest
        }

        throw AssertionError("Expected RateLimited.")
    }

    @Test
    fun runPropagatesCancellation() = runTest {
        val provider = OpenAIProvider(OpenAIProviderOptions(model = "gpt-5.2", auth = OpenAIAuthMode.none))
        val httpClient = FakeHttpClient(listOf(CancellationException("cancelled")))

        try {
            provider.run(
                request = TaskRequest(prompt = "Hello", policy = Policy(ExecutionPolicy.CLOUD)),
                context = RunContext("run_cancel", fakeHostServices(httpClient = httpClient, includeSecret = false))
            )
        } catch (error: CancellationException) {
            return@runTest
        }

        throw AssertionError("Expected CancellationException.")
    }

    @Test
    fun registryFactoryRegistersProvider() {
        val registry = AndroidCloudProviderRegistryFactory.makeOpenAIRegistry(
            OpenAIProviderOptions(model = "gpt-5.2", auth = OpenAIAuthMode.none)
        )

        assertEquals(1, registry.list().size)
        assertEquals("openai", registry.get("openai")?.describe()?.id)
    }

    private fun fakeHostServices(
        httpClient: HttpClientService,
        includeSecret: Boolean = true
    ): HostServices {
        return HostServices(
            connectivity = onlineConnectivity(),
            secureStorage = fakeSecureStorage(includeSecret),
            clock = fakeClock(),
            httpClient = httpClient
        )
    }

    private fun fakeSecureStorage(includeSecret: Boolean = true): SecureStorageService {
        return object : SecureStorageService {
            override fun get(authContextRef: String): String? = if (includeSecret) "sk-from-slot" else null
            override fun put(authContextRef: String, value: String) = Unit
            override fun remove(authContextRef: String) = Unit
        }
    }

    private fun onlineConnectivity(): ConnectivityService {
        return object : ConnectivityService {
            override fun isOnline(): Boolean = true
        }
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
        responses: List<Any>
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
