package app.independo.inderun.sdk

import app.independo.inderun.contracts.ExecutionProvenance
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.LocaleMatch
import app.independo.inderun.contracts.MediaArtifact
import app.independo.inderun.contracts.Outcome
import app.independo.inderun.contracts.OutputDelivery
import app.independo.inderun.contracts.OutputDeliveryRequest
import app.independo.inderun.contracts.ProviderReadiness
import app.independo.inderun.contracts.RequirementLevel
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.SpeechInput
import app.independo.inderun.contracts.SpeechOutput
import app.independo.inderun.contracts.SpeechVoice
import app.independo.inderun.contracts.StreamEvent
import app.independo.inderun.contracts.TaskKind
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestTask
import app.independo.inderun.contracts.TaskRequestTelemetry
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.VoiceGender
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ModelProfiles
import app.independo.inderun.core.createInternal
import app.independo.inderun.sdk.generated.IndeRunApi
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.flow.firstOrNull
import kotlinx.coroutines.launch

// The primary speech API: `speak`, `generateSpeech`, and `listVoices`.
//
// Translation only, like the text API. Each speaking call compiles to exactly one canonical
// `text_to_speech` `TaskRequest`; `listVoices` reads `checkCapabilities`. `speak` is written over
// `stream` because a stream is the only execution a caller can cancel, and stopping audio is the
// point of a playback handle. Mirrors the Web SDK's `facade/speech.ts`; the shared vectors in
// `contracts/fixtures/facade/speech.json` hold the two to the same translation. See ADR 018 and
// `docs/architecture/api-layering.md`.

/** The same policy object as the text API, so a constraint means the same in both. */
typealias SpeechExecutionOptions = TextExecutionOptions

/**
 * Options for [speak].
 *
 * @property text The text to speak. Plain text; markup such as SSML is out of scope.
 * @property locale BCP 47 tag, e.g. `"de-AT"`.
 * @property localeMatch [LocaleMatch.Language] (default) requires the language and prefers the
 *   region, so `de-AT` may be served by `de-DE`. [LocaleMatch.Exact] requires the whole tag.
 * @property voice The voice: [SpeechVoiceInfo.asSpeechVoice] for an entry of [listVoices], or
 *   provider-neutral traits. A required one never relaxes silently.
 * @property model Model profile to route within, as configured on the engine. Null or `"auto"`
 *   routes across every registered target. Never a vendor model or voice id.
 * @property authContextRef Secure-storage slot for provider credentials. Never a raw secret.
 * @property requestId Fixes the run id, for correlation.
 */
data class SpeakOptions(
    val text: String,
    val locale: String,
    val localeMatch: LocaleMatch? = null,
    val voice: SpeechVoice? = null,
    val model: String? = null,
    val execution: SpeechExecutionOptions? = null,
    val authContextRef: String? = null,
    val telemetry: TaskRequestTelemetry? = null,
    val requestId: String? = null,
) {
    /** The canonical [TaskRequest] a [speak] call compiles to. */
    fun toTaskRequest(): TaskRequest = toTaskRequest(OutputDeliveryRequest(mode = OutputDelivery.Playback))

    internal fun toTaskRequest(delivery: OutputDeliveryRequest): TaskRequest = TaskRequest(
        schemaVersion = SchemaVersion.V1_0,
        task = TaskRequestTask(kind = TaskKind.TEXT_TO_SPEECH),
        speech = SpeechInput(locale = locale, localeMatch = localeMatch, text = text, voice = voice),
        delivery = delivery,
        modelProfile = model.takeUnless { it == ModelProfiles.AUTO },
        constraints = execution?.taskConstraints(),
        preferences = execution?.taskPreferences(),
        telemetry = telemetry,
        authContextRef = authContextRef,
        requestId = requestId,
    )
}

/**
 * Options for [generateSpeech].
 *
 * @property mediaTypes Acceptable media types; always a hard requirement. Null lets the provider
 *   choose.
 * @property destinationRef Opaque application destination, resolved by the host. Never a path or
 *   URL.
 */
