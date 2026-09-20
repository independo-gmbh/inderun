package app.independo.inderun.providers.openai

import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.HttpRequest
import app.independo.inderun.contracts.HttpResponse
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestTask
import app.independo.inderun.core.ClockService
import app.independo.inderun.core.ConnectivityService
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.HttpClientService
import app.independo.inderun.core.HttpStreamResponse
import app.independo.inderun.core.HttpStreamingClientService
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderDescriptor
import app.independo.inderun.core.ProviderStreamContext
import app.independo.inderun.core.ProviderStreamEvent
import app.independo.inderun.core.SecureStorageService
import app.independo.inderun.core.StreamCancellationToken
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File

/**
 * Holds the Android OpenAI adapter to the same shared event-mapping vectors as
 * the Web and Swift adapters, so the three cannot drift.
 *
 * Robolectric is required because `org.json` is stubbed in plain Android unit
 * tests.
 */
@RunWith(RobolectricTestRunner::class)
class OpenAIProviderStreamTest {
    private fun fixture(): JSONObject {
        var directory: File? = File("").absoluteFile
        while (directory != null) {
            val candidate = File(directory, "contracts/fixtures/streaming/openai-responses-transcript.json")
            if (candidate.isFile) return JSONObject(candidate.readText(Charsets.UTF_8))
            directory = directory.parentFile
        }
        error("Could not locate contracts/fixtures/streaming/openai-responses-transcript.json")
    }

    private fun provider() = OpenAIProvider(
        OpenAIProviderOptions(model = "gpt-5.2", endpointUrl = "https://proxy.test/v1/responses"),
    )

    private fun host(streaming: HttpStreamingClientService?): HostServices = HostServices(
        connectivity = object : ConnectivityService {
            override fun isOnline(): Boolean = true
        },
        secureStorage = object : SecureStorageService {
            override fun get(authContextRef: String): String? = "sk-test"
            override fun put(authContextRef: String, value: String) = Unit
            override fun remove(authContextRef: String) = Unit
        },
        clock = object : ClockService {
            override fun elapsedRealtimeMillis(): Long = 0L
        },
        // capabilities() probes endpoint reachability over the unary client
        // before it reports anything about streaming.
        httpClient = object : HttpClientService {
            override suspend fun send(request: HttpRequest): HttpResponse = HttpResponse(body = "{}", headers = emptyMap(), status = 200L, statusText = "OK")
        },
        streamingHttpClient = streaming,
    )

    private fun request() = TaskRequest(
        schemaVersion = SchemaVersion.V1_0,
        prompt = "Hello",
        task = TaskRequestTask(),
        authContextRef = "openai_default",
    )

    private suspend fun collect(streaming: HttpStreamingClientService): List<ProviderStreamEvent> = provider().stream(
        request(),
        ProviderStreamContext(
            runId = "run-1",
            hostServices = host(streaming),
            cancellation = StreamCancellationToken(),
        ),
    ).toList()

    @Test
    fun declaresStreamingAndATokenStreamingStyle() {
        val descriptor = provider().describe()
        assertTrue(descriptor.supports.streaming)
        assertEquals(ProviderDescriptor.StreamingStyle.tokens, descriptor.streamingStyle)
        assertEquals(ProviderDescriptor.CancelSemantics.hard, descriptor.cancel)
    }

    @Test
    fun reportsStreamingUnavailableWhenTheHostCannotStream() = runTest {
        val capabilities = provider().capabilities(host(null))

        assertEquals(false, capabilities.streamingAvailable)
        assertEquals(
            "Host does not provide an HttpStreamingClientService, which OpenAI streaming requires.",
            capabilities.streamingUnavailableReason,
        )
    }

    @Test
    fun doesNotReportAStreamingRestrictionWhenTheHostCanStream() = runTest {
        val capabilities = provider().capabilities(host(ScriptedStreamingClient(emptyList())))

        assertTrue(capabilities.available)
        assertNull(capabilities.streamingAvailable)
    }

    @Test
    fun asksTheEndpointToStreamAndAuthenticatesWithTheResolvedCredential() = runTest {
        val client = ScriptedStreamingClient(
            listOf("""data: {"type":"response.completed","response":{"output_text":"hi"}}""" + "\n\n"),
        )
        collect(client)

        val sent = client.requests.first()
        val body = JSONObject(sent.body!!)
        assertEquals(true, body.getBoolean("stream"))
        assertEquals("gpt-5.2", body.getString("model"))
        assertEquals("Bearer sk-test", sent.headers?.get("Authorization"))
        assertEquals("text/event-stream", sent.headers?.get("Accept"))
    }

