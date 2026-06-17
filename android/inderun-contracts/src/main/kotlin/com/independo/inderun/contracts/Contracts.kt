/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

package com.independo.inderun.contracts

/**
 * Milestone-1 text-to-text request contract for Mode 1 run().
 */
data class TaskRequest (
    /**
     * Reference to a secure credential slot. Raw credentials must not be placed in the request.
     */
    val authContextRef: String? = null,

    /**
     * Optional provider-neutral generation hints.
     */
    val generation: Generation? = null,

    /**
     * Conversation-style text input for chat-like text-to-text execution.
     */
    val messages: List<Message>? = null,

    /**
     * Execution policy constraints used by the router.
     */
    val policy: Policy,

    /**
     * Single text prompt input for simple text-to-text execution.
     */
    val prompt: String? = null,

    /**
     * Optional caller-provided idempotency/debug identifier for this request.
     */
    val requestId: String? = null,

    /**
     * Contract schema version used to interpret the request payload.
     */
    val schemaVersion: SchemaVersion = SchemaVersion.V1_0,

    /**
     * Task descriptor used by routing and provider capability matching.
     */
    val task: Task = Task(),

    /**
     * Caller telemetry preferences for this request.
     */
    val telemetry: TaskRequestTelemetry? = null
)

/**
 * Optional provider-neutral generation hints.
 */
data class Generation (
    /**
     * Optional upper bound for generated output tokens.
     */
    val maxOutputTokens: Long? = null,

    /**
     * Optional deterministic generation seed when supported by the provider.
     */
    val seed: Long? = null,

    /**
     * Optional stop sequences that should end generation when matched.
     */
    val stop: List<String>? = null,

    /**
     * Optional randomness hint where 0 is most deterministic and 2 is highest supported
     * variance.
     */
    val temperature: Double? = null,

    /**
     * Optional nucleus sampling probability hint.
     */
    val topP: Double? = null
)

/**
 * One message in the conversation input.
 */
data class Message (
    /**
     * Role of the message author.
     */
    val role: MessageRole,

    /**
     * Text content for this message.
     */
    val content: String
)

/**
 * Role of the message author.
 */
enum class MessageRole(val rawValue: String) {
    ASSISTANT("assistant"),
    SYSTEM("system"),
    USER("user")
}

/**
 * Execution policy constraints used by the router.
 */
data class Policy (
    /**
     * Required execution target for milestone routing.
     */
    val execution: ExecutionPolicy
)

/**
 * Required execution target for milestone routing.
 */
enum class ExecutionPolicy(val rawValue: String) {
    CLOUD("cloud"),
    ON_DEVICE("on_device")
}

enum class SchemaVersion(val rawValue: String) {
    V1_0("1.0")
}

/**
 * Task descriptor used by routing and provider capability matching.
 */
data class Task (
    /**
     * Milestone-1 task kind for text input to text output.
     */
    val kind: TaskKind = TaskKind.TEXT_TO_TEXT
)

enum class TaskKind(val rawValue: String) {
    TEXT_TO_TEXT("text_to_text")
}

/**
 * Caller telemetry preferences for this request.
 */
data class TaskRequestTelemetry (
    /**
     * Whether the caller consents to telemetry collection for this request.
     */
    val consent: Boolean? = null,

    /**
     * Requested telemetry detail level.
     */
    val level: TelemetryLevel? = null,

    /**
     * Optional caller-provided non-secret labels for telemetry correlation.
     */
    val tags: Map<String, String>? = null
)

/**
 * Requested telemetry detail level.
 */
enum class TelemetryLevel(val rawValue: String) {
    DEBUG("debug"),
    MINIMAL("minimal"),
    OFF("off")
}

/**
 * Milestone-1 text-to-text result contract for Mode 1 run().
 */
data class TaskResult (
    /**
     * Normalized reason why generation ended.
     */
    val finishReason: FinishReason,

    /**
     * Normalized text output returned by the selected provider.
     */
    val output: Output,

    /**
     * Opaque run identifier assigned or normalized by the engine.
     */
    val runId: String,

    /**
     * Contract schema version used to interpret the result payload.
     */
    val schemaVersion: SchemaVersion = SchemaVersion.V1_0,

    /**
     * Required minimal telemetry summary attached to every result.
     */
    val telemetry: TaskResultTelemetry,

    /**
     * Optional normalized token usage information reported by the provider.
     */
    val usage: Usage? = null
)

/**
 * Normalized reason why generation ended.
 */
enum class FinishReason(val rawValue: String) {
    CANCELLED("cancelled"),
    ERROR("error"),
    LENGTH("length"),
    STOP("stop")
}