data class GenerateSpeechOptions(
    val speech: SpeakOptions,
    val mediaTypes: List<String>? = null,
    val destinationRef: String? = null,
) {
    /** The canonical [TaskRequest] a [generateSpeech] call compiles to. */
    fun toTaskRequest(): TaskRequest = speech.toTaskRequest(
        OutputDeliveryRequest(destinationRef = destinationRef, mediaTypes = mediaTypes, mode = OutputDelivery.Artifact),
    )
}

/**
 * How a [speak] run ended, when it did not fail.
 *
 * @property finishReason [FinishReason.CANCELLED] when playback was stopped; otherwise as the
 *   provider reported it.
 * @property durationMs How long the audio played, where the provider knows it.
 * @property speech The locale and voice actually used, so an unmet preference is visible.
 */
data class SpokenSpeech(
    val finishReason: FinishReason?,
    val durationMs: Double?,
    val speech: SpeechOutput?,
    val runId: String,
    val provenance: ExecutionProvenance?,
)

/** What [speak] returns: a handle on playback in progress. */
class SpeechPlayback internal constructor(
    val runId: String,
    /**
     * The run's ending: completes when playback finishes or is stopped, fails with the run's
     * [IndeRunException] on failure.
     */
    val result: Deferred<SpokenSpeech>,
    private val onCancel: (String?) -> Unit,
) {
    /** Stops playback; idempotent. */
    fun cancel(reason: String? = null) = onCancel(reason)
}

/**
 * What [generateSpeech] returns.
 *
 * @property artifact A reference to the audio. Read it with `readArtifact`, release it with
 *   `disposeArtifact`.
 * @property speech The locale and voice actually used, so an unmet preference is visible.
 * @property taskResult The canonical result, for anything the summary leaves out.
 */
data class GeneratedSpeech(
    val artifact: MediaArtifact,
    val speech: SpeechOutput?,
    val finishReason: FinishReason,
    val runId: String,
    val provenance: ExecutionProvenance?,
    val taskResult: TaskResult,
)

/**
 * A voice a registered provider offers right now. Pass [asSpeechVoice] as `voice` to speak with
 * it. [id] is opaque and meaningful only on [providerId] on this device: read it, store it, but
 * never write one by hand.
 *
 * @property id Null when the provider cannot address single voices.
 * @property name Label for showing the voice to a person. Not unique, so never compare it.
 * @property networkRequired `true` when the voice sends text off the device. Null inherits the
 *   provider's posture.
 */
data class SpeechVoiceInfo(
    val providerId: String,
    val locale: String,
    val gender: VoiceGender? = null,
    val networkRequired: Boolean? = null,
    val id: String? = null,
    val name: String? = null,
    /** `NotPrepared` and `Preparing` mean "not yet". Null means ready. See `prepare`. */
    val readiness: ProviderReadiness? = null,
) {
    /**
     * This voice as a request's `voice`. Left preferred, it falls back to its traits when it is
     * gone or another provider serves the run; a required one never relaxes silently.
     */
    fun asSpeechVoice(requirement: RequirementLevel? = null): SpeechVoice = SpeechVoice(
        gender = gender,
        id = id,
        providerId = providerId.takeIf { id != null },
        requirement = requirement,
    )
}

/**
 * Speaks through the device: `stream` over a `playback` request. The audible effect is managed by
 * the provider; the application gets a completion and a way to stop it, never bytes. The run is
 * read in [scope], and reading is what keeps it alive: cancelling [scope] tears the run down, which
 * stops the audio too, but [SpeechPlayback.result] then fails with `CancellationException` and no
 * `cancelled` outcome is reported. Stop on purpose with [SpeechPlayback.cancel].
 *
 * @throws IndeRunException exactly as `stream` does: validation and routing refusals, before any
 *   audio could start.
 */
