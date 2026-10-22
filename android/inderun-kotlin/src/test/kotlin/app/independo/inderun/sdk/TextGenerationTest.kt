package app.independo.inderun.sdk

import app.independo.inderun.contracts.AttemptOutcome
import app.independo.inderun.contracts.CancelSemantics
import app.independo.inderun.contracts.Cloud
import app.independo.inderun.contracts.ExecutionProvenance
import app.independo.inderun.contracts.ExecutionProvenanceAttempt
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.Locality
import app.independo.inderun.contracts.Message
import app.independo.inderun.contracts.MessageRole
import app.independo.inderun.contracts.OptimizeFor
import app.independo.inderun.contracts.Payload
import app.independo.inderun.contracts.Privacy
import app.independo.inderun.contracts.ProviderCapabilitySnapshot
import app.independo.inderun.contracts.ProviderDescriptor
import app.independo.inderun.contracts.ProviderDynamicCapabilities
import app.independo.inderun.contracts.ProviderSupports
import app.independo.inderun.contracts.ProviderTransport
import app.independo.inderun.contracts.ProviderType
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.StreamEvent
import app.independo.inderun.contracts.StreamRunHandle
import app.independo.inderun.contracts.StreamTerminalOutcomeError
import app.independo.inderun.contracts.StreamTerminalOutcomeTelemetry
import app.independo.inderun.contracts.TaskOutput
import app.independo.inderun.contracts.TaskOutputType
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestTelemetry
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TaskResultTelemetry
import app.independo.inderun.contracts.TelemetryLevel
import app.independo.inderun.core.ClockService
import app.independo.inderun.core.ConnectivityService
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderAdapter
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.SecureStorageService
import app.independo.inderun.core.StreamRun
import app.independo.inderun.core.cancelledOutcome
import app.independo.inderun.core.completedOutcome
import app.independo.inderun.core.contentPayload
import app.independo.inderun.core.errorOutcome
import app.independo.inderun.core.toPayload
import app.independo.inderun.sdk.generated.IndeRunApi
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.isActive
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File
import java.io.IOException

/**
 * An [IndeRunApi] that records requests and answers with a fixed result or a scripted event
 * sequence: the facade is tested against the interface, not an engine.
 */
private class FakeApi(
    private val result: TaskResult? = null,
    private val events: List<StreamEvent> = emptyList(),
    private val source: Flow<StreamEvent>? = null,
) : IndeRunApi {
    val requests = mutableListOf<TaskRequest>()
    val cancels = mutableListOf<String?>()

    override suspend fun run(request: TaskRequest): TaskResult {
        requests += request
        return result!!
    }

    override suspend fun stream(request: TaskRequest): StreamRun {
        requests += request
        return StreamRun(
            handle = StreamRunHandle(providerId = "p1", runId = "run_1", schemaVersion = SchemaVersion.V1_0, startedAt = 0.0),
            events = source ?: flowOf(*events.toTypedArray()),
        ) { reason -> cancels += reason }
    }

    override suspend fun checkCapabilities(): List<ProviderCapabilitySnapshot> = emptyList()
}

@RunWith(RobolectricTestRunner::class)
class TextGenerationTest {
    // --- shared facade vectors ---------------------------------------------------------------

    private fun fixtureCases(): List<JSONObject> {
        var directory: File? = File("").absoluteFile
        while (directory != null) {
            val candidate = File(directory, "contracts/fixtures/facade/text-generation.json")
            if (candidate.exists()) {
                val cases = JSONObject(candidate.readText()).getJSONArray("cases")
                return (0 until cases.length()).map { cases.getJSONObject(it) }
            }
            directory = directory.parentFile
        }
        error("Could not locate contracts/fixtures/facade/text-generation.json")
    }

    private fun JSONArray.strings(): List<String> = (0 until length()).map { getString(it) }

    private fun messagesFrom(array: JSONArray): List<Message> = (0 until array.length()).map {
        val message = array.getJSONObject(it)
        Message(
            role = MessageRole.fromRawValue(message.getString("role"))!!,
            content = message.getString("content"),
        )
    }

    private fun JSONObject.stringOrNull(key: String): String? = if (has(key)) getString(key) else null

