/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

package app.independo.inderun.contracts

/**
 * The standard request payload for initiating a text-to-text execution task within the
 * IndeRun framework.
 */
data class TaskRequest(
    /**
     * A unique identifier used to retrieve credentials from a secure local storage. Raw
     * sensitive keys (API keys, etc.) should NEVER be placed directly in the request payload.
     */
    val authContextRef: String? = null,

    /**
     * Request-level routing constraints used by the planner.
     */
    val constraints: TaskRequestConstraints? = null,

    /**
     * Optional configuration for fine-tuning how the AI model generates its response.
     */
    val generation: Generation? = null,

    /**
     * A list of interaction messages for multi-turn conversation or chat-style execution.
     */
    val messages: List<Message>? = null,

    /**
     * Soft routing preferences used for deterministic provider ordering.
     */
    val preferences: TaskRequestPreferences? = null,

    /**
     * A simple, single-turn text prompt used to trigger a response from the AI model.
     */
    val prompt: String? = null,

    /**
     * Optional identifier for tracking or correlating this specific execution attempt.
     */
    val requestId: String? = null,

    /**
     * Contract schema version used to interpret the request payload.
     */
    val schemaVersion: SchemaVersion,

    /**
     * A descriptor specifying the type of work to be performed. For text-to-text, the kind must
     * be 'text_to_text'.
     */
    val task: TaskRequestTask,

    /**
     * Execution preferences for tracking usage and performance metrics.
     */
    val telemetry: TaskRequestTelemetry? = null,
)

/**
 * Request-level routing constraints used by the planner.
 */
data class TaskRequestConstraints(
    /**
     * Cloud execution constraint.
     */
    val cloud: Cloud? = null,

    /**
     * Privacy requirement or preference for execution placement.
     */
    val privacy: PrivacyEnum? = null,

    /**
     * Optional routing timeout budget in milliseconds.
     */
    val timeoutMs: Long? = null,
)

/**
 * Cloud execution constraint.
 */
enum class Cloud {
    Allowed,
    Forbidden,
    Required,
}

/**
 * Privacy requirement or preference for execution placement.
 */
enum class PrivacyEnum {
    CloudAllowed,
    CloudRequired,
    LocalPreferred,
    LocalRequired,
}

/**
 * Optional configuration for fine-tuning how the AI model generates its response.
 */
data class Generation(
    /**
     * The maximum number of tokens to generate in a single response.
     */
    val maxOutputTokens: Long? = null,

    /**
     * A fixed seed for deterministic generation (where supported by the underlying provider).
     */
    val seed: Long? = null,

    /**
     * Sequence tokens that should terminate the generation process.
     */
    val stop: List<String>? = null,

    /**
     * Controls the randomness of the output. Range: 0 (most deterministic) to 2 (highest
     * variance).
     */
    val temperature: Double? = null,

    /**
     * Nucleus sampling parameter for controlling diversity vs focus in the output.
     */
    val topP: Double? = null,
)

/**
 * An individual message in a conversation.
 */
data class Message(
    /**
     * Role of the message author.
     */
    val role: MessageRole,

    /**
     * Text content for this message.
     */
    val content: String,
)

/**
 * The role of the author (e.g., 'user', 'assistant').
 */
enum class MessageRole(val rawValue: String) {
    ASSISTANT("assistant"),
    SYSTEM("system"),
    USER("user"),
}

/**
 * Soft routing preferences used for deterministic provider ordering.
 */
data class TaskRequestPreferences(
    /**
     * Primary optimization goal when multiple providers remain eligible.
     */
    val optimizeFor: OptimizeFor? = null,
)

/**
 * Primary optimization goal when multiple providers remain eligible.
 */
enum class OptimizeFor {
    Balanced,
    Cost,
    Latency,
    Privacy,
}

enum class SchemaVersion(val rawValue: String) {
    V1_0("1.0"),
}

/**
 * A descriptor specifying the type of work to be performed. For text-to-text, the kind must
 * be 'text_to_text'.
 */
data class TaskRequestTask(
    /**
     * The standard task category. Currently supports 'text_to_text' for prompt-based
     * interactions.
     */
    val kind: TaskKind = TaskKind.TEXT_TO_TEXT,
)