suspend fun IndeRunApi.speak(options: SpeakOptions, scope: CoroutineScope): SpeechPlayback {
    val run = stream(options.toTaskRequest())
    val runId = run.handle.runId
    val result = CompletableDeferred<SpokenSpeech>()
    scope.launch {
        try {
            // As in `streamText`: the terminal event settles the run, and a source that stays
            // open after it must not hold the result back.
            val terminal = run.events.firstOrNull { it.type == "terminal" }
                ?: throw createInternal("Run $runId ended without a terminal event.", runId = runId)
            result.complete(settleSpeech(terminal, runId))
        } catch (cancelled: CancellationException) {
            result.completeExceptionally(cancelled)
            throw cancelled
        } catch (error: Throwable) {
            // Already reported through `result`. Rethrowing would fail this child and, in an
            // ordinary scope, reach the uncaught-exception handler even when the caller awaits it.
            result.completeExceptionally(error)
        }
    }
    return SpeechPlayback(runId, result) { reason -> run.cancel(reason) }
}

/**
 * Synthesizes retrievable audio: `run` over an `artifact` request. Silent, and not cancellable for
 * the same reason `run` is not. A provider that can only play audio is refused by routing.
 *
 * @throws IndeRunException exactly as `run` does.
 */
suspend fun IndeRunApi.generateSpeech(options: GenerateSpeechOptions): GeneratedSpeech {
    val result = run(options.toTaskRequest())
    return GeneratedSpeech(
        // The engine checks the output against the requested delivery before it returns, so only
        // a foreign `IndeRunApi` can leave this empty.
        artifact = result.output.artifact
            ?: throw createInternal("Run ${result.runId} returned no artifact.", runId = result.runId),
        speech = result.output.speech,
        finishReason = result.finishReason,
        runId = result.runId,
        provenance = result.provenance,
        taskResult = result,
    )
}

/**
 * Lists the voices the registered providers offer right now, in registration and provider order.
 * A provider that is unavailable contributes none; one that cannot enumerate its voices
 * contributes none either, and can still serve a request.
 *
 * @param locale Keep only voices that can serve this BCP 47 tag.
 * @param localeMatch How [locale] compares, with the same meaning as on a request.
 */
suspend fun IndeRunApi.listVoices(locale: String? = null, localeMatch: LocaleMatch? = null): List<SpeechVoiceInfo> = checkCapabilities().flatMap { snapshot ->
    val task = snapshot.capabilities.taskCapabilities
        ?.firstOrNull { it.kind == TaskKind.TEXT_TO_SPEECH.rawValue }
        ?.takeIf { snapshot.capabilities.available && it.available != false }
    task?.voices.orEmpty()
        .filter { voice -> locale == null || localeMatches(voice.locale, locale, localeMatch) }
        .map { SpeechVoiceInfo(snapshot.providerId, it.locale, it.gender, it.networkRequired, it.id, it.name, it.readiness) }
}

/** Case-insensitive BCP 47 comparison, the same one the route planner applies. */
private fun localeMatches(available: String, wanted: String, match: LocaleMatch?): Boolean {
    if (match == LocaleMatch.Exact) return available.equals(wanted, ignoreCase = true)
    val primary = { tag: String -> tag.split('-', '_').first() }
    return primary(available).equals(primary(wanted), ignoreCase = true)
}

private fun settleSpeech(terminal: StreamEvent, runId: String): SpokenSpeech {
    val payload = terminal.payload
    val output = payload?.output
    return when (payload?.outcome) {
        Outcome.Completed -> SpokenSpeech(payload.finishReason, output?.playback?.durationMs, output?.speech, runId, payload.provenance)
        Outcome.Cancelled -> SpokenSpeech(FinishReason.CANCELLED, output?.playback?.durationMs, output?.speech, runId, payload.provenance)
        Outcome.Error -> throw exceptionFromTerminal(payload, runId)
        null -> throw createInternal("Run $runId ended with a malformed terminal event.", runId = runId)
    }
}