    private fun optionsFrom(json: JSONObject) = TextGenerationOptions(
        prompt = json.stringOrNull("prompt"),
        messages = json.optJSONArray("messages")?.let(::messagesFrom),
        model = json.stringOrNull("model"),
        system = json.stringOrNull("system"),
        maxOutputTokens = if (json.has("maxOutputTokens")) json.getLong("maxOutputTokens") else null,
        temperature = if (json.has("temperature")) json.getDouble("temperature") else null,
        topP = if (json.has("topP")) json.getDouble("topP") else null,
        stop = json.optJSONArray("stop")?.strings(),
        seed = if (json.has("seed")) json.getLong("seed") else null,
        execution = json.optJSONObject("execution")?.let { execution ->
            TextExecutionOptions(
                privacy = execution.stringOrNull("privacy")?.let(Privacy::fromRawValue),
                cloud = execution.stringOrNull("cloud")?.let(Cloud::fromRawValue),
                timeoutMs = if (execution.has("timeoutMs")) execution.getLong("timeoutMs") else null,
                optimizeFor = execution.stringOrNull("optimizeFor")?.let(OptimizeFor::fromRawValue),
            )
        },
        authContextRef = json.stringOrNull("authContextRef"),
        telemetry = json.optJSONObject("telemetry")?.let { telemetry ->
            TaskRequestTelemetry(
                consent = if (telemetry.has("consent")) telemetry.getBoolean("consent") else null,
                level = telemetry.stringOrNull("level")?.let(TelemetryLevel::fromRawValue),
                tags = telemetry.optJSONObject("tags")?.let { tags ->
                    tags.keys().asSequence().associateWith { tags.getString(it) }
                },
            )
        },
        requestId = json.stringOrNull("requestId"),
    )

    /**
     * The canonical request as plain JSON-shaped values, so it compares against the fixture's
     * expectation without a JSON serializer for the generated contracts.
     */
    private fun TaskRequest.toJsonValue(): Map<String, Any?> = buildMap {
        put("schemaVersion", schemaVersion.rawValue)
        put("task", mapOf("kind" to task.kind.rawValue))
        prompt?.let { put("prompt", it) }
        messages?.let { list -> put("messages", list.map { mapOf("role" to it.role.rawValue, "content" to it.content) }) }
        modelProfile?.let { put("modelProfile", it) }
        generation?.let { generation ->
            put(
                "generation",
                buildMap {
                    generation.maxOutputTokens?.let { put("maxOutputTokens", it) }
                    generation.temperature?.let { put("temperature", it) }
                    generation.topP?.let { put("topP", it) }
                    generation.stop?.let { put("stop", it) }
                    generation.seed?.let { put("seed", it) }
                },
            )
        }
        constraints?.let { constraints ->
            put(
                "constraints",
                buildMap {
                    constraints.privacy?.let { put("privacy", it.rawValue) }
                    constraints.cloud?.let { put("cloud", it.rawValue) }
                    constraints.timeoutMs?.let { put("timeoutMs", it) }
                },
            )
        }
        preferences?.optimizeFor?.let { put("preferences", mapOf("optimizeFor" to it.rawValue)) }
        authContextRef?.let { put("authContextRef", it) }
        telemetry?.let { telemetry ->
            put(
                "telemetry",
                buildMap {
                    telemetry.consent?.let { put("consent", it) }
                    telemetry.level?.let { put("level", it.rawValue) }
                    telemetry.tags?.let { put("tags", it) }
                },
            )
        }
        requestId?.let { put("requestId", it) }
    }

    private fun Any?.normalized(): Any? = when (this) {
        is JSONObject -> keys().asSequence().associateWith { get(it).normalized() }
        is JSONArray -> (0 until length()).map { get(it).normalized() }
        is Map<*, *> -> entries.associate { (key, value) -> key to value.normalized() }
        is List<*> -> map { it.normalized() }
        is Int -> toLong()
        is Float -> toDouble()
        else -> this
    }

    @Test
    fun matchesTheSharedFacadeVectors() {
        val cases = fixtureCases()
        assertTrue(cases.isNotEmpty())
        for (vector in cases) {
            val request = optionsFrom(vector.getJSONObject("options")).toTaskRequest()
            assertEquals(
                vector.getString("id"),
                vector.getJSONObject("expected").normalized(),
                request.toJsonValue().normalized(),
            )
        }
    }

    @Test(expected = IllegalArgumentException::class)
    fun refusesOptionsWithBothPromptAndMessages() {
        TextGenerationOptions(prompt = "Hi", messages = listOf(Message(role = MessageRole.USER, content = "Hi")))
    }

    // --- generateText ------------------------------------------------------------------------

