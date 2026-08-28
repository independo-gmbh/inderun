/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

package app.independo.inderun.contracts

/**
 * The request payload for a Mode 1 (request/response) text-to-text execution. At least one
 * of `prompt` (single-turn) or `messages` (multi-turn) must be present — both may be
 * present together, though callers should typically supply just one;
 * `constraints`/`preferences` steer routing but never select a provider directly.
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
 * The response payload for a completed text-to-text execution. A full execution failure
 * (validation, routing, or every attempted provider failing) is surfaced by run() throwing
 * an IndeRunError instead of returning a TaskResult; finishReason and telemetry.errorClass
 * are reserved for a provider reporting a non-fatal, degraded outcome on an
 * otherwise-successful result (not currently produced by any provider in this codebase).
 */
data class TaskResult(
    /**
     * How generation ended: 'stop' (natural end), 'length' (hit maxOutputTokens), or
     * 'cancelled'. 'error' is reserved for a provider reporting a non-fatal issue on an
     * otherwise-returned result — no provider in this codebase currently produces it, since a
     * full execution failure is instead surfaced by run() throwing an IndeRunError.
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
    val usage: TaskResultUsage? = null,
)

/**
 * How generation ended: 'stop' (natural end), 'length' (hit maxOutputTokens), or
 * 'cancelled'. 'error' is reserved for a provider reporting a non-fatal issue on an
 * otherwise-returned result — no provider in this codebase currently produces it, since a
 * full execution failure is instead surfaced by run() throwing an IndeRunError.
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
     * Present only if a provider reports a degraded outcome on an otherwise-successful result;
     * no provider in this codebase currently sets this. Distinct from run() throwing — a thrown
     * IndeRunError never produces a TaskResult at all.
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
 * Present only if a provider reports a degraded outcome on an otherwise-successful result;
 * no provider in this codebase currently sets this. Distinct from run() throwing — a thrown
 * IndeRunError never produces a TaskResult at all.
 *
 * Normalized error taxonomy, shared with TaskResult.telemetry.errorClass:
 * CapabilityMismatch (request needs something no eligible provider supports),
 * Offline/Unavailable (provider unreachable or not ready), AuthError (credential/auth
 * failure), RateLimited (provider throttled the request), Timeout (provider exceeded its
 * execution budget), Internal (unexpected engine-side failure).
 *
 * Normalized error taxonomy, identical to IndeRunError.errorClass: CapabilityMismatch
 * (request needs something no eligible provider supports), Offline/Unavailable (provider
 * unreachable or not ready), AuthError (credential/auth failure), RateLimited (provider
 * throttled the request), Timeout (provider exceeded its execution budget), Internal
 * (unexpected engine-side failure).
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
data class TaskResultUsage(
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
 * The error shape thrown by run() (wrapped in an IndeRunException) when execution fails —
 * via validation, routing (no eligible provider), or every attempted provider failing.
 * Never returned as part of a successful TaskResult.
 */
data class IndeRunError(
    /**
     * Optional structured diagnostic details. It must not contain raw secrets.
     */
    val details: Map<String, Any?>? = null,

    /**
     * Normalized error taxonomy, shared with TaskResult.telemetry.errorClass:
     * CapabilityMismatch (request needs something no eligible provider supports),
     * Offline/Unavailable (provider unreachable or not ready), AuthError (credential/auth
     * failure), RateLimited (provider throttled the request), Timeout (provider exceeded its
     * execution budget), Internal (unexpected engine-side failure).
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
    StreamAttemptFailed,
    StreamAttemptStarted,
    StreamAttemptSucceeded,
    StreamCancelled,
    StreamCompleted,
    StreamFailed,
}

/**
 * Pure data input contract for deterministic shared-core route planning.
 */
data class RoutePlannerInput(
    /**
     * Hard routing constraints evaluated before provider selection.
     */
    val constraints: RoutePlannerInputConstraints,

    /**
     * Interaction mode the caller is requesting. Absent means 'run' (Mode 1), so planner inputs
     * produced before this field existed keep their exact Mode-1 semantics. The mode filters
     * eligible providers; it never changes candidate ordering.
     */
    val interactionMode: InteractionMode? = null,

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
 * Interaction mode the caller is requesting. Absent means 'run' (Mode 1), so planner inputs
 * produced before this field existed keep their exact Mode-1 semantics. The mode filters
 * eligible providers; it never changes candidate ordering.
 */
enum class InteractionMode {
    Run,
    Stream,
}

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

    /**
     * Whether cancellation is honored right now in this host environment. Absent inherits the
     * static descriptor.cancel value (any value other than 'none' means available).
     */
    val cancellationAvailable: Boolean? = null,

    val reason: String? = null,

    /**
     * Whether the provider can stream right now in this host environment. Absent inherits the
     * static descriptor.supports.streaming value.
     */
    val streamingAvailable: Boolean? = null,

    /**
     * Human-readable explanation used when streamingAvailable is false. Absent lets the planner
     * synthesize a default message.
     */
    val streamingUnavailableReason: String? = null,
)

data class Descriptor(
    /**
     * Cancellation guarantee the provider offers. Carried for route explanations and telemetry;
     * the planner does not filter on it.
     */
    val cancel: Cancel? = null,

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
 * Cancellation guarantee the provider offers. Carried for route explanations and telemetry;
 * the planner does not filter on it.
 */
enum class Cancel {
    Hard,
    None,
    Soft,
}

/**
 * Descriptor privacy metadata used to enforce local/cloud routing rules.
 */
data class PrivacyClass(
    val dataLeavesDevice: Boolean,
    val regions: List<String>? = null,
)

data class Supports(
    val run: Boolean,

    /**
     * Whether the provider statically declares Mode-2 streaming. Absent is treated as false: a
     * descriptor that predates this field cannot be assumed to stream.
     */
    val streaming: Boolean? = null,
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
    /**
     * Normalized rejection reason. 'streaming_not_supported' means the descriptor does not
     * statically declare Mode-2 streaming; 'streaming_unavailable' means it declares streaming
     * but the dynamic capability snapshot reports it cannot stream in the current host
     * environment.
     */
    val code: Code,

    val message: String,
)

/**
 * Normalized rejection reason. 'streaming_not_supported' means the descriptor does not
 * statically declare Mode-2 streaming; 'streaming_unavailable' means it declares streaming
 * but the dynamic capability snapshot reports it cannot stream in the current host
 * environment.
 */
enum class Code {
    CapabilityUnavailable,
    CloudConstraint,
    Offline,
    PrivacyConstraint,
    RunNotSupported,
    StreamingNotSupported,
    StreamingUnavailable,
    TaskNotSupported,
}

/**
 * Provider-neutral descriptor for a developer-supplied/custom local model made available to
 * an IndeRun local-model provider family (for example, the ONNX Runtime family). It
 * describes model identity, format, task support, source, files, integrity, licensing, and
 * resource expectations. It is bootstrap/configuration metadata resolved before execution;
 * it is not part of the public TaskRequest/TaskResult surface, and it must not carry raw
 * secrets.
 */
data class ModelPackage(
    /**
     * Files that make up the model package, expressed as source-relative names/paths. The
     * provider adapter and model source resolve these to concrete bytes per platform.
     */
    val files: Files? = null,

    /**
     * Model packaging format the target runtime family must understand. 'onnx' is a plain ONNX
     * graph, 'ort' is an ONNX Runtime optimized/mobile format, 'genai' is an ONNX Runtime GenAI
     * model package.
     */
    val format: Format,

    /**
     * Stable application-scoped identifier for the model package.
     */
    val id: String,

    /**
     * Optional integrity metadata used to validate resolved files before load.
     */
    val integrity: Integrity? = null,

    /**
     * Optional license/source metadata for the model, for developer transparency. Free-form.
     */
    val license: License? = null,

    /**
     * Optional known resource expectations, used by capability checks to reject on constrained
     * devices before load.
     */
    val limits: Limits? = null,

    /**
     * Optional runtime compatibility expectations. Fields are advisory hints for capability
     * checks; the provider adapter owns exact enforcement.
     */
    val runtime: Runtime? = null,

    /**
     * Where the model files are obtained from. Availability of each source type is
     * platform-dependent; see the ONNX Runtime provider-family specification for the
     * per-platform support matrix.
     */
    val source: Source? = null,

    /**
     * IndeRun task kinds this model package can serve (for example 'text_to_text'). Used by
     * dynamic capability checks and route matching.
     */
    val tasks: List<String>? = null,

    /**
     * Optional application-defined version for the model package, used for cache invalidation
     * and compatibility checks.
     */
    val version: String? = null,
)

/**
 * Files that make up the model package, expressed as source-relative names/paths. The
 * provider adapter and model source resolve these to concrete bytes per platform.
 */
data class Files(
    /**
     * Optional model/generation config file, where the model requires one.
     */
    val config: String? = null,

    /**
     * Optional external data files referenced by the model graph (for example ONNX external
     * weights).
     */
    val external: List<String>? = null,

    /**
     * Files that must be present for the package to load (for example the model graph).
     */
    val required: List<String>? = null,

    /**
     * Optional tokenizer file, where the model requires one.
     */
    val tokenizer: String? = null,
)

/**
 * Model packaging format the target runtime family must understand. 'onnx' is a plain ONNX
 * graph, 'ort' is an ONNX Runtime optimized/mobile format, 'genai' is an ONNX Runtime GenAI
 * model package.
 */
enum class Format {
    Genai,
    Onnx,
    Ort,
}

/**
 * Optional integrity metadata used to validate resolved files before load.
 */
data class Integrity(
    /**
     * Map of file name to expected checksum (for example 'sha256:...'). Absence means integrity
     * is not verified by IndeRun.
     */
    val checksums: Map<String, String>? = null,
)

/**
 * Optional license/source metadata for the model, for developer transparency. Free-form.
 */
data class License(
    /**
     * SPDX license identifier where known (for example 'Apache-2.0').
     */
    val spdx: String? = null,

    /**
     * License or model card URL where available.
     */
    val url: String? = null,
)

/**
 * Optional known resource expectations, used by capability checks to reject on constrained
 * devices before load.
 */
data class Limits(
    /**
     * Approximate on-disk size of the resolved package, where known.
     */
    val diskBytes: Long? = null,

    /**
     * Approximate peak memory required to run the model, where known.
     */
    val memBytes: Long? = null,
)

/**
 * Optional runtime compatibility expectations. Fields are advisory hints for capability
 * checks; the provider adapter owns exact enforcement.
 */
data class Runtime(
    /**
     * Minimum ONNX opset version the model requires, where known.
     */
    val minOpset: Long? = null,

    /**
     * Minimum runtime package version required to load the model, where known.
     */
    val minRuntimeVersion: String? = null,

    /**
     * Platforms the package is expected to run on (for example 'web', 'android', 'apple').
     * Absence means unconstrained.
     */
    val platforms: List<String>? = null,
)

/**
 * Where the model files are obtained from. Availability of each source type is
 * platform-dependent; see the ONNX Runtime provider-family specification for the
 * per-platform support matrix.
 */
data class Source(
    /**
     * Optional source-specific reference (for example a registry repo id or a bundled asset
     * base path). Interpretation depends on 'sourceType'. Must not contain credentials: URL
     * userinfo (for example 'https://user:pass@host/...') is rejected, and credentials must be
     * supplied via authContextRef instead.
     */
    val ref: String? = null,

    /**
     * Discriminator for how the host makes model files available. 'registry' is a web
     * repository/registry reference (for example a Hugging Face-style repo), 'bundled' is an
     * app asset/resource, 'programmatic' is supplied directly by application code, 'filesystem'
     * is a local path where the platform allows it, 'app_managed' is an app-managed
     * cache/storage location, 'remote' is a host-managed download.
     */
    val sourceType: SourceType,
)

/**
 * Discriminator for how the host makes model files available. 'registry' is a web
 * repository/registry reference (for example a Hugging Face-style repo), 'bundled' is an
 * app asset/resource, 'programmatic' is supplied directly by application code, 'filesystem'
 * is a local path where the platform allows it, 'app_managed' is an app-managed
 * cache/storage location, 'remote' is a host-managed download.
 */
enum class SourceType {
    AppManaged,
    Bundled,
    Filesystem,
    Programmatic,
    Registry,
    Remote,
}

/**
 * The serializable acknowledgment returned when a Mode 2 stream is opened, before any
 * StreamEvent has arrived. This is the identity/correlation contract only: the live,
 * consumable stream itself is a platform-idiomatic construct (an AsyncIterable<StreamEvent>
 * in TypeScript, a Flow<StreamEvent> in Kotlin, an AsyncThrowingStream<StreamEvent, Error>
 * in Swift) that is never serialized and is out of scope for this schema. Design seam only;
 * no engine or provider implementation exists yet (see docs/architecture/architecture.md).
 */
data class StreamRunHandle(
    /**
     * Identifier of the provider selected to service this stream, if routing has completed by
     * the time the handle is returned. Absent while route selection is still pending.
     */
    val providerId: String? = null,

    /**
     * A unique, opaque identifier assigned by the engine for this stream run. Every StreamEvent
     * and the terminal StreamTerminalOutcome for this run carry the same runId, matching the
     * identity convention used by TaskResult.runId and IndeRunError.runId.
     */
    val runId: String,

    /**
     * Contract schema version used to interpret this handle payload.
     */
    val schemaVersion: SchemaVersion,

    /**
     * Wall-clock time the stream run was opened, in Unix epoch milliseconds.
     */
    val startedAt: Double,
)

/**
 * The canonical Mode 2 streaming event union, discriminated by 'type'. Every variant shares
 * an envelope of schemaVersion, runId, sequence, timestamp, and type. 'sequence' is the
 * ordering authority for events within a run (a monotonically increasing integer starting
 * at 0 per runId) — consumers must order by 'sequence', not by arrival order, since a
 * bridge hop (e.g. a future Capacitor bridge) could reorder delivery. Known event types are
 * split into user-visible content ('content_delta', 'content_snapshot') and
 * mechanical/diagnostic types ('lifecycle', 'diagnostic', 'terminal') so SDKs can
 * distinguish what belongs in a chat UI from what is orchestration detail. Forward
 * compatibility: this union closes with an open 'unknown_event' branch so a consumer built
 * against an older revision of this schema does not hard-fail when a newer, additive minor
 * revision introduces a new known type; per contracts/README.md's schema evolution policy,
 * SDKs must treat an unrecognized 'type' as ignore-or-pass-through-for-diagnostics, never
 * as a hard error. Design seam only; no engine or provider implementation exists yet (see
 * docs/architecture/architecture.md).
 */
data class StreamEvent(
    /**
     * Event-specific diagnostic metadata. It must not contain prompt payloads or raw secrets,
     * matching the same guardrail as TelemetryEvent.payload.
     *
     * Structurally identical to StreamTerminalOutcome
     * (contracts/schemas/stream-terminal-outcome.schema.json), duplicated by value here rather
     * than by $ref, matching this repo's schema convention of no cross-file references. Keep
     * both shapes in sync; a cross-check test asserts a shared fixture validates against both
     * schemas.
     *
     * Optional event-specific payload for the unrecognized type. It must not contain prompt
     * payloads or raw secrets.
     */
    val payload: Payload? = null,

    /**
     * Opaque run identifier this event belongs to, matching StreamRunHandle.runId.
     */
    val runId: String,

    /**
     * Contract schema version used to interpret this event payload.
     */
    val schemaVersion: SchemaVersion,

    /**
     * Zero-based, monotonically increasing event index within this run. The ordering authority;
     * do not rely on delivery/arrival order.
     *
     * Zero-based, monotonically increasing event index within this run. This is always the
     * highest sequence number for the run: the terminal event.
     */
    val sequence: Long,

    /**
     * Wall-clock event timestamp in Unix epoch milliseconds.
     */
    val timestamp: Double,

    /**
     * User-visible content: an incremental text increment since the previous content_delta or
     * content_snapshot event. Mirrors ProviderDescriptor.streamingStyle 'tokens'/'chunks'
     * (packages/inderun-web/src/core/provider.ts) — providers reporting either style normalize
     * to content_delta.
     *
     * User-visible content: the full cumulative text produced so far. Mirrors
     * ProviderDescriptor.streamingStyle 'snapshots' (packages/inderun-web/src/core/provider.ts)
     * — providers reporting that style normalize to content_snapshot rather than
     * content_delta.
     *
     * Mechanical/diagnostic: a run lifecycle transition (e.g. provider selection, execution
     * start). Not user-visible content; not part of the generated text.
     *
     * Mechanical/diagnostic: free-form orchestration or provider diagnostic detail. Not
     * user-visible content.
     *
     * Terminal: the last event of the run, carrying the mutually-exclusive
     * completion/error/cancellation outcome. No further StreamEvent is delivered for this runId
     * after this event.
     *
     * Forward-compatibility catch-all: any event type not among the known constants above.
     * Exists so a consumer validating against this revision of the schema does not hard-fail
     * when a future additive revision introduces a new known event type; SDKs must ignore or
     * pass through such events for diagnostics rather than treating them as an error.
     */
    val type: String,
)

/**
 * Event-specific diagnostic metadata. It must not contain prompt payloads or raw secrets,
 * matching the same guardrail as TelemetryEvent.payload.
 *
 * Optional event-specific payload for the unrecognized type. It must not contain prompt
 * payloads or raw secrets.
 */
data class Payload(
    /**
     * The incremental text produced since the previous content event.
     *
     * The full cumulative text produced by the run so far.
     */
    val text: String? = null,

    /**
     * The lifecycle phase reached.
     */
    val phase: Phase? = null,

    val finalText: String? = null,
    val outcome: Outcome? = null,
    val runId: String? = null,
    val schemaVersion: SchemaVersion? = null,
    val telemetry: PayloadTelemetry? = null,
    val usage: PayloadUsage? = null,
    val error: PayloadError? = null,
    val partialText: String? = null,
    val reason: String? = null,
)

data class PayloadError(
    val details: Map<String, Any?>? = null,
    val errorClass: IndeRunErrorClass,
    val message: String,
    val providerId: String? = null,
    val retryable: Boolean? = null,
    val retryAfterMs: Long? = null,
    val schemaVersion: SchemaVersion = SchemaVersion.V1_0,
)

enum class Outcome {
    Cancelled,
    Completed,
    Error,
}

/**
 * The lifecycle phase reached.
 */
enum class Phase {
    ProviderSelected,
    Started,
}

data class PayloadTelemetry(
    val providerUsed: String,
    val totalMs: Double,
)

data class PayloadUsage(
    val inputTokens: Long? = null,
    val outputTokens: Long? = null,
    val totalTokens: Long? = null,
)

/**
 * How a Mode 2 stream run ended. Completion, error, and cancellation are mutually exclusive
 * terminal outcomes, enforced here as a closed set of three oneOf branches discriminated by
 * 'outcome' (unlike StreamEvent.type, this set is not open-ended: the three-way terminal
 * outcome is a fixed architectural guarantee, not something new outcome kinds get added
 * to). Exactly one StreamTerminalOutcome is produced per run, and no further StreamEvent is
 * delivered after it (see docs/architecture/architecture.md, 'Cancellation And Fallback').
 * This shape is also embedded by value as the payload of the terminal StreamEvent
 * (stream-event.schema.json) so it can additionally be exposed standalone, e.g. as a
 * completion future/promise a stream handle resolves independently of consuming the full
 * event sequence; the two copies must stay structurally identical. Note on
 * additionalProperties: per this repo's forward-compatible convention every branch permits
 * unknown extra fields, so mutual exclusivity is enforced via the required 'outcome'
 * discriminator plus each branch's own required peer field (finalText/error/partialText)
 * being present, not by forbidding a payload from also carrying an unrelated stray field
 * from another branch's vocabulary.
 */
data class StreamTerminalOutcome(
    /**
     * The full, cumulative text produced by the run. Equivalent in role to
     * TaskResult.output.text for Mode 1.
     */
    val finalText: String? = null,

    /**
     * The stream completed normally: every provider-generated event was delivered before this
     * outcome was produced.
     *
     * The stream ended in failure: validation, routing (no eligible provider), or every
     * attempted provider failing.
     *
     * The stream was cancelled. No further StreamEvent is delivered after this outcome, and no
     * further fallback attempt is made, per the engine's cancellation guarantee.
     */
    val outcome: Outcome,

    /**
     * The stream run this outcome terminates, matching StreamRunHandle.runId and every
     * StreamEvent.runId for the run.
     */
    val runId: String,

    /**
     * Contract schema version used to interpret this outcome payload.
     */
    val schemaVersion: SchemaVersion,

    /**
     * Required metadata providing an overview of the execution result and performance metrics.
     * Same shape as TaskResult.telemetry.
     */
    val telemetry: StreamTerminalOutcomeTelemetry? = null,

    /**
     * Optional metadata regarding the quantity of tokens processed by the provider. Same shape
     * as TaskResult.usage.
     */
    val usage: StreamTerminalOutcomeUsage? = null,

    /**
     * The normalized error for this failure. Structurally identical to IndeRunError
     * (contracts/schemas/inderun-error.schema.json), duplicated by value here rather than by
     * $ref, matching this repo's schema convention of no cross-file references. Keep both
     * shapes in sync; a cross-check test asserts a shared fixture validates against both
     * schemas.
     */
    val error: StreamTerminalOutcomeError? = null,

    /**
     * Whatever cumulative text had already been delivered via content_delta/content_snapshot
     * StreamEvents before the cancellation point. May be empty if cancellation occurred before
     * any content was produced.
     */
    val partialText: String? = null,

    /**
     * Optional human-readable reason the run was cancelled (e.g. caller-initiated abort). Not a
     * machine-taxonomy field; use errorClass on the 'error' outcome branch for failure
     * classification.
     */
    val reason: String? = null,
)

/**
 * The normalized error for this failure. Structurally identical to IndeRunError
 * (contracts/schemas/inderun-error.schema.json), duplicated by value here rather than by
 * $ref, matching this repo's schema convention of no cross-file references. Keep both
 * shapes in sync; a cross-check test asserts a shared fixture validates against both
 * schemas.
 */
data class StreamTerminalOutcomeError(
    /**
     * Optional structured diagnostic details. It must not contain raw secrets.
     */
    val details: Map<String, Any?>? = null,

    /**
     * Normalized error taxonomy, identical to IndeRunError.errorClass: CapabilityMismatch
     * (request needs something no eligible provider supports), Offline/Unavailable (provider
     * unreachable or not ready), AuthError (credential/auth failure), RateLimited (provider
     * throttled the request), Timeout (provider exceeded its execution budget), Internal
     * (unexpected engine-side failure).
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
     * Contract schema version used to interpret the error payload.
     */
    val schemaVersion: SchemaVersion = SchemaVersion.V1_0,
)

/**
 * Required metadata providing an overview of the execution result and performance metrics.
 * Same shape as TaskResult.telemetry.
 */
data class StreamTerminalOutcomeTelemetry(
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
 * Optional metadata regarding the quantity of tokens processed by the provider. Same shape
 * as TaskResult.usage.
 */
data class StreamTerminalOutcomeUsage(
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