    @Test
    fun matchesTheSharedTranscriptVectors() = runTest {
        val cases = fixture().getJSONArray("cases")
        assertTrue(cases.length() > 0)

        for (index in 0 until cases.length()) {
            val transcript = cases.getJSONObject(index)
            val label = "${transcript.getString("name")}: ${transcript.getString("description")}"
            val events = collect(ScriptedStreamingClient(listOf(transcript.getString("sse"))))
            val expected = transcript.getJSONArray("expected")

            assertEquals(label, expected.length(), events.size)
            for (position in 0 until expected.length()) {
                val want = expected.getJSONObject(position)
                when (val got = events[position]) {
                    is ProviderStreamEvent.Delta ->
                        assertEquals(label, want.getString("text"), got.text)

                    is ProviderStreamEvent.Done -> {
                        assertEquals(label, want.getString("finalText"), got.finalText)
                        assertEquals(
                            label,
                            FinishReason.entries.first { it.rawValue == want.getString("finishReason") },
                            got.finishReason,
                        )
                        val wantUsage = want.optJSONObject("usage")
                        assertEquals(
                            label,
                            wantUsage?.getLong("totalTokens"),
                            got.usage?.totalTokens,
                        )
                    }

                    is ProviderStreamEvent.Failure -> {
                        val exception = got.error as IndeRunException
                        assertEquals(
                            label,
                            IndeRunErrorClass.valueOf(want.getString("errorClass")),
                            exception.errorClass,
                        )
                        assertEquals(label, want.getString("message"), exception.message)
                    }

                    else -> error("Unexpected event $got in $label")
                }
            }
        }
    }

    @Test
    fun isUnaffectedByHowTheEventStreamIsChunked() = runTest {
        val transcript = fixture().getJSONArray("cases").getJSONObject(0)
        val chunks = transcript.getString("sse").map { it.toString() }

        val events = collect(ScriptedStreamingClient(chunks))

        assertEquals(transcript.getJSONArray("expected").length(), events.size)
    }

    @Test
    fun classifiesANonSuccessResponseBeforeReadingTheBodyAsAnEventStream() = runTest {
        val client = ScriptedStreamingClient(
            chunks = listOf("""{"error":{"message":"Rate limit reached"}}"""),
            status = 429L,
            statusText = "Too Many Requests",
            headers = mapOf("retry-after" to "3"),
        )

        val error = runCatching { collect(client) }.exceptionOrNull() as? IndeRunException

        assertEquals(IndeRunErrorClass.RateLimited, error?.errorClass)
        assertEquals(3000L, error?.retryAfterMs)
    }

    @Test
    fun refusesToStreamWhenTheHostHasNoStreamingClient() = runTest {
        val error = runCatching {
            provider().stream(
                request(),
                ProviderStreamContext(
                    runId = "run-1",
                    hostServices = host(null),
                    cancellation = StreamCancellationToken(),
                ),
            ).toList()
        }.exceptionOrNull() as? IndeRunException

        assertEquals(IndeRunErrorClass.Unavailable, error?.errorClass)
    }

    @Test
    fun stopsReadingOnceTheCallersTokenIsCancelled() = runTest {
        val cancellation = StreamCancellationToken()
        val client = ScriptedStreamingClient(
            listOf(
                """data: {"type":"response.output_text.delta","delta":"one"}""" + "\n\n",
                """data: {"type":"response.output_text.delta","delta":"two"}""" + "\n\n",
            ),
        )

        val events = mutableListOf<ProviderStreamEvent>()
        provider().stream(
            request(),
            ProviderStreamContext(runId = "run-1", hostServices = host(client), cancellation = cancellation),
        ).collect { event ->
            events += event
            cancellation.cancel("stop")
        }

        assertEquals(listOf(ProviderStreamEvent.Delta("one")), events)
    }
}

private class ScriptedStreamingClient(
    private val chunks: List<String>,
    private val status: Long = 200L,
    private val statusText: String = "OK",
    private val headers: Map<String, String> = mapOf("content-type" to "text/event-stream"),
) : HttpStreamingClientService {
    val requests = mutableListOf<HttpRequest>()

    override suspend fun stream(request: HttpRequest): HttpStreamResponse {
        requests += request
        return HttpStreamResponse(
            status = status,
            statusText = statusText,
            headers = headers,
            body = bodyFlow(),
        )
    }

    private fun bodyFlow(): Flow<ByteArray> = flow {
        for (chunk in chunks) {
            emit(chunk.toByteArray(Charsets.UTF_8))
        }
    }
}