    @Test
    fun generateTextRunsTheCanonicalRequestAndSummarizesTheResult() = runTest {
        val taskResult = TaskResult(
            finishReason = FinishReason.STOP,
            output = TaskOutput(type = TaskOutputType.TEXT, text = "Hello"),
            runId = "run_1",
            schemaVersion = SchemaVersion.V1_0,
            telemetry = TaskResultTelemetry(providerUsed = "p1", totalMs = 5.0),
            provenance = provenance(AttemptOutcome.Succeeded),
        )
        val api = FakeApi(result = taskResult)

        val generated = api.generateText(TextGenerationOptions(prompt = "Hi", model = "smart"))

        assertEquals("smart", api.requests.single().modelProfile)
        assertEquals("Hello", generated.text)
        assertEquals(FinishReason.STOP, generated.finishReason)
        assertEquals("run_1", generated.runId)
        assertEquals(taskResult.provenance, generated.provenance)
    }

    @Test
    fun generateTextMatchesADirectRunOnARealEngine() = runTest {
        val provider = object : ProviderAdapter {
            override fun describe() = ProviderDescriptor(
                id = "local_a",
                type = ProviderType.Local,
                transport = ProviderTransport.InProcess,
                supports = ProviderSupports(
                    run = true,
                    streaming = false,
                    realtime = false,
                    tools = false,
                    reasoningEvents = false,
                    structuredOutput = false,
                    multimodal = false,
                ),
                cancel = CancelSemantics.None,
                tasks = listOf("text_to_text"),
            )

            override suspend fun capabilities(host: HostServices) = ProviderDynamicCapabilities(available = true)

            override suspend fun run(request: TaskRequest, context: RunContext) = TaskResult(
                finishReason = FinishReason.STOP,
                output = TaskOutput(type = TaskOutputType.TEXT, text = "Echo: ${request.prompt}"),
                runId = context.runId,
                schemaVersion = SchemaVersion.V1_0,
                telemetry = TaskResultTelemetry(providerUsed = "local_a", totalMs = 0.0),
            )
        }
        val engine = IndeRun(
            ProviderRegistry().apply { register(provider) },
            HostServices(
                connectivity = object : ConnectivityService {
                    override fun isOnline(): Boolean = true
                },
                secureStorage = object : SecureStorageService {
                    override fun get(authContextRef: String): String? = null
                    override fun put(authContextRef: String, value: String) = Unit
                    override fun remove(authContextRef: String) = Unit
                },
                clock = object : ClockService {
                    override fun elapsedRealtimeMillis(): Long = 0L
                },
            ),
        )
        val options = TextGenerationOptions(prompt = "Hi", requestId = "req-1")

        val viaFacade = engine.generateText(options)
        val direct = engine.run(options.toTaskRequest())

        assertEquals(direct, viaFacade.taskResult)
        assertEquals(direct.provenance, viaFacade.provenance)
    }

    // --- streamText --------------------------------------------------------------------------

    private var sequence = 0L

    private fun event(type: String, payload: Payload) = StreamEvent(
        payload = payload,
        runId = "run_1",
        schemaVersion = SchemaVersion.V1_0,
        sequence = sequence++,
        timestamp = 0.0,
        type = type,
    )

    private fun provenance(outcome: AttemptOutcome) = ExecutionProvenance(
        attemptCount = 1,
        attempts = listOf(ExecutionProvenanceAttempt(outcome = outcome, providerId = "p1")),
        fallbackOccurred = false,
        locality = Locality.OnDevice,
        modelProfile = "auto",
        providerId = "p1",
        routeRejections = emptyList(),
    )

    private fun completed(finalText: String) = event(
        "terminal",
        completedOutcome(
            runId = "run_1",
            finalText = finalText,
            finishReason = FinishReason.STOP,
            usage = null,
            telemetry = StreamTerminalOutcomeTelemetry(providerUsed = "p1", totalMs = 1.0),
            provenance = provenance(AttemptOutcome.Succeeded),
        ).toPayload(),
    )

    @Test
    fun streamTextExposesIncrementsEventsAndResultInAnyOrder() = runTest {
        val events = listOf(
            event("content_delta", contentPayload("Hel")),
            event("content_delta", contentPayload("lo")),
            completed("Hello"),
        )
        val stream = FakeApi(events = events).streamText(TextGenerationOptions(prompt = "Hi"), backgroundScope)

        val result = stream.result.await()
        assertEquals("Hello", result.text)
        assertEquals("p1", result.provenance?.providerId)
        assertEquals(listOf("Hel", "lo"), stream.textStream.toList())
        assertEquals(events, stream.fullStream.toList())
    }

    @Test
    fun streamTextTurnsAnExtendingSnapshotIntoTheNewSuffix() = runTest {
        val stream = FakeApi(
            events = listOf(
                event("content_snapshot", contentPayload("Loc")),
                event("content_snapshot", contentPayload("Local first")),
                completed("Local first"),
            ),
        ).streamText(TextGenerationOptions(prompt = "Hi"), backgroundScope)

        assertEquals(listOf("Loc", "al first"), stream.textStream.toList())
    }

