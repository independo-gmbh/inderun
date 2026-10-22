/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

package app.independo.inderun.contracts

/**
 * The request payload for a run() or stream() execution. The common envelope
 * (schemaVersion, requestId, task, modelProfile, constraints, preferences, telemetry,
 * authContextRef) is task-agnostic; each task kind owns its payload (ADR 016).
 * text_to_text: at least one of `prompt` (single-turn) or `messages` (multi-turn) must be
 * present — both may be present together, though callers should typically supply just one —
 * and `speech`/`delivery` are forbidden. text_to_speech: `speech` and `delivery` are
 * required and `prompt`, `messages` and `generation` are forbidden.
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
     * How the result of a non-text task must reach the application (ADR 016). Required for
     * non-text tasks and forbidden for text_to_text, whose output is implicitly inline. A
     * provider never substitutes playback for an artifact or the reverse.
     */
    val delivery: OutputDeliveryRequest? = null,

    /**
     * Optional configuration for fine-tuning how the AI model generates its response.
     */
    val generation: Generation? = null,

    /**
     * A list of interaction messages for multi-turn conversation or chat-style execution.
     */
    val messages: List<Message>? = null,

    /**
     * Name of the model profile to route within, as configured on the engine. Absent or 'auto'
     * means every registered target, ranked by constraints and preferences alone. A profile is
     * an application-defined, ordered allow-list of targets (provider instances bound to one
     * model each); raw model or provider identifiers are never accepted here. An unknown
     * profile name fails request validation.
     */
    val modelProfile: String? = null,

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
     * The text_to_speech payload. Required for text_to_speech and forbidden for every other
     * kind.
     */
    val speech: SpeechInput? = null,

    /**
     * A descriptor specifying the type of work to be performed. The kind selects which payload
     * the request must carry.
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
    val privacy: Privacy? = null,

    /**
     * Optional timeout budget in milliseconds, passed to the planner and to providers. It
     * bounds the time until the run commits to a provider -- its first content, its first
     * possible audible effect, or its artifact handoff -- not the duration of audio it plays.
     * The engines add no timers of their own.
     */
    val timeoutMs: Long? = null,
)

/**
 * Cloud execution constraint.
 */
enum class Cloud(val rawValue: String) {
    Allowed("allowed"),
    Forbidden("forbidden"),
    Required("required"),
    ;

    companion object {
        fun fromRawValue(value: String): Cloud? = entries.firstOrNull { it.rawValue == value }
    }
}

/**
 * Privacy requirement or preference for execution placement.
 */
enum class Privacy(val rawValue: String) {
    CloudAllowed("cloud_allowed"),
    CloudRequired("cloud_required"),
    LocalPreferred("local_preferred"),
    LocalRequired("local_required"),
    ;

    companion object {
        fun fromRawValue(value: String): Privacy? = entries.firstOrNull { it.rawValue == value }
    }
}

/**
 * How the result of a non-text task must reach the application (ADR 016). Required for
 * non-text tasks and forbidden for text_to_text, whose output is implicitly inline. A
 * provider never substitutes playback for an artifact or the reverse.
 */
data class OutputDeliveryRequest(
    /**
     * Only valid with 'artifact' delivery: the acceptable media types, always a hard
     * requirement. Absent means the provider chooses and the artifact reports what it produced.
     */
    val mediaTypes: List<String>? = null,

    val mode: OutputDelivery,
)

/**
 * How a task's result reaches the application: 'inline' content in the result (text),
 * 'playback' as a managed, audible effect on the device with no retrievable bytes, or
 * 'artifact' as retrievable media.
 */
enum class OutputDelivery(val rawValue: String) {
    Artifact("artifact"),
    Inline("inline"),
    Playback("playback"),
    ;

    companion object {
        fun fromRawValue(value: String): OutputDelivery? = entries.firstOrNull { it.rawValue == value }
    }
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
    ;

    companion object {
        fun fromRawValue(value: String): MessageRole? = entries.firstOrNull { it.rawValue == value }
    }
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
enum class OptimizeFor(val rawValue: String) {
    Balanced("balanced"),
    Cost("cost"),
    Latency("latency"),
    Privacy("privacy"),
    ;

    companion object {
        fun fromRawValue(value: String): OptimizeFor? = entries.firstOrNull { it.rawValue == value }
    }
}

enum class SchemaVersion(val rawValue: String) {
    V1_0("1.0"),
    ;

    companion object {
        fun fromRawValue(value: String): SchemaVersion? = entries.firstOrNull { it.rawValue == value }
    }
}

/**
 * The text_to_speech payload. Required for text_to_speech and forbidden for every other
 * kind.
 */
data class SpeechInput(
    /**
     * BCP 47 tag of the language to speak, e.g. 'de-AT'.
     */
    val locale: String,

    /**
     * 'language' (default): the primary language subtag is a hard requirement and the region is
     * a preference. 'exact': the full tag is a hard requirement.
     */
    val localeMatch: LocaleMatch? = null,

    /**
     * Plain text to speak. Markup such as SSML is out of scope.
     */
    val text: String,

    /**
     * Provider-neutral voice traits. A 'preferred' voice (default) shapes which voice speaks
     * and is never a reason to fail; a 'required' one takes part in routing and is never
     * relaxed silently. Carries no provider voice identifier.
     */
    val voice: SpeechVoice? = null,
)

/**
 * 'language' (default): the primary language subtag is a hard requirement and the region is
 * a preference. 'exact': the full tag is a hard requirement.
 *
 * 'exact' requires the full tag; 'language' requires only the primary language subtag and
 * treats the region as a preference.
 */
enum class LocaleMatch(val rawValue: String) {
    Exact("exact"),
    Language("language"),
    ;

