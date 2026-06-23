package app.independo.inderun.providers.openai

import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.HttpRequest
import app.independo.inderun.contracts.Method
import app.independo.inderun.contracts.Output
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TaskResultTelemetry
import app.independo.inderun.contracts.Usage
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderAdapter
import app.independo.inderun.core.ProviderDescriptor
import app.independo.inderun.core.ProviderDynamicCapabilities
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.createAuthError
import app.independo.inderun.core.createInternal
import app.independo.inderun.core.createRateLimited
import app.independo.inderun.core.createTimeout
import app.independo.inderun.core.createUnavailable
import kotlinx.coroutines.CancellationException
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.util.Date

const val DEFAULT_OPENAI_RESPONSES_ENDPOINT: String = "https://api.openai.com/v1/responses"

enum class OpenAIAuthMode {
    authContextRef,
    none
}

data class OpenAIProviderOptions(
    val id: String = "openai",
    val model: String,
    val endpointUrl: String = DEFAULT_OPENAI_RESPONSES_ENDPOINT,
    val auth: OpenAIAuthMode = OpenAIAuthMode.authContextRef,
    val authContextRef: String? = null,
    val timeoutMs: Long? = null
)

class OpenAIProvider(
    private val options: OpenAIProviderOptions
) : ProviderAdapter {
    override fun describe(): ProviderDescriptor {
        return ProviderDescriptor(
            id = options.id,
            type = ProviderDescriptor.ProviderType.cloud,
            transport = ProviderDescriptor.TransportType.http,
            supports = ProviderDescriptor.SupportsCapabilities(
                run = true,
                streaming = false,
                realtime = false,
                tools = false,
                reasoningEvents = false,
                structuredOutput = false,
                multimodal = false
            ),
            cancel = ProviderDescriptor.CancelSemantics.hard,
            tasks = listOf("text_to_text"),
            privacy = ProviderDescriptor.PrivacyDescriptor(dataLeavesDevice = true)
        )
    }

    override suspend fun capabilities(host: HostServices): ProviderDynamicCapabilities {
        if (host.httpClient == null) {
            return ProviderDynamicCapabilities(
                available = false,
                reason = "OpenAI Responses provider requires an HttpClientService."
            )
        }

        return ProviderDynamicCapabilities(available = true)
    }

    override suspend fun run(request: TaskRequest, context: RunContext): TaskResult {
        val startTimeMs = context.hostServices.clock.elapsedRealtimeMillis().toDouble()
        val httpClient = context.hostServices.httpClient
            ?: throw createUnavailable(
                message = "OpenAI Responses provider requires an HTTP client.",
                runId = context.runId,
                providerId = options.id
            )

        val headers = linkedMapOf("Content-Type" to "application/json")
        if (options.auth == OpenAIAuthMode.authContextRef) {
            val slotId = request.authContextRef ?: options.authContextRef
            if (slotId.isNullOrBlank()) {
                throw createAuthError(
                    message = "OpenAI Responses provider requires authContextRef.",
                    runId = context.runId,
                    providerId = options.id
                )
            }

            val secret = context.hostServices.secureStorage.get(slotId)
            if (secret.isNullOrBlank()) {
                throw createAuthError(
                    message = "No OpenAI credential found for authContextRef '$slotId'.",
                    runId = context.runId,
                    providerId = options.id
                )
            }

            headers["Authorization"] = "Bearer $secret"
        }

        val httpRequest = HttpRequest(
            method = Method.Post,
            url = options.endpointUrl,
            headers = headers,
            body = createRequestBody(request).toString(),
            timeoutMs = options.timeoutMs
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
                        "message" to (error.message ?: error.toString())
                    )
                )
            )
        }

        if (response.status < 200 || response.status >= 300) {
            throw mapHttpError(
                status = response.status.toInt(),
                statusText = response.statusText,
                headers = response.headers,
                body = response.body,
                runId = context.runId
            )
        }

        val json = parseJsonObject(response.body)
        val outputText = extractOutputText(json)
            ?: throw createInternal(
                message = "OpenAI Responses payload did not contain text output.",
                runId = context.runId,
                providerId = options.id
            )

        val usage = json.optJSONObject("usage")?.let { usageJson ->
            val inputTokens = usageJson.optLongOrNull("input_tokens")
            val outputTokens = usageJson.optLongOrNull("output_tokens")
            val totalTokens = usageJson.optLongOrNull("total_tokens")
            if (inputTokens != null || outputTokens != null || totalTokens != null) {
                Usage(
                    inputTokens = inputTokens,
                    outputTokens = outputTokens,
                    totalTokens = totalTokens
                )
            } else {
                null
            }
        }

        val totalMs = context.hostServices.clock.elapsedRealtimeMillis().toDouble() - startTimeMs
        return TaskResult(
            finishReason = finishReason(json),
            output = Output(text = outputText),
            runId = context.runId,
            telemetry = TaskResultTelemetry(providerUsed = options.id, totalMs = totalMs),
            usage = usage
        )
    }

    private fun createRequestBody(request: TaskRequest): JSONObject {
        val body = JSONObject()
            .put("model", options.model)
            .put("input", createInput(request))

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
                            .put("content", message.content)
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
        runId: String
    ): IndeRunException {
        val json = parseJsonObject(body)
        val error = json.optJSONObject("error")
        val message = error?.optString("message")?.takeIf { it.isNotBlank() }
            ?: "OpenAI Responses request failed with HTTP $status $statusText."
        val details = mutableMapOf<String, Any?>(
            "status" to status,
            "statusText" to statusText,
            "errorType" to error?.optStringOrNull("type"),
            "errorCode" to error?.optStringOrNull("code")
        )

        return when {
            status == 401 || status == 403 -> createAuthError(
                message = message,
                runId = runId,
                providerId = options.id,
                details = details
            )

            status == 429 -> createRateLimited(
                message = message,
                runId = runId,
                providerId = options.id,
                retryable = true,
                retryAfterMs = parseRetryAfterMs(headers),
                details = details
            )

            status == 408 || status == 504 -> createTimeout(
                message = message,
                runId = runId,
                providerId = options.id,
                retryable = true,
                details = details
            )

            status == 409 || status >= 500 -> createUnavailable(
                message = message,
                runId = runId,
                providerId = options.id,
                retryable = true,
                details = details
            )

            else -> createInternal(
                message = message,
                runId = runId,
                providerId = options.id,
                details = details
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
    fun makeOpenAIRegistry(options: OpenAIProviderOptions): ProviderRegistry {
        return ProviderRegistry().apply {
            register(OpenAIProvider(options))
        }
    }
}

private fun parseJsonObject(body: String): JSONObject {
    return try {
        JSONObject(body)
    } catch (_: Throwable) {
        JSONObject()
    }
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
