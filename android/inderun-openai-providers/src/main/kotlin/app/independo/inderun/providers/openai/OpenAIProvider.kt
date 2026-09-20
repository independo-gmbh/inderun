package app.independo.inderun.providers.openai

import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.HttpRequest
import app.independo.inderun.contracts.Method
import app.independo.inderun.contracts.Output
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TaskResultTelemetry
import app.independo.inderun.contracts.TaskResultUsage
import app.independo.inderun.core.ClockService
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.HttpClientService
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderDescriptor
import app.independo.inderun.core.ProviderDynamicCapabilities
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.core.ProviderStreamContext
import app.independo.inderun.core.ProviderStreamEvent
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.SseEvent
import app.independo.inderun.core.SseParser
import app.independo.inderun.core.StreamingProviderAdapter
import app.independo.inderun.core.createAuthError
import app.independo.inderun.core.createInternal
import app.independo.inderun.core.createRateLimited
import app.independo.inderun.core.createTimeout
import app.independo.inderun.core.createUnavailable
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.FlowCollector
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.takeWhile
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.util.Date

const val DEFAULT_OPENAI_RESPONSES_ENDPOINT: String = "https://api.openai.com/v1/responses"

private const val DEFAULT_HEALTH_CHECK_TIMEOUT_MS: Long = 3000L
private const val DEFAULT_HEALTH_CHECK_CACHE_MS: Long = 5000L

enum class OpenAIAuthMode {
    authContextRef,
    none,
}

data class OpenAIProviderOptions(
    val id: String = "openai",
    val model: String,
    val endpointUrl: String = DEFAULT_OPENAI_RESPONSES_ENDPOINT,
    val auth: OpenAIAuthMode = OpenAIAuthMode.authContextRef,
    val authContextRef: String? = null,
    val timeoutMs: Long? = null,
    /**
     * Timeout for the endpoint reachability probe issued from [OpenAIProvider.capabilities].
     * Defaults to 3000ms. The OpenAI API has no dedicated health endpoint, so this is a cheap
     * unauthenticated GET against the configured endpoint.
     */
    val healthCheckTimeoutMs: Long? = null,
    /**
     * How long a reachability probe result is cached before [OpenAIProvider.capabilities]
     * re-probes. Defaults to 5000ms.
     */
    val healthCheckCacheMs: Long? = null,
)

/**
 * Unwinds the collection loop once a terminal event has been produced. Kotlin
 * flows have no `break`, and abandoning the collector by throwing is the
 * documented way to stop consuming one early.
 */
private object StreamTerminated : Throwable(null, null, false, false)