    @Test
    fun streamTextEndsTheTextViewWhenDeliveredTextIsRetracted() = runTest {
        val stream = FakeApi(
            events = listOf(
                event("content_snapshot", contentPayload("Draft")),
                event("content_snapshot", contentPayload("")),
                completed(""),
            ),
        ).streamText(TextGenerationOptions(prompt = "Hi"), backgroundScope)

        val failure = runCatching { stream.textStream.toList() }.exceptionOrNull()
        assertTrue(failure is TextStreamRetractedException)
        assertEquals("", stream.result.await().text)
    }

    @Test
    fun streamTextFailsWithTheRunsErrorAndProvenance() = runTest {
        val stream = FakeApi(
            events = listOf(
                event("content_delta", contentPayload("partial")),
                event(
                    "terminal",
                    errorOutcome(
                        runId = "run_1",
                        error = StreamTerminalOutcomeError(errorClass = IndeRunErrorClass.RateLimited, message = "Slow down"),
                        partialText = "partial",
                        provenance = provenance(AttemptOutcome.Failed),
                    ).toPayload(),
                ),
            ),
        ).streamText(TextGenerationOptions(prompt = "Hi"), backgroundScope)

        val error = runCatching { stream.result.await() }.exceptionOrNull() as IndeRunException
        assertEquals(IndeRunErrorClass.RateLimited, error.errorClass)
        assertEquals("run_1", error.runId)
        assertEquals(AttemptOutcome.Failed, error.provenance?.attempts?.single()?.outcome)
        val textFailure = runCatching { stream.textStream.toList() }.exceptionOrNull() as IndeRunException
        assertEquals(IndeRunErrorClass.RateLimited, textFailure.errorClass)
    }

    @Test
    fun streamTextCompletesACancelledRunWithItsPartialTextAndForwardsCancel() = runTest {
        val api = FakeApi(
            events = listOf(
                event("content_delta", contentPayload("one")),
                event(
                    "terminal",
                    cancelledOutcome(
                        runId = "run_1",
                        partialText = "one",
                        reason = "user stopped",
                        provenance = provenance(AttemptOutcome.Cancelled),
                    ).toPayload(),
                ),
            ),
        )
        val stream = api.streamText(TextGenerationOptions(prompt = "Hi"), backgroundScope)
        stream.cancel("user stopped")

        val result = stream.result.await()
        assertEquals("one", result.text)
        assertEquals(FinishReason.CANCELLED, result.finishReason)
        assertEquals(listOf<String?>("user stopped"), api.cancels)
    }

    @Test
    fun streamTextReportsATransportFailureWithoutFailingTheCallersScope() = runTest {
        var uncaught: Throwable? = null
        val scope = CoroutineScope(
            Job() + StandardTestDispatcher(testScheduler) + CoroutineExceptionHandler { _, error -> uncaught = error },
        )
        val api = FakeApi(
            source = flow {
                emit(event("content_delta", contentPayload("par")))
                throw IOException("bridge closed")
            },
        )
        val stream = api.streamText(TextGenerationOptions(prompt = "Hi"), scope)

        assertTrue(runCatching { stream.result.await() }.exceptionOrNull() is IOException)
        assertTrue(runCatching { stream.textStream.toList() }.exceptionOrNull() is IOException)
        testScheduler.advanceUntilIdle()
        assertNull(uncaught)
        assertTrue(scope.isActive)
    }

    @Test
    fun streamTextSettlesOnTheTerminalEventWhenTheSourceStaysOpen() = runTest {
        val api = FakeApi(
            source = flow {
                emit(event("content_delta", contentPayload("Hi")))
                emit(completed("Hi"))
                awaitCancellation()
            },
        )
        val stream = api.streamText(TextGenerationOptions(prompt = "Hi"), backgroundScope)

        assertEquals("Hi", stream.result.await().text)
        assertEquals(listOf("Hi"), stream.textStream.toList())
        assertEquals(listOf("content_delta", "terminal"), stream.fullStream.toList().map { it.type })
    }

    @Test
    fun streamTextReplaysALongStreamToEveryCollector() = runTest {
        val deltas = List(5_000) { "t$it " }
        val stream = FakeApi(
            events = deltas.map { event("content_delta", contentPayload(it)) } + completed(deltas.joinToString("")),
        ).streamText(TextGenerationOptions(prompt = "Hi"), backgroundScope)

        assertEquals(deltas, stream.textStream.toList())
        assertEquals(deltas.size + 1, stream.fullStream.toList().size)
        assertEquals(deltas.joinToString(""), stream.result.await().text)
    }
}