/**
 * Normalized text output returned by the selected provider.
 */
data class Output (
    /**
     * Generated text returned to the caller.
     */
    val text: String,

    /**
     * Output payload kind for milestone text-to-text execution.
     */
    val type: OutputType = OutputType.TEXT
)

enum class OutputType(val rawValue: String) {
    TEXT("text")
}

/**
 * Required minimal telemetry summary attached to every result.
 */
data class TaskResultTelemetry (
    /**
     * Optional normalized error class if the result represents a provider-level error outcome.
     */
    val errorClass: IndeRunErrorClass? = null,

    /**
     * Identifier of the provider selected for the completed attempt.
     */
    val providerUsed: String,

    /**
     * Total measured execution duration in milliseconds.
     */
    val totalMs: Double
)

/**
 * Optional normalized error class if the result represents a provider-level error outcome.
 *
 * Normalized error taxonomy class.
 */
enum class IndeRunErrorClass(val rawValue: String) {
    AuthError("AuthError"),
    CapabilityMismatch("CapabilityMismatch"),
    Internal("Internal"),
    Offline("Offline"),
    RateLimited("RateLimited"),
    Timeout("Timeout"),
    Unavailable("Unavailable")
}

/**
 * Optional normalized token usage information reported by the provider.
 */
data class Usage (
    /**
     * Number of input tokens consumed, when reported by the provider.
     */
    val inputTokens: Long? = null,

    /**
     * Number of output tokens generated, when reported by the provider.
     */
    val outputTokens: Long? = null,

    /**
     * Total token count, when reported by the provider.
     */
    val totalTokens: Long? = null
)

/**
 * Normalized Milestone-1 error contract.
 */
data class IndeRunError (
    /**
     * Optional structured diagnostic details. It must not contain raw secrets.
     */
    val details: Map<String, Any?>? = null,

    /**
     * Normalized error taxonomy class.
     */
    val errorClass: IndeRunErrorClass,

    /**
     * Human-readable error message suitable for logs and developer diagnostics.
     */
    val message: String,

    /**
     * Identifier of the provider associated with the failure, if execution reached a provider.
     */
    val providerId: String? = null,

    /**
     * Whether retrying the same request may succeed.
     */
    val retryable: Boolean? = null,

    /**
     * Optional suggested delay before retrying, in milliseconds.
     */
    val retryAfterMs: Long? = null,

    /**
     * Opaque run identifier associated with the failed execution, if available.
     */
    val runId: String? = null,

    /**
     * Contract schema version used to interpret the error payload.
     */
    val schemaVersion: SchemaVersion = SchemaVersion.V1_0
)

/**
 * Normalized HTTP request payload for host-provided cloud transport.
 */
data class HttpRequest (
    /**
     * Optional serialized request body. For JSON APIs this should be a JSON string.
     */
    val body: String? = null,

    /**
     * HTTP headers to send after the provider adapter has applied any required transport-level
     * credentials.
     */
    val headers: Map<String, String>? = null,

    /**
     * HTTP method to use for the request.
     */
    val method: Method,

    /**
     * Optional maximum duration for the host transport attempt in milliseconds.
     */
    val timeoutMs: Long? = null,

    /**
     * Absolute target URL for the provider transport request.
     */
    val url: String
)

/**
 * HTTP method to use for the request.
 */
enum class Method {
    Delete,
    Get,
    Patch,
    Post,
    Put
}

/**
 * Normalized HTTP response payload returned by host-provided cloud transport.
 */
data class HttpResponse (
    /**
     * Serialized response body returned by the provider transport.
     */
    val body: String,

    /**
     * HTTP response headers normalized to string key-value pairs.
     */
    val headers: Map<String, String>,

    /**
     * HTTP status code returned by the provider transport.
     */
    val status: Long,

    /**
     * HTTP status text returned by the provider transport.
     */
    val statusText: String
)

/**
 * Normalized telemetry event emitted by the orchestrator and providers.
 */
data class TelemetryEvent (
    /**
     * Event-specific metadata. It must not contain prompt payloads or raw secrets.
     */
    val payload: Map<String, Any?>,

    /**
     * Opaque run identifier associated with this execution event.
     */
    val runId: String,

    /**
     * Wall-clock event timestamp in Unix epoch milliseconds.
     */
    val timestamp: Double,

    /**
     * Telemetry event kind emitted by the orchestrator or provider integration.
     */
    val type: TelemetryEventType
)

/**
 * Telemetry event kind emitted by the orchestrator or provider integration.
 */
enum class TelemetryEventType {
    AttemptFailed,
    AttemptSucceeded,
    RouteDecided
}