enum class TaskKind(val rawValue: String) {
    TEXT_TO_TEXT("text_to_text"),
}

/**
 * Execution preferences for tracking usage and performance metrics.
 */
data class TaskRequestTelemetry(
    /**
     * Whether the user consents to telemetry collection for this specific request.
     */
    val consent: Boolean? = null,

    /**
     * The granularity of the collected metrics (off, minimal, or debug).
     */
    val level: TelemetryLevel? = null,

    /**
     * Optional key-value pairs for correlating telemetry data with specific features or users.
     */
    val tags: Map<String, String>? = null,
)

/**
 * The granularity of the collected metrics (off, minimal, or debug).
 */
enum class TelemetryLevel(val rawValue: String) {
    DEBUG("debug"),
    MINIMAL("minimal"),
    OFF("off"),
}

/**
 * The standard response payload for completed text-to-text execution within the IndeRun
 * framework.
 */
data class TaskResult(
    /**
     * Standardized reason describing how generation concluded (e.g., 'stop', 'length',
     * 'cancelled', or 'error').
     */
    val finishReason: FinishReason,

    /**
     * The normalized content returned from the selected provider.
     */
    val output: Output,

    /**
     * A unique, opaque identifier assigned by the engine for this specific execution attempt.
     */
    val runId: String,

    /**
     * Contract schema version used to interpret the result payload.
     */
    val schemaVersion: SchemaVersion,

    /**
     * Required metadata providing an overview of the execution result and performance metrics.
     */
    val telemetry: TaskResultTelemetry,

    /**
     * Optional metadata regarding the quantity of tokens processed by the provider.
     */
    val usage: Usage? = null,
)

/**
 * Standardized reason describing how generation concluded (e.g., 'stop', 'length',
 * 'cancelled', or 'error').
 */
enum class FinishReason(val rawValue: String) {
    CANCELLED("cancelled"),
    ERROR("error"),
    LENGTH("length"),
    STOP("stop"),
}

/**
 * The normalized content returned from the selected provider.
 */
data class Output(
    /**
     * The actual text generated by the execution.
     */
    val text: String,

    /**
     * Output payload category (e.g., 'text' for Mode 1 text-to-text).
     */
    val type: OutputType = OutputType.TEXT,
)

enum class OutputType(val rawValue: String) {
    TEXT("text"),
}

/**
 * Required metadata providing an overview of the execution result and performance metrics.
 */
data class TaskResultTelemetry(
    /**
     * Included if the request resulted in a provider-level error (e.g., 'CapabilityMismatch' or
     * 'Unavailable').
     */
    val errorClass: IndeRunErrorClass? = null,

    /**
     * The identifier for the specific provider that handled the request (e.g.,
     * 'openai_compatible_cloud').
     */
    val providerUsed: String,

    /**
     * Measured execution duration in milliseconds, including route selection and result
     * processing.
     */
    val totalMs: Double,
)

/**
 * Included if the request resulted in a provider-level error (e.g., 'CapabilityMismatch' or
 * 'Unavailable').
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
    Unavailable("Unavailable"),
}

/**
 * Optional metadata regarding the quantity of tokens processed by the provider.
 */
data class Usage(
    /**
     * Number of input tokens consumed, as reported by the provider.
     */
    val inputTokens: Long? = null,

    /**
     * Number of output tokens generated, as reported by the provider.
     */
    val outputTokens: Long? = null,

    /**
     * Aggregated token count for this request, as reported by the provider.
     */
    val totalTokens: Long? = null,
)

/**
 * Normalized Milestone-1 error contract.
 */
data class IndeRunError(
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
    val schemaVersion: SchemaVersion = SchemaVersion.V1_0,
)

/**
 * Normalized HTTP request payload for host-provided cloud transport.
 */
data class HttpRequest(
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
    val url: String,
)

/**
 * HTTP method to use for the request.
 */
enum class Method {
    Delete,
    Get,
    Patch,
    Post,
    Put,
}

/**
 * Normalized HTTP response payload returned by host-provided cloud transport.
 */