class OpenAIProvider(
    private val options: OpenAIProviderOptions,
) : StreamingProviderAdapter {
    @Volatile
    private var cachedHealth: Pair<ProviderDynamicCapabilities, Long>? = null
    override fun describe(): ProviderDescriptor = ProviderDescriptor(
        id = options.id,
        type = ProviderDescriptor.ProviderType.cloud,
        transport = ProviderDescriptor.TransportType.http,
        streamingStyle = ProviderDescriptor.StreamingStyle.tokens,
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
        privacy = ProviderDescriptor.PrivacyDescriptor(dataLeavesDevice = true),
    )

    /**
     * Reports dynamic provider availability for the current host.
     *
     * After the static host-service check passes, this probes endpoint reachability with a
     * cheap unauthenticated GET against the configured endpoint (the OpenAI API has no
     * dedicated health endpoint). The result is cached for [OpenAIProviderOptions.healthCheckCacheMs]
     * so routing decisions and repeated UI capability checks don't re-probe on every call.
     */
    override suspend fun capabilities(host: HostServices): ProviderDynamicCapabilities {
        val httpClient = host.httpClient
            ?: return ProviderDynamicCapabilities(
                available = false,
                reason = "OpenAI Responses provider requires an HttpClientService.",
            )

        val reachability = checkEndpointReachable(httpClient, host.clock)
        if (host.streamingHttpClient != null) {
            return reachability
        }

        // Mode 1 still works without it; only streaming is taken away, and the
        // planner turns this into an inspectable `streaming_unavailable`
        // rejection rather than an unexplained routing failure.
        return reachability.copy(
            streamingAvailable = false,
            streamingUnavailableReason =
            "Host does not provide an HttpStreamingClientService, which OpenAI streaming requires.",
        )
    }

    private suspend fun checkEndpointReachable(
        httpClient: HttpClientService,
        clock: ClockService,
    ): ProviderDynamicCapabilities {
        val now = clock.elapsedRealtimeMillis()
        val cacheMs = options.healthCheckCacheMs ?: DEFAULT_HEALTH_CHECK_CACHE_MS
        cachedHealth?.let { (result, checkedAt) ->
            if (now - checkedAt < cacheMs) {
                return result
            }
        }

        val result = try {
            val response = httpClient.send(
                HttpRequest(
                    method = Method.Get,
                    url = options.endpointUrl,
                    timeoutMs = options.healthCheckTimeoutMs ?: DEFAULT_HEALTH_CHECK_TIMEOUT_MS,
                ),
            )
            if (response.status >= 500) {
                ProviderDynamicCapabilities(
                    available = false,
                    reason = "OpenAI Responses endpoint returned HTTP ${response.status}.",
                )
            } else {
                ProviderDynamicCapabilities(available = true)
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            ProviderDynamicCapabilities(
                available = false,
                reason = "OpenAI Responses endpoint is unreachable.",
            )
        }

        cachedHealth = result to now
        return result
    }

    override suspend fun run(request: TaskRequest, context: RunContext): TaskResult {
        val startTimeMs = context.hostServices.clock.elapsedRealtimeMillis().toDouble()
        val httpClient = context.hostServices.httpClient
            ?: throw createUnavailable(
                message = "OpenAI Responses provider requires an HTTP client.",
                runId = context.runId,
                providerId = options.id,
            )

        val headers = resolveHeaders(request, context.hostServices, context.runId)

        val httpRequest = HttpRequest(
            method = Method.Post,
            url = options.endpointUrl,
            headers = headers,
            body = createRequestBody(request).toString(),
            timeoutMs = options.timeoutMs,
        )

        val response = try {
            httpClient.send(httpRequest)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            throw createUnavailable(
                message = "OpenAI Responses request failed before a response was received.",
                runId = context.runId,
                providerId = options.id,
                details = mapOf(
                    "originalError" to mapOf(
                        "name" to error::class.simpleName,
                        "message" to (error.message ?: error.toString()),
                    ),
                ),
            )
        }

        if (response.status < 200 || response.status >= 300) {
            throw mapHttpError(
                status = response.status.toInt(),
                statusText = response.statusText,
                headers = response.headers,
                body = response.body,
                runId = context.runId,
            )
        }

        val json = parseJsonObject(response.body)
        val outputText = extractOutputText(json)
            ?: throw createInternal(
                message = "OpenAI Responses payload did not contain text output.",
                runId = context.runId,
                providerId = options.id,
            )

        val usage = usage(json)

        val totalMs = context.hostServices.clock.elapsedRealtimeMillis().toDouble() - startTimeMs
        return TaskResult(
            finishReason = finishReason(json),
            output = Output(text = outputText),
            runId = context.runId,
            schemaVersion = SchemaVersion.V1_0,
            telemetry = TaskResultTelemetry(providerUsed = options.id, totalMs = totalMs),
            usage = usage,
        )
    }

    /**
     * Executes a normalized text-to-text task in Mode 2 against the OpenAI
     * Responses API's server-sent event stream.
     *
     * The request is the Mode 1 body plus `"stream": true`, so both modes stay a
     * single code path up to the transport. The response head is classified
     * before the body is read: a non-2xx is drained to text and run through the
     * same [mapHttpError] as Mode 1, because a 429 must surface as RateLimited
     * rather than as a malformed event stream.
     *
     * Event mapping, from the Responses API's typed SSE events to the canonical
     * provider vocabulary:
     *
     * - `response.output_text.delta` becomes a delta;
     * - `response.completed` and `response.incomplete` become the terminal done,
     *   with `finalText`, `usage` and `finishReason` read off the embedded
     *   response object by the same helpers Mode 1 uses — it has the same shape;
     * - `response.failed` and `error` become a terminal failure;
     * - every other event type is ignored, since the set is open and additive.
     */
    override fun stream(
        request: TaskRequest,
        context: ProviderStreamContext,
    ): Flow<ProviderStreamEvent> = flow {
        val streamingClient = context.hostServices.streamingHttpClient
            ?: throw createUnavailable(
                message = "OpenAI Responses streaming requires an HttpStreamingClientService.",
                runId = context.runId,
                providerId = options.id,
            )

        val headers = resolveHeaders(request, context.hostServices, context.runId)
        headers["Accept"] = "text/event-stream"

        val httpRequest = HttpRequest(
            method = Method.Post,
            url = options.endpointUrl,
            headers = headers,
            body = createRequestBody(request, stream = true).toString(),
            timeoutMs = options.timeoutMs,
        )

        val response = try {
            streamingClient.stream(httpRequest)
        } catch (error: CancellationException) {
            throw error
        } catch (error: IndeRunException) {
            // The transport already classified this — a head timeout must stay a
            // Timeout rather than being flattened into Unavailable here.
            throw error
        } catch (error: Throwable) {
            throw createUnavailable(
                message = "OpenAI Responses stream failed before a response was received.",
                runId = context.runId,
                providerId = options.id,
                details = mapOf(
                    "originalError" to mapOf(
                        "name" to error::class.simpleName,
                        "message" to (error.message ?: error.toString()),
                    ),
                ),
            )
        }

        if (response.status < 200 || response.status >= 300) {
            val errorBody = StringBuilder()
            response.body.collect { chunk -> errorBody.append(String(chunk, Charsets.UTF_8)) }
            throw mapHttpError(
                status = response.status.toInt(),
                statusText = response.statusText,
                headers = response.headers,
                body = errorBody.toString(),
                runId = context.runId,
            )
        }

        val parser = SseParser()
        var terminated = false
        try {
            response.body.takeWhile { !context.cancellation.isCancelled }.collect { chunk ->
                for (sseEvent in parser.consume(chunk)) {
                    if (emitStreamEvent(sseEvent, context)) {
                        terminated = true
                        throw StreamTerminated
                    }
                }
            }
            if (!context.cancellation.isCancelled) {
                for (sseEvent in parser.finish()) {
                    if (emitStreamEvent(sseEvent, context)) {
                        terminated = true
                        break
                    }
                }
            }
        } catch (signal: StreamTerminated) {
            check(terminated) { "StreamTerminated raised without a terminal event." }
        }

        // Falling through without a terminal event means the stream ended early.
        // The engine reports that as a provider fault; inventing a completion
        // from whatever deltas happened to arrive would hide a truncated
        // response.
    }

    /**
     * Maps one framed SSE event onto the provider vocabulary. Returns true when
     * the event was terminal and the stream should stop being read.
     */
    private suspend fun FlowCollector<ProviderStreamEvent>.emitStreamEvent(
        sseEvent: SseEvent,
        context: ProviderStreamContext,
    ): Boolean {
        if (sseEvent.data == "[DONE]") return false

        val json = parseJsonObject(sseEvent.data)
        // The `event:` line and the payload's own `type` carry the same value;
        // prefer the payload so a proxy that drops event names still works.
        val type = json.optStringOrNull("type") ?: sseEvent.event

        when (type) {
            "response.output_text.delta" -> {
                json.optStringOrNull("delta")?.let { emit(ProviderStreamEvent.Delta(it)) }
                return false
            }

            "response.completed", "response.incomplete" -> {
                val body = json.optJSONObject("response") ?: JSONObject()
                emit(
                    ProviderStreamEvent.Done(
                        finalText = extractOutputText(body).orEmpty(),
                        finishReason = finishReason(body),
                        usage = usage(body),
                    ),
                )
                return true
            }

            "response.failed", "error" -> {
                emit(ProviderStreamEvent.Failure(mapStreamError(json, context.runId)))
                return true
            }

            else -> return false
        }
    }

    /**
     * Maps a `response.failed` / `error` stream event onto the error taxonomy.
     * These arrive over an HTTP 200 body, so there is no status code to classify
     * from; OpenAI reports rate limiting and auth failures here with the same
     * `code` values it uses in unary error bodies.
     *
     * Two payload shapes exist and both are accepted: the standalone `error`
     * event carries `code`/`message` at its root, while `response.failed` nests
     * them under `response.error`. The root `type` is the event name rather than
     * an error type, so it is never read as one.
     */
    private fun mapStreamError(json: JSONObject, runId: String): Throwable {
        val nested = json.optJSONObject("error")
            ?: json.optJSONObject("response")?.optJSONObject("error")
            ?: JSONObject()
        val message = nested.optStringOrNull("message")
            ?: json.optStringOrNull("message")
            ?: "OpenAI Responses stream reported a failure."
        val code = nested.optStringOrNull("code") ?: json.optStringOrNull("code")
        val details = mapOf(
            "errorType" to nested.optStringOrNull("type"),
            "errorCode" to code,
        )

        return when (code) {
            "rate_limit_exceeded" -> createRateLimited(
                message = message,
                runId = runId,
                providerId = options.id,
                retryable = true,
                details = details,
            )
            "invalid_api_key", "authentication_error" -> createAuthError(
                message = message,
                runId = runId,
                providerId = options.id,
                details = details,
            )
            else -> createUnavailable(
                message = message,
                runId = runId,
                providerId = options.id,
                retryable = true,
                details = details,
            )
        }
    }

    /**
     * Resolves the request headers, including the bearer token behind
     * `authContextRef`. Shared by [run] and [stream]: the credential never
     * travels in the request payload, only the slot id does, so both modes must
     * resolve it the same way.
     */
    private fun resolveHeaders(
        request: TaskRequest,
        hostServices: HostServices,
        runId: String,
    ): LinkedHashMap<String, String> {
        val headers = linkedMapOf("Content-Type" to "application/json")
        if (options.auth != OpenAIAuthMode.authContextRef) return headers

        val slotId = request.authContextRef ?: options.authContextRef
        if (slotId.isNullOrBlank()) {
            throw createAuthError(
                message = "OpenAI Responses provider requires authContextRef.",
                runId = runId,
                providerId = options.id,
            )
        }

        val secret = hostServices.secureStorage.get(slotId)
        if (secret.isNullOrBlank()) {
            throw createAuthError(
                message = "No OpenAI credential found for authContextRef '$slotId'.",
                runId = runId,
                providerId = options.id,
            )
        }

        headers["Authorization"] = "Bearer $secret"
        return headers
    }

    /** Reads the token counts off a response body, shared by both modes. */
    private fun usage(json: JSONObject): TaskResultUsage? {
        val usageJson = json.optJSONObject("usage") ?: return null
        val inputTokens = usageJson.optLongOrNull("input_tokens")
        val outputTokens = usageJson.optLongOrNull("output_tokens")
        val totalTokens = usageJson.optLongOrNull("total_tokens")
        if (inputTokens == null && outputTokens == null && totalTokens == null) return null

        return TaskResultUsage(
            inputTokens = inputTokens,
            outputTokens = outputTokens,
            totalTokens = totalTokens,
        )
    }

    private fun createRequestBody(request: TaskRequest, stream: Boolean = false): JSONObject {
        val body = JSONObject()
            .put("model", options.model)
            .put("input", createInput(request))

        if (stream) body.put("stream", true)

        request.generation?.maxOutputTokens?.let { body.put("max_output_tokens", it) }
        request.generation?.temperature?.let { body.put("temperature", it) }
        request.generation?.topP?.let { body.put("top_p", it) }
        request.generation?.stop?.let { body.put("stop", JSONArray(it)) }
        return body
    }

    private fun createInput(request: TaskRequest): Any {
        val messages = request.messages
        if (!messages.isNullOrEmpty()) {
            return JSONArray().apply {
                messages.forEach { message ->
                    put(
                        JSONObject()
                            .put("role", if (message.role.rawValue == "system") "developer" else message.role.rawValue)
                            .put("content", message.content),
                    )
                }
            }
        }

        return request.prompt.orEmpty()
    }

    private fun mapHttpError(
        status: Int,
        statusText: String,
        headers: Map<String, String>,
        body: String,
        runId: String,
    ): IndeRunException {
        val json = parseJsonObject(body)
        val error = json.optJSONObject("error")
        val message = error?.optString("message")?.takeIf { it.isNotBlank() }
            ?: "OpenAI Responses request failed with HTTP $status $statusText."
        val details = mutableMapOf<String, Any?>(
            "status" to status,
            "statusText" to statusText,
            "errorType" to error?.optStringOrNull("type"),
            "errorCode" to error?.optStringOrNull("code"),
        )

        return when {
            status == 401 || status == 403 -> createAuthError(
                message = message,
                runId = runId,
                providerId = options.id,
                details = details,
            )

            status == 429 -> createRateLimited(
                message = message,
                runId = runId,
                providerId = options.id,
                retryable = true,
                retryAfterMs = parseRetryAfterMs(headers),
                details = details,
            )

            status == 408 || status == 504 -> createTimeout(
                message = message,
                runId = runId,
                providerId = options.id,
                retryable = true,
                details = details,
            )

            status == 409 || status >= 500 -> createUnavailable(
                message = message,
                runId = runId,
                providerId = options.id,
                retryable = true,
                details = details,
            )

            else -> createInternal(
                message = message,
                runId = runId,
                providerId = options.id,
                details = details,
            )
        }
    }

    private fun extractOutputText(json: JSONObject): String? {
        json.optStringOrNull("output_text")?.let { return it }

        val output = json.optJSONArray("output") ?: return null
        val fragments = buildString {
            for (itemIndex in 0 until output.length()) {
                val item = output.optJSONObject(itemIndex) ?: continue
                val content = item.optJSONArray("content") ?: continue
                for (contentIndex in 0 until content.length()) {
                    val contentItem = content.optJSONObject(contentIndex) ?: continue
                    if (contentItem.optString("type") == "output_text") {
                        val text = contentItem.optStringOrNull("text")
                        if (text != null) {
                            append(text)
                        }
                    }
                }
            }
        }

        return fragments.ifBlank { null }
    }

    private fun finishReason(json: JSONObject): FinishReason {
        if (json.optString("status") == "incomplete") {
            val reason = json.optJSONObject("incomplete_details")?.optString("reason")
            return if (reason == "max_output_tokens") FinishReason.LENGTH else FinishReason.ERROR
        }

        return FinishReason.STOP
    }
}

object AndroidCloudProviderRegistryFactory {
    fun makeOpenAIRegistry(options: OpenAIProviderOptions): ProviderRegistry = ProviderRegistry().apply {
        register(OpenAIProvider(options))
    }
}

private fun parseJsonObject(body: String): JSONObject = try {
    JSONObject(body)
} catch (_: Throwable) {
    JSONObject()
}

private fun JSONObject.optStringOrNull(key: String): String? {
    if (!has(key) || isNull(key)) {
        return null
    }

    return optString(key).takeIf { it.isNotBlank() }
}

private fun JSONObject.optLongOrNull(key: String): Long? {
    if (!has(key) || isNull(key)) {
        return null
    }
    return optLong(key)
}

private fun parseRetryAfterMs(headers: Map<String, String>): Long? {
    val raw = headers["retry-after"] ?: headers["Retry-After"] ?: return null
    raw.toDoubleOrNull()?.let { seconds ->
        return (seconds * 1000).toLong().coerceAtLeast(0L)
    }

    return try {
        val instant = Instant.parse(raw)
        (instant.toEpochMilli() - Date().time).coerceAtLeast(0L)
    } catch (_: Throwable) {
        null
    }
}