    companion object {
        fun fromRawValue(value: String): LocaleMatch? = entries.firstOrNull { it.rawValue == value }
    }
}

/**
 * Provider-neutral voice traits. A 'preferred' voice (default) shapes which voice speaks
 * and is never a reason to fail; a 'required' one takes part in routing and is never
 * relaxed silently. Carries no provider voice identifier.
 */
data class SpeechVoice(
    val gender: VoiceGender? = null,

    /**
     * 'preferred' (default) or 'required'. A required voice must name at least one trait.
     */
    val requirement: RequirementLevel? = null,
)

/**
 * Perceived gender of a voice, as the platform reports it.
 */
enum class VoiceGender(val rawValue: String) {
    Female("female"),
    Male("male"),
    Neutral("neutral"),
    ;

    companion object {
        fun fromRawValue(value: String): VoiceGender? = entries.firstOrNull { it.rawValue == value }
    }
}

/**
 * 'preferred' (default) or 'required'. A required voice must name at least one trait.
 *
 * 'required' takes part in routing; 'preferred' does not.
 */
enum class RequirementLevel(val rawValue: String) {
    Preferred("preferred"),
    Required("required"),
    ;

    companion object {
        fun fromRawValue(value: String): RequirementLevel? = entries.firstOrNull { it.rawValue == value }
    }
}

/**
 * A descriptor specifying the type of work to be performed. The kind selects which payload
 * the request must carry.
 */
data class TaskRequestTask(
    /**
     * The operation: 'text_to_text' (prompt-based text generation) or 'text_to_speech' (speech
     * synthesis from text). A consumer built against an older revision rejects a kind it does
     * not know through validation.
     */
    val kind: TaskKind = TaskKind.TEXT_TO_TEXT,
)

/**
 * The operation: 'text_to_text' (prompt-based text generation) or 'text_to_speech' (speech
 * synthesis from text). A consumer built against an older revision rejects a kind it does
 * not know through validation.
 */
enum class TaskKind(val rawValue: String) {
    TEXT_TO_SPEECH("text_to_speech"),
    TEXT_TO_TEXT("text_to_text"),
    ;

    companion object {
        fun fromRawValue(value: String): TaskKind? = entries.firstOrNull { it.rawValue == value }
    }
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
    ;

