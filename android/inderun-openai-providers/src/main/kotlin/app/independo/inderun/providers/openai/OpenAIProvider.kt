package app.independo.inderun.providers.openai

import app.independo.inderun.contracts.CancelSemantics
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.HttpRequest
import app.independo.inderun.contracts.Method
import app.independo.inderun.contracts.Output
import app.independo.inderun.contracts.ProviderDescriptor
import app.independo.inderun.contracts.ProviderDynamicCapabilities
import app.independo.inderun.contracts.ProviderPrivacy
import app.independo.inderun.contracts.ProviderSupports
import app.independo.inderun.contracts.ProviderTransport
import app.independo.inderun.contracts.ProviderType
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.StreamingStyle
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TaskResultTelemetry
import app.independo.inderun.contracts.TaskResultUsage
import app.independo.inderun.core.ClockService
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.HttpClientService
import app.independo.inderun.core.IndeRunException
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
import java.time.format.DateTimeFormatter

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
 * Options for [AndroidCloudProviderRegistryFactory.makeOpenAIRegistry]: the provider options with
 * [models] in place of the single `model`. One target is registered per model, with id
 * `<id>:<model>`, so model profiles can list each model separately.
 */
data class OpenAIFactoryOptions(
    val id: String = "openai",
    val models: List<String>,
    val endpointUrl: String = DEFAULT_OPENAI_RESPONSES_ENDPOINT,
    val auth: OpenAIAuthMode = OpenAIAuthMode.authContextRef,
    val authContextRef: String? = null,
    val timeoutMs: Long? = null,
    val healthCheckTimeoutMs: Long? = null,
    val healthCheckCacheMs: Long? = null,
) {
    /** The provider options for one target of this factory configuration. */
    fun providerOptions(model: String): OpenAIProviderOptions = OpenAIProviderOptions(
        id = "$id:$model",
        model = model,
        endpointUrl = endpointUrl,
        auth = auth,
        authContextRef = authContextRef,
        timeoutMs = timeoutMs,
        healthCheckTimeoutMs = healthCheckTimeoutMs,
        healthCheckCacheMs = healthCheckCacheMs,
    )
}

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
        type = ProviderType.Cloud,
        model = options.model,
        transport = ProviderTransport.HTTP,
        streamingStyle = StreamingStyle.Tokens,
        supports = ProviderSupports(
            run = true,
            streaming = true,
            realtime = false,
            tools = false,
            reasoningEvents = false,
            structuredOutput = false,
            multimodal = false,
        ),
        cancel = CancelSemantics.Hard,
        tasks = listOf("text_to_text"),
        privacy = ProviderPrivacy(dataLeavesDevice = true),
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
        // A lenient server (OpenRouter among them) can answer 2xx for a run that
        // failed upstream; that is a failure to classify, not an empty answer.
        val reported = json.optJSONObject("error")?.let(::reportedError)
        val status = json.optStringOrNull("status")
        if (status == "failed" || status == "cancelled") {
            throw mapReportedError(
                reported = reported,
                fallbackMessage = "OpenAI Responses run ended with status '$status'.",
                runId = context.runId,
                errorType = json.optRaw("error_type"),
            )
        }

        val outputText = extractOutputText(json)
        if (outputText == null && reported != null) {
            throw mapReportedError(
                reported = reported,
                fallbackMessage = "OpenAI Responses payload reported an error.",
                runId = context.runId,
                errorType = json.optRaw("error_type"),
            )
        }
        if (outputText == null) {
            throw createInternal(
                message = "OpenAI Responses payload did not contain text output.",
                runId = context.runId,
                providerId = options.id,
            )
        }

        val usage = usage(json)

        val totalMs = context.hostServices.clock.elapsedRealtimeMillis().toDouble() - startTimeMs
        return TaskResult(
            finishReason = finishReason(json),
            output = Output(text = outputText),
            runId = context.runId,
            schemaVersion = SchemaVersion.V1_0,
            telemetry = TaskResultTelemetry(
                providerUsed = options.id,
                reportedModel = reportedModel(json),
                totalMs = totalMs,
            ),
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
     * - `response.failed`, `response.error` and `error` become a terminal failure,
     *   as does an untyped event carrying an `error` object (OpenRouter's
     *   documented mid-stream failure shape);
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
                        reportedModel = reportedModel(body),
                    ),
                )
                return true
            }

            "response.failed", "response.error", "error" -> {
                emit(ProviderStreamEvent.Failure(mapStreamError(json, context.runId)))
                return true
            }

            null -> {
                if (json.optJSONObject("error") == null) return false
                emit(ProviderStreamEvent.Failure(mapStreamError(json, context.runId)))
                return true
            }

            else -> return false
        }
    }

    /**
     * Maps a `response.failed` / `response.error` / `error` stream event onto the
     * error taxonomy. These arrive over an HTTP 200 body, so there is no status
     * code to classify from; the event's own `code` is classified instead.
     *
     * Two payload shapes exist and both are accepted: the standalone `error`
     * event carries `code`/`message` at its root, while `response.failed` nests
     * them under `response.error` and some servers nest them under `error`. The
     * root `type` is the event name rather than an error type, so it is never
     * read as one. OpenRouter's typed classification comes from the embedded
     * response (`response.failed`) or the error's metadata (untyped events).
     */
    private fun mapStreamError(json: JSONObject, runId: String): IndeRunException {
        val nested = json.optJSONObject("error")
            ?: json.optJSONObject("response")?.optJSONObject("error")
            ?: JSONObject()
        return mapReportedError(
            reported = ReportedError(
                message = nested.optStringOrNull("message") ?: json.optStringOrNull("message"),
                type = nested.optStringOrNull("type"),
                code = nested.optErrorCode("code") ?: json.optErrorCode("code"),
            ),
            fallbackMessage = "OpenAI Responses stream reported a failure.",
            runId = runId,
            errorType = json.optJSONObject("response")?.optRaw("error_type")
                ?: nested.optJSONObject("metadata")?.optRaw("error_type"),
        )
    }

    /**
     * Classifies a failure reported in a body rather than by the HTTP status: a
     * failed stream event or a 2xx run body whose status is `failed`. The most
     * specific signal wins:
     * 1. OpenRouter's typed `error_type` ([errorType]), classified by the HTTP
     *    status it documents for that type (see [openRouterErrorTypeStatus]);
     * 2. a numeric `code`, which is an HTTP status (OpenRouter's convention) and
     *    is classified exactly as [mapHttpError] classifies that status;
     * 3. a string code, by OpenAI's names.
     * Anything unrecognized is a transient `Unavailable`, since the server did
     * accept the request.
     */
    private fun mapReportedError(
        reported: ReportedError?,
        fallbackMessage: String,
        runId: String,
        errorType: Any? = null,
    ): IndeRunException {
        val message = reported?.message?.takeIf { it.isNotEmpty() } ?: fallbackMessage
        val code = reported?.code
        val typedStatus = openRouterErrorTypeStatus(errorType)
        val details = mapOf(
            "errorType" to if (typedStatus != null) errorType as String else reported?.type,
            "errorCode" to code?.toString(),
        )

        if (typedStatus != null) {
            return errorForStatus(status = typedStatus, message = message, runId = runId, details = details)
        }

        if (code is Long) {
            return errorForStatus(status = code, message = message, runId = runId, details = details)
        }

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
            // The request itself was rejected; repeating it cannot succeed.
            "invalid_prompt", "image_content_policy_violation" -> createInternal(
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

    /**
     * Maps an OpenAI HTTP error response onto the IndeRun error taxonomy by its
     * status (see [errorForStatus]), honoring `Retry-After` on whichever status
     * carries it.
     */
    private fun mapHttpError(
        status: Int,
        statusText: String,
        headers: Map<String, String>,
        body: String,
        runId: String,
    ): IndeRunException {
        val json = parseJsonObject(body)
        val error = json.optJSONObject("error")
        val message = error?.optStringOrNull("message")
            ?: "OpenAI Responses request failed with HTTP $status $statusText."
        val details = mapOf(
            "status" to status,
            "statusText" to statusText,
            "errorType" to error?.optStringOrNull("type"),
            "errorCode" to error?.optErrorCode("code")?.toString(),
        )

        return errorForStatus(
            status = status.toLong(),
            message = message,
            runId = runId,
            details = details,
            retryAfterMs = parseRetryAfterMs(headers),
        )
    }

    /**
     * The status classification shared by HTTP errors and numeric in-body codes:
     * - `401` / `403` → `AuthError`
     * - `402` → `Unavailable`, not retryable: the account is out of credits, so
     *   this target cannot serve until someone tops it up. A 402 that carries
     *   `Retry-After` is the exception — OpenRouter's in-flight budget limit,
     *   which clears on its own — and is `RateLimited`. Fallback is unaffected
     *   either way: the engine moves on to the next target whatever the class.
     * - `429` → `RateLimited`
     * - `408` / `504` → `Timeout`
     * - `409` / `5xx` → `Unavailable`
     * - any other status → `Internal`
     *
     * [retryAfterMs] travels on every retryable class; it is absent for numeric
     * in-body codes, which have no header to read it from.
     */
    private fun errorForStatus(
        status: Long,
        message: String,
        runId: String,
        details: Map<String, Any?>,
        retryAfterMs: Long? = null,
    ): IndeRunException = when {
        status == 401L || status == 403L -> createAuthError(
            message = message,
            runId = runId,
            providerId = options.id,
            details = details,
        )

        status == 402L && retryAfterMs == null -> createUnavailable(
            message = message,
            runId = runId,
            providerId = options.id,
            retryable = false,
            details = details,
        )

        status == 402L || status == 429L -> createRateLimited(
            message = message,
            runId = runId,
            providerId = options.id,
            retryable = true,
            retryAfterMs = retryAfterMs,
            details = details,
        )

        status == 408L || status == 504L -> createTimeout(
            message = message,
            runId = runId,
            providerId = options.id,
            retryable = true,
            retryAfterMs = retryAfterMs,
            details = details,
        )

        status == 409L || status >= 500L -> createUnavailable(
            message = message,
            runId = runId,
            providerId = options.id,
            retryable = true,
            retryAfterMs = retryAfterMs,
            details = details,
        )

        else -> createInternal(
            message = message,
            runId = runId,
            providerId = options.id,
            details = details,
        )
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

    /**
     * The model id the Responses API echoes on the response object: the model that served the
     * request, which can be a dated snapshot of the configured alias.
     */
    private fun reportedModel(json: JSONObject): String? = json.optStringOrNull("model")?.takeIf { it.isNotEmpty() }

    private fun finishReason(json: JSONObject): FinishReason {
        if (json.optString("status") == "incomplete") {
            val reason = json.optJSONObject("incomplete_details")?.optString("reason")
            return if (reason == "max_output_tokens") FinishReason.LENGTH else FinishReason.ERROR
        }

        return FinishReason.STOP
    }
}

object AndroidCloudProviderRegistryFactory {
    /**
     * Registers one OpenAI-compatible target per configured model.
     *
     * @throws IllegalArgumentException when [OpenAIFactoryOptions.models] is empty.
     */
    fun makeOpenAIRegistry(options: OpenAIFactoryOptions): ProviderRegistry {
        require(options.models.isNotEmpty()) { "makeOpenAIRegistry requires at least one model." }
        return ProviderRegistry().apply {
            options.models.forEach { model -> register(OpenAIProvider(options.providerOptions(model))) }
        }
    }
}

/**
 * A failure reported inside a response body or stream event. [code] is a
 * [String] on OpenAI and the numeric HTTP status (a [Long]) on OpenRouter.
 */
private class ReportedError(
    val message: String?,
    val type: String?,
    val code: Any?,
)

private fun reportedError(json: JSONObject): ReportedError = ReportedError(
    message = json.optStringOrNull("message"),
    type = json.optStringOrNull("type"),
    code = json.optErrorCode("code"),
)

/**
 * The HTTP status OpenRouter documents for each typed `error_type`, so a typed
 * failure is classified exactly like the equivalent HTTP error. Refusals and
 * content-policy violations are documented as 403 but are not credential
 * failures, so they classify as a rejected request (400). Anything that is not
 * a known type string returns `null` and the native `code` decides instead.
 */
private fun openRouterErrorTypeStatus(errorType: Any?): Long? = (errorType as? String)?.let(OPENROUTER_ERROR_TYPE_STATUS::get)

private val OPENROUTER_ERROR_TYPE_STATUS: Map<String, Long> = mapOf(
    "authentication" to 401L,
    "payment_required" to 402L,
    "permission_denied" to 403L,
    "rate_limit_exceeded" to 429L,
    "timeout" to 504L,
    "provider_unavailable" to 502L,
    "provider_overloaded" to 503L,
    "server" to 500L,
    "unmapped" to 500L,
    "not_found" to 404L,
    "image_not_found" to 404L,
    "precondition_failed" to 412L,
    "payload_too_large" to 413L,
    "unprocessable" to 422L,
    "content_policy_violation" to 400L,
    "refusal" to 400L,
    "context_length_exceeded" to 400L,
    "max_tokens_exceeded" to 400L,
    "token_limit_exceeded" to 400L,
    "string_too_long" to 400L,
    "invalid_request" to 400L,
    "invalid_prompt" to 400L,
    "invalid_image" to 400L,
    "image_too_large" to 400L,
    "image_too_small" to 400L,
    "unsupported_image_format" to 400L,
    "image_download_failed" to 400L,
)

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

/**
 * The raw value at [key], or `null` when it is absent or JSON `null`. Unlike
 * `optString`, which yields `""` for a missing key and coerces numbers, the
 * caller sees exactly what the server sent and decides what it accepts.
 */
private fun JSONObject.optRaw(key: String): Any? = opt(key)?.takeIf { it != JSONObject.NULL }

private fun JSONObject.optLongOrNull(key: String): Long? {
    if (!has(key) || isNull(key)) {
        return null
    }
    return optLong(key)
}

/**
 * An error `code` as sent: a [String] name, or a [Long] when the server sent a
 * whole number (OpenRouter's HTTP status). `optString` would coerce `429` to
 * `"429"` and lose the distinction, so the raw value is inspected instead.
 */
private fun JSONObject.optErrorCode(key: String): Any? = when (val value = opt(key)) {
    is String -> value.takeIf { it.isNotBlank() }
    is Int, is Long -> (value as Number).toLong()
    is Number -> value.toDouble().takeIf { it % 1.0 == 0.0 }?.toLong() ?: value.toString()
    else -> null
}

/**
 * Reads `Retry-After` as either delay-seconds or an HTTP date (RFC 1123, e.g.
 * `Wed, 21 Oct 2015 07:28:00 GMT`); a date in the past means retry now. ISO-8601
 * instants are accepted too. `java.time` is part of the platform from API 26,
 * this module's minSdk, so no desugaring is involved.
 */
private fun parseRetryAfterMs(headers: Map<String, String>): Long? {
    val raw = headers["retry-after"] ?: headers["Retry-After"] ?: return null
    raw.toDoubleOrNull()?.takeIf { it.isFinite() }?.let { seconds ->
        return (seconds * 1000).toLong().coerceAtLeast(0L)
    }

    val dateMs = try {
        Instant.from(DateTimeFormatter.RFC_1123_DATE_TIME.parse(raw)).toEpochMilli()
    } catch (_: Throwable) {
        try {
            Instant.parse(raw).toEpochMilli()
        } catch (_: Throwable) {
            return null
        }
    }
    return (dateMs - System.currentTimeMillis()).coerceAtLeast(0L)
}