data class HttpResponse(
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
    val statusText: String,
)

/**
 * Normalized telemetry event emitted by the orchestrator and providers.
 */
data class TelemetryEvent(
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
    val type: TelemetryEventType,
)

/**
 * Telemetry event kind emitted by the orchestrator or provider integration.
 */
enum class TelemetryEventType {
    AttemptFailed,
    AttemptSucceeded,
    RouteDecided,
}

/**
 * Pure data input contract for deterministic shared-core Mode-1 route planning.
 */
data class RoutePlannerInput(
    /**
     * Hard routing constraints evaluated before provider selection.
     */
    val constraints: RoutePlannerInputConstraints,

    /**
     * Soft route ordering preferences applied after hard filtering.
     */
    val preferences: RoutePlannerInputPreferences,

    /**
     * Static descriptors plus dynamic capability snapshots for planning.
     */
    val providers: List<Provider>,

    /**
     * Minimal task descriptor for provider task matching.
     */
    val task: RoutePlannerInputTask,
)

/**
 * Hard routing constraints evaluated before provider selection.
 */
data class RoutePlannerInputConstraints(
    /**
     * Cloud execution constraint.
     */
    val cloud: Cloud? = null,

    /**
     * Current connectivity snapshot used for cloud route planning.
     */
    val networkOnline: Boolean? = null,

    /**
     * Privacy requirement or preference for execution placement.
     */
    val privacy: PrivacyEnum? = null,
)

/**
 * Soft route ordering preferences applied after hard filtering.
 */
data class RoutePlannerInputPreferences(
    /**
     * Primary optimization goal when multiple providers remain eligible.
     */
    val optimizeFor: OptimizeFor? = null,
)

data class Provider(
    val capabilities: Capabilities,
    val descriptor: Descriptor,
)

data class Capabilities(
    val available: Boolean,
    val reason: String? = null,
)

data class Descriptor(
    val id: String,

    /**
     * Descriptor privacy metadata used to enforce local/cloud routing rules.
     */
    val privacy: PrivacyClass? = null,

    val supports: Supports,
    val tasks: List<String>,
    val type: DescriptorType,
)

/**
 * Descriptor privacy metadata used to enforce local/cloud routing rules.
 */
data class PrivacyClass(
    val dataLeavesDevice: Boolean,
    val regions: List<String>? = null,
)

data class Supports(
    val run: Boolean,
)

enum class DescriptorType {
    Cloud,
    Edge,
    Local,
}

/**
 * Minimal task descriptor for provider task matching.
 */
data class RoutePlannerInputTask(
    val kind: String,
)

/**
 * Deterministic shared-core Mode-1 route planning result.
 */
data class RoutePlan(
    /**
     * Eligible candidates in deterministic order.
     */
    val candidates: List<Candidate>,

    /**
     * Human-readable selection or failure explanation suitable for telemetry/debugging.
     */
    val explanation: Explanation,

    /**
     * Normalized routing failure class when no provider is selected.
     */
    val failureCode: FailureCode? = null,

    /**
     * Fallback provider IDs ordered after the primary selection.
     */
    val fallbackProviderIds: List<String>,

    /**
     * Providers filtered out during planning together with machine-readable reasons.
     */
    val rejectedProviders: List<RejectedProvider>,

    /**
     * Chosen primary provider ID, if any.
     */
    val selectedProviderId: String? = null,
)

data class Candidate(
    val order: Long,
    val providerId: String,
)

/**
 * Human-readable selection or failure explanation suitable for telemetry/debugging.
 */
data class Explanation(
    val selectedProviderId: String? = null,
    val summary: String,
)

/**
 * Normalized routing failure class when no provider is selected.
 */
enum class FailureCode {
    CapabilityMismatch,
    Offline,
    Unavailable,
}

data class RejectedProvider(
    val providerId: String,
    val reasons: List<Reason>,
)

data class Reason(
    val code: Code,
    val message: String,
)

enum class Code {
    CapabilityUnavailable,
    CloudConstraint,
    Offline,
    PrivacyConstraint,
    RunNotSupported,
    TaskNotSupported,
}