    companion object {
        fun fromRawValue(value: String): TelemetryLevel? = entries.firstOrNull { it.rawValue == value }
    }
}

/**
 * The response payload for a completed run() execution, for every task kind; output.type
 * tells the content representation apart (text, managed playback, retrievable artifact). A
 * full execution failure (validation, routing, or every attempted provider failing) is
 * surfaced by run() throwing an IndeRunError instead of returning a TaskResult;
 * finishReason and telemetry.errorClass are reserved for a provider reporting a non-fatal,
 * degraded outcome on an otherwise-successful result (finishReason 'error' is produced by
 * the Android ML Kit GenAI provider; telemetry.errorClass is not currently set by any
 * provider in this codebase).
 */
data class TaskResult(
    /**
     * How generation ended: 'stop' (natural end), 'length' (hit maxOutputTokens), or
     * 'cancelled'. 'error' is reserved for a provider reporting a non-fatal issue on an
     * otherwise-returned result — the Android ML Kit GenAI provider produces it when Gemini
     * Nano reports a finish reason that is neither a natural stop nor the token limit. A full
     * execution failure is instead surfaced by run() throwing an IndeRunError.
     */
    val finishReason: FinishReason,

    /**
     * The normalized output of the selected provider. See task-output.schema.json.
     */
    val output: TaskOutput,

    /**
     * Normalized execution provenance: which target ran, its declared locality, the configured
     * and reported model, and how fallback and routing played out. See
     * execution-provenance.schema.json.
     */
    val provenance: ExecutionProvenance? = null,

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
 * otherwise-returned result — the Android ML Kit GenAI provider produces it when Gemini
 * Nano reports a finish reason that is neither a natural stop nor the token limit. A full
 * execution failure is instead surfaced by run() throwing an IndeRunError.
 *
 * How generation ended, mirroring TaskResult.finishReason for Mode 1: 'stop' (natural end),
 * 'length' (hit maxOutputTokens), 'error' (provider reported a non-fatal issue on an
 * otherwise completed run). 'cancelled' is included so this enum stays identical to
 * TaskResult.finishReason, but it is unreachable here: cancellation is its own terminal
 * outcome branch. Optional: providers that do not report a finish reason omit it.
 */
enum class FinishReason(val rawValue: String) {
    CANCELLED("cancelled"),
    ERROR("error"),
    LENGTH("length"),
    STOP("stop"),
    ;

    companion object {
        fun fromRawValue(value: String): FinishReason? = entries.firstOrNull { it.rawValue == value }
    }
}

/**
 * The normalized output of the selected provider. See task-output.schema.json.
 *
 * The normalized output of a run, shared by TaskResult and the completed and cancelled
 * stream terminal outcomes (ADR 016). 'type' describes the content representation, not the
 * task: 'text' carries inline text, 'playback' reports a managed, audible effect that has
 * no retrievable bytes, and 'artifact' references retrievable media (ADR 017). A playback
 * output is never an artifact, and an artifact output never implies that anything was
 * played.
 *
 * The normalized output of the run, the same shape run() returns in TaskResult.output. Set
 * for every non-text run; a text run may set it alongside finalText. See
 * task-output.schema.json.
 *
 * What a cancelled non-text run had already produced: a playback run that committed (audio
 * may have been heard) carries a playback output. Absent when nothing was produced, e.g. an
 * artifact run cancelled before its artifact was handed over, whose partial media the
 * engine discards. See task-output.schema.json.
 */
data class TaskOutput(
    /**
     * The retrievable media the run produced. Required when type is 'artifact'.
     */
    val artifact: MediaArtifact? = null,

    /**
     * Completion of managed playback. Required when type is 'playback'. Carries no media.
     */
    val playback: PlaybackOutput? = null,

    /**
     * The locale and voice traits a text-to-speech run actually used, so an unmet preference is
     * visible without being an error.
     */
    val speech: SpeechOutput? = null,

    /**
     * The text the run produced. Required when type is 'text'.
     */
    val text: String? = null,

    /**
     * The content representation: 'text', 'playback' or 'artifact'.
     */
    val type: TaskOutputType,
)

/**
 * The retrievable media the run produced. Required when type is 'artifact'.
 *
 * A reference to retrievable media a run produced (ADR 017). It carries no bytes and no
 * location: an engine-owned artifact is read through the engine by id, and an
 * application-owned one was written to an application destination. Media-neutral: audio,
 * images and video share this shape and differ only in mediaType.
 */
data class MediaArtifact(
    /**
     * Size of the media in bytes. Always set for an artifact the engine materialized.
     */
    val byteLength: Long? = null,

    /**
     * Duration of time-based media in milliseconds, where the producer knows it.
     */
    val durationMs: Double? = null,

    /**
     * Opaque, engine-issued identifier. Never a path, URL or provider identifier.
     */
    val id: String,

    /**
     * How long the engine keeps the bytes. 'until_disposed': until the application disposes the
     * artifact or the process ends; the artifact outlives the run that produced it.
     */
    val lifetime: ArtifactLifetime,

    /**
     * IANA media type of the bytes, e.g. 'audio/wav'. Encoding parameters ride on the media
     * type (e.g. 'audio/L16;rate=22050').
     */
    val mediaType: String,

    /**
     * 'engine': the engine holds the bytes and the application reads them by id until it
     * disposes the artifact. 'application': the bytes were written to the application
     * destination named by destinationRef and the engine holds nothing.
     */
    val owner: ArtifactOwner,
)

/**
 * How long the engine keeps the bytes. 'until_disposed': until the application disposes the
 * artifact or the process ends; the artifact outlives the run that produced it.
 */
enum class ArtifactLifetime(val rawValue: String) {
    UntilDisposed("until_disposed"),
    ;

    companion object {
        fun fromRawValue(value: String): ArtifactLifetime? = entries.firstOrNull { it.rawValue == value }
    }
}

/**
 * 'engine': the engine holds the bytes and the application reads them by id until it
 * disposes the artifact. 'application': the bytes were written to the application
 * destination named by destinationRef and the engine holds nothing.
 */
enum class ArtifactOwner(val rawValue: String) {
    Application("application"),
    Engine("engine"),
    ;

    companion object {
        fun fromRawValue(value: String): ArtifactOwner? = entries.firstOrNull { it.rawValue == value }
    }
}

/**
 * Completion of managed playback. Required when type is 'playback'. Carries no media.
 */
data class PlaybackOutput(
    /**
     * How long audible playback lasted, in milliseconds. For a cancelled run, how long it
     * played before it was stopped.
     */
    val durationMs: Double? = null,
)

/**
 * The locale and voice traits a text-to-speech run actually used, so an unmet preference is
 * visible without being an error.
 */
data class SpeechOutput(
    /**
     * BCP 47 tag of the locale that was spoken.
     */
    val locale: String,

    /**
     * Provider-neutral traits of the voice that spoke. Carries no provider voice identifier.
     */
    val voice: SpeechOutputVoice? = null,
)

/**
 * Provider-neutral traits of the voice that spoke. Carries no provider voice identifier.
 */
data class SpeechOutputVoice(
    val gender: VoiceGender? = null,
)

/**
 * The content representation: 'text', 'playback' or 'artifact'.
 */
enum class TaskOutputType(val rawValue: String) {
    ARTIFACT("artifact"),
    PLAYBACK("playback"),
    TEXT("text"),
    ;

    companion object {
        fun fromRawValue(value: String): TaskOutputType? = entries.firstOrNull { it.rawValue == value }
    }
}

/**
 * Normalized execution provenance: which target ran, its declared locality, the configured
 * and reported model, and how fallback and routing played out. See
 * execution-provenance.schema.json.
 *
 * Provider-neutral record of how an execution was carried out: the target the outcome is
 * attributed to, its declared locality, the configured and provider-reported model, every
 * attempt, and why other candidates were rejected. Carried on TaskResult, on every
 * StreamTerminalOutcome branch, and on IndeRunError. It reports what the engine observed
 * and what providers declared or reported; it never infers a model or locality a provider
 * did not state, and it never contains request content, credentials, or provider payloads.
 */
data class ExecutionProvenance(
    /**
     * How many providers were attempted. 0 when the request failed validation or routing, or
     * was cancelled before any attempt started.
     */
    val attemptCount: Long,

    /**
     * Every attempted provider, in attempt order, with how its attempt ended.
     */
    val attempts: List<ExecutionProvenanceAttempt>,

    /**
     * The model providerId is bound to, as its descriptor declares it. Absent when the provider
     * cannot name its model or no provider is attributed.
     */
    val configuredModel: String? = null,

    /**
     * Whether more than one provider was attempted (attemptCount > 1).
     */
    val fallbackOccurred: Boolean,

    /**
     * Where providerId declares it executes: 'on_device' for a local provider, 'edge', or
     * 'cloud'. A declaration by the provider's descriptor, not a measurement. 'unknown' when
     * providerId is absent.
     */
    val locality: Locality,

    /**
     * The model profile the request routed within; 'auto' when the request named none.
     */
    val modelProfile: String,

    /**
     * The target the outcome is attributed to: the provider that produced the result, the
     * provider a stream had committed to when it ended, or the provider that was running when
     * it was cancelled. Absent when no provider was reached or when every attempted provider
     * failed before one was committed to.
     */
    val providerId: String? = null,

    /**
     * The model identifier the provider reported in its own response. Absent means the provider
     * did not report one; it is never inferred from configuration.
     */
    val reportedModel: String? = null,

    /**
     * Providers the route planner rejected before any attempt, with the normalized RoutePlan
     * reason codes. Codes only: no provider-supplied messages.
     */
    val routeRejections: List<ExecutionProvenanceRouteRejection>,

    /**
     * Contract schema version used to interpret this provenance record.
     */
    val schemaVersion: SchemaVersion = SchemaVersion.V1_0,
)

data class ExecutionProvenanceAttempt(
    /**
     * Whether the run committed to this provider during the attempt: its first content was
     * delivered, it signalled the first possible audible effect, or it handed over an artifact.
     * After commit a failure ends the run instead of falling back. Absent means the attempt did
     * not commit.
     */
    val committed: Boolean? = null,

    /**
     * Normalized error class of a failed attempt.
     */
    val errorClass: IndeRunErrorClass? = null,

    /**
     * 'succeeded' (produced the result or was committed to and completed), 'failed', or
     * 'cancelled'.
     */
    val outcome: AttemptOutcome,

    val providerId: String,
)

/**
 * Normalized error class of a failed attempt.
 *
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
    ;

    companion object {
        fun fromRawValue(value: String): IndeRunErrorClass? = entries.firstOrNull { it.rawValue == value }
    }
}

/**
 * 'succeeded' (produced the result or was committed to and completed), 'failed', or
 * 'cancelled'.
 */
enum class AttemptOutcome(val rawValue: String) {
    Cancelled("cancelled"),
    Failed("failed"),
    Succeeded("succeeded"),
    ;

    companion object {
        fun fromRawValue(value: String): AttemptOutcome? = entries.firstOrNull { it.rawValue == value }
    }
}

/**
 * Where providerId declares it executes: 'on_device' for a local provider, 'edge', or
 * 'cloud'. A declaration by the provider's descriptor, not a measurement. 'unknown' when
 * providerId is absent.
 */
enum class Locality(val rawValue: String) {
    Cloud("cloud"),
    Edge("edge"),
    OnDevice("on_device"),
    Unknown("unknown"),
    ;

    companion object {
        fun fromRawValue(value: String): Locality? = entries.firstOrNull { it.rawValue == value }
    }
}

data class ExecutionProvenanceRouteRejection(
    val codes: List<Code>,
    val providerId: String,
)

/**
 * Normalized rejection reason. 'streaming_not_supported' means the descriptor does not
 * statically declare Mode-2 streaming; 'streaming_unavailable' means it declares streaming
 * but the dynamic capability snapshot reports it cannot stream in the current host
 * environment. 'not_in_model_profile' means the request named a model profile that does not
 * list this provider. 'input_not_supported', 'output_delivery_not_supported',
 * 'output_format_not_supported', 'locale_not_supported' and 'voice_not_available' mean the
 * provider's task capability lacks an input kind, output delivery, media type, locale or
 * voice the request requires.
 */
enum class Code(val rawValue: String) {
    CapabilityUnavailable("capability_unavailable"),
    CloudConstraint("cloud_constraint"),
    InputNotSupported("input_not_supported"),
    LocaleNotSupported("locale_not_supported"),
    NotInModelProfile("not_in_model_profile"),
    Offline("offline"),
    OutputDeliveryNotSupported("output_delivery_not_supported"),
    OutputFormatNotSupported("output_format_not_supported"),
    PrivacyConstraint("privacy_constraint"),
    RunNotSupported("run_not_supported"),
    StreamingNotSupported("streaming_not_supported"),
    StreamingUnavailable("streaming_unavailable"),
    TaskNotSupported("task_not_supported"),
    VoiceNotAvailable("voice_not_available"),
    ;

    companion object {
        fun fromRawValue(value: String): Code? = entries.firstOrNull { it.rawValue == value }
    }
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
     * The model identifier the provider reported in its own response, set by the provider when
     * its backend reports one. The engine carries it into provenance.reportedModel; it is never
     * inferred from configuration.
     */
    val reportedModel: String? = null,

    /**
     * Measured execution duration in milliseconds, including route selection and result
     * processing.
     */
    val totalMs: Double,
)

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
     * Normalized execution provenance: which target ran, its declared locality, the configured
     * and reported model, and how fallback and routing played out. See
     * execution-provenance.schema.json.
     */
    val provenance: ExecutionProvenance? = null,

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
enum class Method(val rawValue: String) {
    Delete("DELETE"),
    Get("GET"),
    Patch("PATCH"),
    Post("POST"),
    Put("PUT"),
    ;

    companion object {
        fun fromRawValue(value: String): Method? = entries.firstOrNull { it.rawValue == value }
    }
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
enum class TelemetryEventType(val rawValue: String) {
    AttemptFailed("attempt_failed"),
    AttemptSucceeded("attempt_succeeded"),
    RouteDecided("route_decided"),
    StreamAttemptFailed("stream_attempt_failed"),
    StreamAttemptStarted("stream_attempt_started"),
    StreamAttemptSucceeded("stream_attempt_succeeded"),
    StreamCancelled("stream_cancelled"),
    StreamCompleted("stream_completed"),
    StreamFailed("stream_failed"),
    ;

    companion object {
        fun fromRawValue(value: String): TelemetryEventType? = entries.firstOrNull { it.rawValue == value }
    }
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
     * The resolved model profile the request routes within. Absent means the built-in 'auto'
     * profile: no allow-list, and ordering by placement and preference alone. When present,
     * providers whose id is not in targetIds are rejected with 'not_in_model_profile', and the
     * position in targetIds ranks the survivors after placement and before preferences. Ids
     * that name no registered provider are ignored.
     */
    val modelProfile: ModelProfile? = null,

    /**
     * Soft route ordering preferences applied after hard filtering.
     */
    val preferences: RoutePlannerInputPreferences,

    /**
     * Static descriptors plus dynamic capability checks for planning. Both shapes are the
     * provider schemas themselves, shared by $ref, so the planner reads exactly what
     * checkCapabilities() reports.
     */
    val providers: List<Provider>,

    /**
     * Task descriptor for provider task matching: the kind plus the requirements routing can
     * check against declared capabilities. Absent requirement fields are never checked, so a
     * text request carries the kind alone.
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
    val privacy: Privacy? = null,
)

/**
 * Interaction mode the caller is requesting. Absent means 'run' (Mode 1), so planner inputs
 * produced before this field existed keep their exact Mode-1 semantics. The mode filters
 * eligible providers; it never changes candidate ordering.
 */
enum class InteractionMode(val rawValue: String) {
    Run("run"),
    Stream("stream"),
    ;

    companion object {
        fun fromRawValue(value: String): InteractionMode? = entries.firstOrNull { it.rawValue == value }
    }
}

/**
 * The resolved model profile the request routes within. Absent means the built-in 'auto'
 * profile: no allow-list, and ordering by placement and preference alone. When present,
 * providers whose id is not in targetIds are rejected with 'not_in_model_profile', and the
 * position in targetIds ranks the survivors after placement and before preferences. Ids
 * that name no registered provider are ignored.
 */
data class ModelProfile(
    /**
     * Profile name, carried for explanations.
     */
    val name: String,

    /**
     * Provider ids in profile order.
     */
    val targetIds: List<String>,
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
    /**
     * The provider's live capability check, already folded by the engine (for example,
     * streamingAvailable is false when the provider declares streaming but does not implement
     * it).
     */
    val capabilities: ProviderDynamicCapabilities,

    /**
     * The provider's static capability declaration.
     */
    val descriptor: ProviderDescriptor,
)

/**
 * The provider's live capability check, already folded by the engine (for example,
 * streamingAvailable is false when the provider declares streaming but does not implement
 * it).
 *
 * A provider's live capability check, evaluated on the current host when routing or when
 * checkCapabilities() is called. Unlike the descriptor it can change between calls.
 *
 * The provider's live capability check at the time of the call.
 */
data class ProviderDynamicCapabilities(
    /**
     * Whether the provider is available and functional on this host right now.
     */
    val available: Boolean,

    /**
     * Whether cancellation is honored on this host right now. Absent inherits the static
     * descriptor.cancel value: any value other than 'none' means available. Never null.
     */
    val cancellationAvailable: Boolean? = null,

    /**
     * Why the provider is unavailable, when available is false.
     */
    val reason: String? = null,

    /**
     * Whether the provider can stream (Mode 2) on this host right now. Absent inherits the
     * static descriptor.supports.streaming value; only set it when the host takes streaming
     * away from a provider that otherwise declares it. Never null.
     */
    val streamingAvailable: Boolean? = null,

    /**
     * Why streaming is unavailable, when streamingAvailable is false. Absent lets the route
     * planner synthesize a default message.
     */
    val streamingUnavailableReason: String? = null,

    /**
     * Per-task overrides of the provider-level check, for tasks whose availability differs on
     * this host, e.g. a voice that is not installed. Every field of an entry is optional and
     * absent inherits the provider-level value; a false at either level wins.
     */
    val taskCapabilities: List<ProviderTaskAvailability>? = null,
)

/**
 * The live check for one task kind.
 */
data class ProviderTaskAvailability(
    /**
     * Whether the task can run on this host right now. Absent inherits the provider-level
     * available. Never null.
     */
    val available: Boolean? = null,

    /**
     * Whether cancellation is honored for this task right now. Absent inherits. Never null.
     */
    val cancellationAvailable: Boolean? = null,

    /**
     * The task kind this entry describes.
     */
    val kind: String,

    /**
     * BCP 47 locales available for this task right now. Absent means the provider cannot
     * enumerate them.
     */
    val locales: List<String>? = null,

    /**
     * Why the task is unavailable, when available is false.
     */
    val reason: String? = null,

    /**
     * Whether the task can stream on this host right now. Absent inherits. Never null.
     */
    val streamingAvailable: Boolean? = null,

    /**
     * Why streaming is unavailable for this task, when streamingAvailable is false.
     */
    val streamingUnavailableReason: String? = null,

    /**
     * Voices available for this task right now. Absent means the provider cannot enumerate
     * them; a request that requires a voice then never routes to it.
     */
    val voices: List<ProviderVoice>? = null,
)

/**
 * Provider-neutral traits of one available voice. Carries no provider voice identifier.
 *
 * The voice this candidate must use if it is attempted, chosen by the planner from the
 * provider's dynamic voice inventory. It is the best voice that satisfies the request's
 * locale, required voice traits and privacy — under local-required privacy always one that
 * keeps data on the device — ranked by preferred gender, then exact locale region, then
 * on-device before network. The adapter must use a voice with exactly these traits. Absent
 * when the request names no locale or voice, or the provider does not list its voices; the
 * adapter then chooses itself under the same rules.
 */
data class ProviderVoice(
    val gender: VoiceGender? = null,

    /**
     * BCP 47 locale the voice speaks.
     */
    val locale: String,

    /**
     * Whether using the voice sends data off the device. Absent inherits the task's privacy
     * posture.
     */
    val networkRequired: Boolean? = null,
)

/**
 * The provider's static capability declaration.
 *
 * A provider's static capability declaration: identity, placement, transport, supported
 * interaction modes and tasks, cancellation guarantee, resource limits and privacy posture.
 * It does not change while the provider is registered. The route planner,
 * checkCapabilities() and execution provenance all read this one shape.
 */
data class ProviderDescriptor(
    /**
     * Cancellation guarantee: 'hard' stops processing including remote work, 'soft' stops
     * reading locally while remote work may continue, 'none' means cancellation is unsupported.
     * Independently of this value, the engine delivers no event after a cancel.
     */
    val cancel: CancelSemantics,

    /**
     * Unique identifier of the provider instance (a target), e.g. 'apple_foundation_models' or
     * 'openai_compatible_cloud:gpt-5-mini'. Model profiles list targets by this id.
     */
    val id: String,

    /**
     * Optional input and output resource limits.
     */
    val limits: ProviderLimits? = null,

    /**
     * The model this provider instance is bound to, when it can name one. Cloud providers
     * report the model id they send; platform-managed models report an opaque platform alias
     * rather than a guessed weight name. Absent means the provider cannot name its model.
     */
    val model: String? = null,

    /**
     * Data-egress posture, used to enforce local and cloud routing rules. Absent means a local
     * or edge provider is treated as keeping data on the device and a cloud provider as sending
     * it off.
     */
    val privacy: ProviderPrivacy? = null,

    /**
     * How a streaming provider delivers incremental output: individual tokens, larger chunks,
     * or whole snapshots. Absent for providers that do not stream.
     */
    val streamingStyle: StreamingStyle? = null,

    /**
     * Interaction modes and features the provider statically declares.
     */
    val supports: ProviderSupports,

    /**
     * What the provider can do for each task: accepted inputs, interaction modes, output
     * deliveries and formats, cancellation, locales and privacy. When present it is
     * authoritative for routing and must list every task the provider serves. When absent (a
     * legacy descriptor), routing infers exactly one entry — 'text_to_text' with text input,
     * inline output, run/stream from supports and cancel from cancel — if tasks contains
     * 'text_to_text', and nothing for any other task: a legacy descriptor is never treated as
     * capable of a non-text task.
     */
    val taskCapabilities: List<ProviderTaskCapability>? = null,

    /**
     * Task kinds the provider supports, e.g. 'text_to_text'. When taskCapabilities is present
     * it must describe the same kinds and is what routing reads; without it, routing infers
     * capabilities for 'text_to_text' alone (see taskCapabilities).
     */
    val tasks: List<String>,

    /**
     * How the engine reaches the provider: in-process runtime, operating-system service,
     * buffered HTTP, server-sent events, or a realtime connection.
     */
    val transport: ProviderTransport,

    /**
     * Execution placement: 'local' (on the device), 'edge', or 'cloud'.
     */
    val type: ProviderType,
)

/**
 * Cancellation guarantee: 'hard' stops processing including remote work, 'soft' stops
 * reading locally while remote work may continue, 'none' means cancellation is unsupported.
 * Independently of this value, the engine delivers no event after a cancel.
 *
 * Cancellation guarantee for this task. It may differ from the provider-level cancel, e.g.
 * when stopping playback is immediate but a synthesis request cannot be aborted.
 */
enum class CancelSemantics(val rawValue: String) {
    Hard("hard"),
    None("none"),
    Soft("soft"),
    ;

    companion object {
        fun fromRawValue(value: String): CancelSemantics? = entries.firstOrNull { it.rawValue == value }
    }
}

/**
 * Optional input and output resource limits.
 */
data class ProviderLimits(
    /**
     * Longest accepted or produced audio, in seconds.
     */
    val maxAudioSeconds: Long? = null,

    /**
     * Largest accepted image, in bytes.
     */
    val maxImageBytes: Long? = null,

    /**
     * Largest accepted input, in tokens.
     */
    val maxInputTokens: Long? = null,

    /**
     * Largest output the provider produces, in tokens.
     */
    val maxOutputTokens: Long? = null,
)

/**
 * Data-egress posture, used to enforce local and cloud routing rules. Absent means a local
 * or edge provider is treated as keeping data on the device and a cloud provider as sending
 * it off.
 *
 * Data-egress posture for this task when it differs from the provider-level privacy, e.g. a
 * provider whose speech synthesis uses a network service. Absent inherits
 * descriptor.privacy.
 */
data class ProviderPrivacy(
    /**
     * Whether request content leaves the device.
     */
    val dataLeavesDevice: Boolean,

    /**
     * Geographic regions where a cloud provider processes data.
     */
    val regions: List<String>? = null,
)

/**
 * How a streaming provider delivers incremental output: individual tokens, larger chunks,
 * or whole snapshots. Absent for providers that do not stream.
 */
enum class StreamingStyle(val rawValue: String) {
    Chunks("chunks"),
    Snapshots("snapshots"),
    Tokens("tokens"),
    ;

    companion object {
        fun fromRawValue(value: String): StreamingStyle? = entries.firstOrNull { it.rawValue == value }
    }
}

/**
 * Interaction modes and features the provider statically declares.
 */
data class ProviderSupports(
    /**
     * Whether the provider accepts non-text inputs such as images or audio.
     */
    val multimodal: Boolean,

    /**
     * Whether the provider supports Mode 3 realtime sessions. Reserved; no engine implements
     * Mode 3 yet.
     */
    val realtime: Boolean,

    /**
     * Whether the provider emits reasoning events alongside content.
     */
    val reasoningEvents: Boolean,

    /**
     * Whether the provider supports Mode 1 run (request/response).
     */
    val run: Boolean,

    /**
     * Whether the provider supports Mode 2 stream. A provider that declares it must also
     * implement the streaming adapter; the engines report it as unavailable otherwise.
     */
    val streaming: Boolean,

    /**
     * Whether the provider supports structured output constrained by a JSON schema.
     */
    val structuredOutput: Boolean,

    /**
     * Whether the provider supports tool calling.
     */
    val tools: Boolean,
)

/**
 * The provider's static capabilities for one task kind.
 */
data class ProviderTaskCapability(
    /**
     * Cancellation guarantee for this task. It may differ from the provider-level cancel, e.g.
     * when stopping playback is immediate but a synthesis request cannot be aborted.
     */
    val cancel: CancelSemantics,

    /**
     * Input media kinds the provider accepts for this task.
     */
    val inputs: List<TaskInputKind>,

    /**
     * Interaction modes the provider supports for this task.
     */
    val interaction: ProviderTaskInteraction,

    /**
     * The task kind this entry describes, e.g. 'text_to_speech'.
     */
    val kind: String,

    /**
     * BCP 47 locales the provider can serve for this task, when it knows them statically.
     * Absent means unknown; the dynamic check may report them instead.
     */
    val locales: List<String>? = null,

    /**
     * How results of this task can be delivered. A provider lists only what it really produces:
     * a provider that can only play audio lists 'playback' and never 'artifact'.
     */
    val outputs: List<ProviderTaskOutput>,

    /**
     * Data-egress posture for this task when it differs from the provider-level privacy, e.g. a
     * provider whose speech synthesis uses a network service. Absent inherits
     * descriptor.privacy.
     */
    val privacy: ProviderPrivacy? = null,
)

/**
 * A kind of input medium a task consumes.
 */
enum class TaskInputKind(val rawValue: String) {
    Audio("audio"),
    Image("image"),
    Text("text"),
    ;

    companion object {
        fun fromRawValue(value: String): TaskInputKind? = entries.firstOrNull { it.rawValue == value }
    }
}

/**
 * Interaction modes the provider supports for this task.
 */
data class ProviderTaskInteraction(
    /**
     * Whether the provider supports Mode 1 run for this task.
     */
    val run: Boolean,

    /**
     * Whether the provider supports Mode 2 stream for this task.
     */
    val stream: Boolean,
)

/**
 * One way the provider can deliver a task's result.
 */
data class ProviderTaskOutput(
    val delivery: OutputDelivery,

    /**
     * Media types the provider can produce with this delivery, e.g. 'audio/wav'. Absent means
     * the provider does not declare them; a request that requires specific media types never
     * routes to such an output.
     */
    val mediaTypes: List<String>? = null,
)

/**
 * How the engine reaches the provider: in-process runtime, operating-system service,
 * buffered HTTP, server-sent events, or a realtime connection.
 */
enum class ProviderTransport(val rawValue: String) {
    HTTP("http"),
    InProcess("in_process"),
    Realtime("realtime"),
    SSE("sse"),
    SystemService("system_service"),
    ;

    companion object {
        fun fromRawValue(value: String): ProviderTransport? = entries.firstOrNull { it.rawValue == value }
    }
}

/**
 * Execution placement: 'local' (on the device), 'edge', or 'cloud'.
 */
enum class ProviderType(val rawValue: String) {
    Cloud("cloud"),
    Edge("edge"),
    Local("local"),
    ;

    companion object {
        fun fromRawValue(value: String): ProviderType? = entries.firstOrNull { it.rawValue == value }
    }
}

/**
 * Task descriptor for provider task matching: the kind plus the requirements routing can
 * check against declared capabilities. Absent requirement fields are never checked, so a
 * text request carries the kind alone.
 */
data class RoutePlannerInputTask(
    /**
     * The output delivery the request requires. Absent for text, whose delivery is implicitly
     * inline.
     */
    val delivery: DeliveryRequirement? = null,

    /**
     * Input media kinds the request carries. Every one must be accepted by the provider's task
     * capability. The SDKs send ['text'] for text_to_text.
     */
    val inputs: List<TaskInputKind>? = null,

    /**
     * The task kind, matched against the providers' task capabilities.
     */
    val kind: String,

    /**
     * The locale the request requires. Under 'language' matching the region is a preference: a
     * provider known to offer the exact tag ranks ahead of an otherwise equal one. A provider
     * that cannot enumerate its locales is not rejected on this basis; it must fail before
     * committing instead.
     */
    val locale: LocaleRequirement? = null,

    /**
     * Voice traits the request asks for. Only a 'required' voice can reject a provider; a
     * 'preferred' one shapes which listed voice the plan binds a candidate to, always within
     * the request's privacy policy.
     */
    val voice: VoiceRequirement? = null,
)

/**
 * The output delivery the request requires. Absent for text, whose delivery is implicitly
 * inline.
 */
data class DeliveryRequirement(
    /**
     * Acceptable media types; the provider must declare at least one for the requested
     * delivery. Absent means any.
     */
    val mediaTypes: List<String>? = null,

    val mode: OutputDelivery,
)

/**
 * The locale the request requires. Under 'language' matching the region is a preference: a
 * provider known to offer the exact tag ranks ahead of an otherwise equal one. A provider
 * that cannot enumerate its locales is not rejected on this basis; it must fail before
 * committing instead.
 */
data class LocaleRequirement(
    /**
     * 'exact' requires the full tag; 'language' requires only the primary language subtag and
     * treats the region as a preference.
     */
    val match: LocaleMatch,

    /**
     * BCP 47 tag.
     */
    val tag: String,
)

/**
 * Voice traits the request asks for. Only a 'required' voice can reject a provider; a
 * 'preferred' one shapes which listed voice the plan binds a candidate to, always within
 * the request's privacy policy.
 */
data class VoiceRequirement(
    val gender: VoiceGender? = null,

    /**
     * 'required' takes part in routing; 'preferred' does not.
     */
    val requirement: RequirementLevel,
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

    /**
     * The voice this candidate must use if it is attempted, chosen by the planner from the
     * provider's dynamic voice inventory. It is the best voice that satisfies the request's
     * locale, required voice traits and privacy — under local-required privacy always one that
     * keeps data on the device — ranked by preferred gender, then exact locale region, then
     * on-device before network. The adapter must use a voice with exactly these traits. Absent
     * when the request names no locale or voice, or the provider does not list its voices; the
     * adapter then chooses itself under the same rules.
     */
    val voice: ProviderVoice? = null,
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
enum class FailureCode(val rawValue: String) {
    CapabilityMismatch("capability_mismatch"),
    Offline("offline"),
    Unavailable("unavailable"),
    ;

    companion object {
        fun fromRawValue(value: String): FailureCode? = entries.firstOrNull { it.rawValue == value }
    }
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
     * environment. 'not_in_model_profile' means the request named a model profile that does not
     * list this provider. 'input_not_supported', 'output_delivery_not_supported',
     * 'output_format_not_supported', 'locale_not_supported' and 'voice_not_available' mean the
     * provider's task capability lacks an input kind, output delivery, media type, locale or
     * voice the request requires.
     */
    val code: Code,

    val message: String,
)

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
enum class Format(val rawValue: String) {
    Genai("genai"),
    Onnx("onnx"),
    Ort("ort"),
    ;

    companion object {
        fun fromRawValue(value: String): Format? = entries.firstOrNull { it.rawValue == value }
    }
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
enum class SourceType(val rawValue: String) {
    AppManaged("app_managed"),
    Bundled("bundled"),
    Filesystem("filesystem"),
    Programmatic("programmatic"),
    Registry("registry"),
    Remote("remote"),
    ;

    companion object {
        fun fromRawValue(value: String): SourceType? = entries.firstOrNull { it.rawValue == value }
    }
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
 * as a hard error. All three engines implement this union (see
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
     * — providers reporting that style normalize to content_snapshot rather than content_delta.
     * Retraction: a provider of any streamingStyle may additionally emit a content_snapshot to
     * withdraw content it has already delivered, since a snapshot replaces the run's cumulative
     * text rather than appending to it; an empty one therefore resets that text to nothing.
     * This is how a provider whose backend rejects an in-flight response after partial delivery
     * — an on-device safety/policy check, for example — tells consumers to discard what they
     * have, so a consumer must handle content_snapshot even when the provider's declared style
     * is 'tokens' or 'chunks'.
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
    val finishReason: FinishReason? = null,
    val outcome: Outcome? = null,
    val output: TaskOutput? = null,

    /**
     * Normalized execution provenance: which target ran, its declared locality, the configured
     * and reported model, and how fallback and routing played out. See
     * execution-provenance.schema.json.
     */
    val provenance: ExecutionProvenance? = null,

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

    /**
     * Normalized execution provenance: which target ran, its declared locality, the configured
     * and reported model, and how fallback and routing played out. See
     * execution-provenance.schema.json.
     */
    val provenance: ExecutionProvenance? = null,

    val providerId: String? = null,
    val retryable: Boolean? = null,
    val retryAfterMs: Long? = null,
    val schemaVersion: SchemaVersion = SchemaVersion.V1_0,
)

enum class Outcome(val rawValue: String) {
    Cancelled("cancelled"),
    Completed("completed"),
    Error("error"),
    ;

    companion object {
        fun fromRawValue(value: String): Outcome? = entries.firstOrNull { it.rawValue == value }
    }
}

/**
 * The lifecycle phase reached.
 */
enum class Phase(val rawValue: String) {
    ProviderSelected("provider_selected"),
    Started("started"),
    ;

    companion object {
        fun fromRawValue(value: String): Phase? = entries.firstOrNull { it.rawValue == value }
    }
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
 * outcome is a fixed architectural guarantee, not something new outcome kinds get added to;
 * the payload of each branch may grow additively). Exactly one StreamTerminalOutcome is
 * produced per run, and no further StreamEvent is delivered after it (see
 * docs/architecture/architecture.md, 'Cancellation And Fallback'). This shape is also
 * embedded by value as the payload of the terminal StreamEvent (stream-event.schema.json)
 * so it can additionally be exposed standalone, e.g. as a completion future/promise a
 * stream handle resolves independently of consuming the full event sequence; the two copies
 * must stay structurally identical. Note on additionalProperties: per this repo's
 * forward-compatible convention every branch permits unknown extra fields, so mutual
 * exclusivity is enforced via the required 'outcome' discriminator plus each branch's own
 * required peer field being present (finalText or output / error), and for 'cancelled' by
 * the discriminator alone, not by forbidding a payload from also carrying an unrelated
 * stray field from another branch's vocabulary.
 */
data class StreamTerminalOutcome(
    /**
     * The full, cumulative text produced by a text run. Equivalent in role to
     * TaskResult.output.text for Mode 1. A text run sets it; a non-text run carries output
     * instead.
     */
    val finalText: String? = null,

    /**
     * How generation ended, mirroring TaskResult.finishReason for Mode 1: 'stop' (natural end),
     * 'length' (hit maxOutputTokens), 'error' (provider reported a non-fatal issue on an
     * otherwise completed run). 'cancelled' is included so this enum stays identical to
     * TaskResult.finishReason, but it is unreachable here: cancellation is its own terminal
     * outcome branch. Optional: providers that do not report a finish reason omit it.
     */
    val finishReason: FinishReason? = null,

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
     * The normalized output of the run, the same shape run() returns in TaskResult.output. Set
     * for every non-text run; a text run may set it alongside finalText. See
     * task-output.schema.json.
     *
     * What a cancelled non-text run had already produced: a playback run that committed (audio
     * may have been heard) carries a playback output. Absent when nothing was produced, e.g. an
     * artifact run cancelled before its artifact was handed over, whose partial media the
     * engine discards. See task-output.schema.json.
     */
    val output: TaskOutput? = null,

    /**
     * Normalized execution provenance: which target ran, its declared locality, the configured
     * and reported model, and how fallback and routing played out. See
     * execution-provenance.schema.json.
     */
    val provenance: ExecutionProvenance? = null,

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
     * Whatever cumulative text a text run had already delivered before it failed after
     * committing to its provider. Absent when nothing was delivered.
     *
     * Whatever cumulative text a text run had already delivered via
     * content_delta/content_snapshot StreamEvents before the cancellation point. Always set for
     * a text run, and empty if cancellation occurred before any content was produced. A
     * non-text run never sets it.
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
     * Normalized execution provenance: which target ran, its declared locality, the configured
     * and reported model, and how fallback and routing played out. See
     * execution-provenance.schema.json.
     */
    val provenance: ExecutionProvenance? = null,

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

/**
 * One registered provider's identity, static declaration and live capability check, as
 * returned by checkCapabilities(). A read-only snapshot: producing it executes no task and
 * has no side effects.
 */
data class ProviderCapabilitySnapshot(
    /**
     * The provider's live capability check at the time of the call.
     */
    val capabilities: ProviderDynamicCapabilities,

    /**
     * The provider's static capability declaration.
     */
    val descriptor: ProviderDescriptor,

    /**
     * Identifier of the provider; equal to descriptor.id.
     */
    val providerId: String,
)
