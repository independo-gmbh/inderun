package app.independo.inderun.core

import app.independo.inderun.contracts.ControlApplicationPlan
import app.independo.inderun.contracts.ControlDecision
import app.independo.inderun.contracts.ControlRequirement
import app.independo.inderun.contracts.DeliveryRequirement
import app.independo.inderun.contracts.LocaleMatch
import app.independo.inderun.contracts.LocaleRequirement
import app.independo.inderun.contracts.OutputDelivery
import app.independo.inderun.contracts.Privacy
import app.independo.inderun.contracts.ProviderVoice
import app.independo.inderun.contracts.RequirementLevel
import app.independo.inderun.contracts.RoutePlannerInputTask
import app.independo.inderun.contracts.SpeechControlId
import app.independo.inderun.contracts.SpeechControlMethod
import app.independo.inderun.contracts.SpeechControlOutcome
import app.independo.inderun.contracts.SpeechControlOutcomeReason
import app.independo.inderun.contracts.SpeechControlStatus
import app.independo.inderun.contracts.SpeechOutput
import app.independo.inderun.contracts.TaskInputKind
import app.independo.inderun.contracts.TaskKind
import app.independo.inderun.contracts.TaskOutput
import app.independo.inderun.contracts.TaskOutputType
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.VoiceRequirement

/**
 * What the engine needs to know about one task kind (ADR 016). This table is the only place
 * the engine branches on `task.kind`: which kinds it executes, the request requirements per
 * kind, the projection onto the planner's task requirements, and the output delivery a result
 * must have. Everything else — routing, fallback, cancellation, provenance — is task-agnostic,
 * so a new task adds an entry here rather than a second execution path.
 *
 * The Web (`task-profiles.ts`) and Swift (`TaskProfiles.swift`) engines keep the same table;
 * `contracts/fixtures/task-contracts/` holds the planner projection all three must produce for
 * each request.
 */
interface TaskProfile {
    /** The `task.kind` this profile describes. */
    val kind: TaskKind

    /**
     * The request's per-kind validation issues, empty when it is valid. Kotlin has no schema
     * validator, so these reproduce the `if`/`then` branches of `task-request.schema.json`.
     */
    fun validate(request: TaskRequest): List<String>

    /** Projects the request onto the requirements the shared planner can check. */
    fun plannerTask(request: TaskRequest): RoutePlannerInputTask

    /** The output delivery the request asks for: [OutputDelivery.Inline] for text, else `delivery.mode`. */
    fun delivery(request: TaskRequest): OutputDelivery
}

private object TextToTextProfile : TaskProfile {
    override val kind = TaskKind.TEXT_TO_TEXT

    override fun validate(request: TaskRequest): List<String> = buildList {
        if (request.prompt != null && request.prompt!!.isBlank()) {
            add("prompt must be non-empty when provided.")
        }
        if (request.messages?.any { it.content.isBlank() } == true) {
            add("messages[].content must be non-empty.")
        }
        if (request.prompt.isNullOrBlank() && request.messages.isNullOrEmpty()) {
            add("Either prompt or messages must be provided and non-empty.")
        }
        if (request.speech != null) add("speech is not allowed for task.kind 'text_to_text'.")
        if (request.delivery != null) add("delivery is not allowed for task.kind 'text_to_text'.")
    }

    override fun plannerTask(request: TaskRequest): RoutePlannerInputTask = RoutePlannerInputTask(
        kind = kind.rawValue,
        inputs = listOf(TaskInputKind.Text),
    )

    override fun delivery(request: TaskRequest): OutputDelivery = OutputDelivery.Inline
}

private object TextToSpeechProfile : TaskProfile {
    override val kind = TaskKind.TEXT_TO_SPEECH

    override fun validate(request: TaskRequest): List<String> = buildList {
        if (request.prompt != null) add("prompt is not allowed for task.kind 'text_to_speech'.")
        if (request.messages != null) add("messages is not allowed for task.kind 'text_to_speech'.")
        if (request.generation != null) add("generation is not allowed for task.kind 'text_to_speech'.")

        val speech = request.speech
        if (speech == null) {
            add("speech is required for task.kind 'text_to_speech'.")
        } else {
            if (speech.text.isEmpty()) add("speech.text must be non-empty.")
            if (speech.locale.isEmpty()) add("speech.locale must be non-empty.")
            if (speech.voice?.id != null && speech.voice?.providerId == null) {
                add("speech.voice.providerId must be provided with speech.voice.id.")
            }
            if (speech.voice?.requirement == RequirementLevel.Required && speech.voice?.gender == null && speech.voice?.id == null) {
                add("speech.voice with requirement 'required' must name an id or a gender.")
            }
            speech.controls?.speakingRate?.let { rate ->
                if (!(rate.value.isFinite() && rate.value > 0)) {
                    add("speech.controls.speakingRate.value must be a finite number greater than 0.")
                }
            }
            speech.controls?.pitch?.let { pitch ->
                if (!(pitch.value.isFinite() && pitch.value > 0)) {
                    add("speech.controls.pitch.value must be a finite number greater than 0.")
                }
            }
        }

        val delivery = request.delivery
        if (delivery == null) {
            add("delivery is required for task.kind 'text_to_speech'.")
        } else {
            if (delivery.mode != OutputDelivery.Playback && delivery.mode != OutputDelivery.Artifact) {
                add("delivery.mode must be 'playback' or 'artifact' for task.kind 'text_to_speech'.")
            }
            delivery.destinationRef?.let { destinationRef ->
                if (delivery.mode != OutputDelivery.Artifact) {
                    add("delivery.destinationRef is only allowed with delivery.mode 'artifact'.")
                }
                if (destinationRef.isEmpty()) {
                    add("delivery.destinationRef must be non-empty.")
                }
            }
            delivery.playback?.let { playback ->
                if (delivery.mode != OutputDelivery.Playback) {
                    add("delivery.playback is only allowed with delivery.mode 'playback'.")
                }
                playback.volume?.let { volume ->
                    if (!(volume.value.isFinite() && volume.value >= 0 && volume.value <= 1)) {
                        add("delivery.playback.volume.value must be a finite number from 0 to 1.")
                    }
                }
            }
            val mediaTypes = delivery.mediaTypes
            if (mediaTypes != null) {
                if (delivery.mode != OutputDelivery.Artifact) {
                    add("delivery.mediaTypes is only allowed with delivery.mode 'artifact'.")
                }
                if (mediaTypes.isEmpty() || mediaTypes.any { it.isEmpty() }) {
                    add("delivery.mediaTypes must be a non-empty list of non-empty media types.")
                }
                if (mediaTypes.toSet().size != mediaTypes.size) {
                    add("delivery.mediaTypes must not repeat a media type.")
                }
            }
        }
    }

    override fun plannerTask(request: TaskRequest): RoutePlannerInputTask {
        // validate() requires both for this kind, and runs before projection.
        val speech = checkNotNull(request.speech) { "text_to_speech request without speech" }
        val delivery = checkNotNull(request.delivery) { "text_to_speech request without delivery" }
        return RoutePlannerInputTask(
            kind = kind.rawValue,
            inputs = listOf(TaskInputKind.Text),
            delivery = DeliveryRequirement(mode = delivery.mode, mediaTypes = delivery.mediaTypes?.toList()),
            locale = LocaleRequirement(tag = speech.locale, match = speech.localeMatch ?: LocaleMatch.Language),
            voice = speech.voice?.let { voice ->
                VoiceRequirement(
                    gender = voice.gender,
                    id = voice.id,
                    providerId = voice.providerId,
                    requirement = voice.requirement ?: RequirementLevel.Preferred,
                )
            },
            controls = controlRequirements(request),
        )
    }

    /**
     * The request's speech controls in the planner's fixed order, or null when it names none, so a
     * request without controls projects exactly as before (ADR 025).
     */
    private fun controlRequirements(request: TaskRequest): List<ControlRequirement>? = requestedControls(request).ifEmpty { null }

    override fun delivery(request: TaskRequest): OutputDelivery = checkNotNull(request.delivery) { "text_to_speech request without delivery" }.mode
}

private val taskProfiles: Map<TaskKind, TaskProfile> = listOf(TextToTextProfile, TextToSpeechProfile)
    .associateBy { it.kind }

/** The profile for [kind], or null when this engine cannot execute the task. */
fun taskProfileFor(kind: TaskKind): TaskProfile? = taskProfiles[kind]

/**
 * Re-checks, immediately before an attempt, that the voice the plan bound for this provider
 * still satisfies the request's privacy policy. The planner already chose the voice inside that
 * policy; repeating the check here keeps privacy enforceable at the last point before data
 * reaches the provider, independent of how the plan was produced. A violation fails the attempt
 * before commit, so the run may fall back.
 *
 * @return The exception to fail the attempt with, or null when the voice is allowed.
 */
fun recheckBoundVoice(request: TaskRequest, providerId: String, voice: ProviderVoice?): IndeRunException? {
    if (voice?.networkRequired != true || request.constraints?.privacy != Privacy.LocalRequired) {
        return null
    }
    return createCapabilityMismatch(
        message = "Provider '$providerId' was bound to a voice that sends data off the device, which privacy=local_required forbids.",
        providerId = providerId,
        details = mapOf("code" to "privacy_recheck_failed"),
    )
}

/**
 * The speech controls the request names, in the planner's fixed order (rate, pitch, volume), with
 * the requirement defaulted to `preferred`. Empty for a request that names none. Every control
 * check below compares against this list, so all of them read the request the way the planner does.
 */
fun requestedControls(request: TaskRequest): List<ControlRequirement> {
    val named = listOf(
        SpeechControlId.SpeechSpeakingRate to request.speech?.controls?.speakingRate?.let { it.value to it.requirement },
        SpeechControlId.SpeechPitch to request.speech?.controls?.pitch?.let { it.value to it.requirement },
        SpeechControlId.PlaybackVolume to request.delivery?.playback?.volume?.let { it.value to it.requirement },
    )
    return named.mapNotNull { (id, control) ->
        control?.let { (value, requirement) ->
            ControlRequirement(id = id, value = value, requirement = requirement ?: RequirementLevel.Preferred)
        }
    }
}

/**
 * Checks, after planning and before the first attempt, the control application plan of every
 * candidate the engine will attempt, fallbacks included, against the request (ADR 025 section 3).
 * The planner boundary carries no version, so a route core built without plans would return
 * candidates with none, and a required control would silently vanish: a missing plan is not an
 * empty request.
 *
 * It takes the route selection's chain ([RouteSelection.candidates]), not the plan's candidates: a
 * selected provider the plan lists no candidate for is still attempted, with no plan, and must be
 * checked like any other.
 *
 * @return `Internal` with `details.code: control_plan_mismatch` for the first candidate whose plan
 *   does not match, or null when every plan does. No attempt may follow a mismatch.
 */
fun checkControlPlans(request: TaskRequest, candidates: List<RouteCandidate>): IndeRunException? {
    val requested = requestedControls(request)
    val mismatched = candidates.firstOrNull { !controlPlanMatches(requested, it.controls) } ?: return null
    return createInternal(
        message = "The route plan for provider '${mismatched.provider.describe().id}' does not match the request's speech controls.",
        details = mapOf("code" to "control_plan_mismatch"),
    )
}

/**
 * Whether [plan] is consistent with [requested]: one entry per requested control, in request order,
 * with the request's id, value and requirement, and `apply` for every required one. An `omit` entry
 * carries its reason and an `apply` entry none. Absent and empty plans are the same, so they match
 * only a request without controls, and any entry on a request without controls is a mismatch.
 */
fun controlPlanMatches(requested: List<ControlRequirement>, plan: List<ControlApplicationPlan>?): Boolean {
    val entries = plan.orEmpty()
    if (entries.size != requested.size) return false
    return requested.zip(entries).all { (control, entry) ->
        entry.id == control.id &&
            entry.value == control.value &&
            entry.requirement == control.requirement &&
            // An omission carries its reason (the outcome record's reason); an application none.
            (entry.reason == null) == (entry.decision == ControlDecision.Apply) &&
            (control.requirement != RequirementLevel.Required || entry.decision == ControlDecision.Apply)
    }
}

/** How the run a provider's control records belong to ended. */
enum class ControlOutcomeEnding { Completed, Cancelled }

/**
 * The method an applied control must report: volume attenuates playback, rate and pitch are
 * synthesized (ADR 025 section 4).
 */
fun controlMethodFor(id: SpeechControlId): SpeechControlMethod = if (id == SpeechControlId.PlaybackVolume) SpeechControlMethod.PlaybackAttenuation else SpeechControlMethod.PlatformSynthesis

/**
 * Validates the control records a provider reported and completes them (ADR 025 section 4). The
 * result has one record per requested control, in request order: the provider's record where it
 * reported one, otherwise `not_applied` with `not_reported`. Application is never inferred from
 * the request.
 *
 * Refused, for any ending: a duplicate record, a record for a control the request did not name, a
 * `requested` value that is not the request's, an `applied` record whose method does not match the
 * control's phase (a missing method included), a `not_applied` record without a reason. Refused
 * only for a completed ending: a required control without an `applied` record. A cancelled ending
 * keeps what was reported, because a stop is an ending, not a failure. (An unknown status or reason
 * cannot occur: the contract enums are closed.)
 *
 * @throws IndeRunException `Internal` with `details.code: output_mismatch`.
 */
fun completeControlOutcomes(
    request: TaskRequest,
    reported: List<SpeechControlOutcome>?,
    ending: ControlOutcomeEnding,
    providerId: String,
): List<SpeechControlOutcome> {
    fun mismatch(problem: String) = createInternal(
        message = "Provider '$providerId' reported speech control records $problem.",
        providerId = providerId,
        details = mapOf("code" to "output_mismatch"),
    )
    val requested = requestedControls(request)
    val records = mutableMapOf<SpeechControlId, SpeechControlOutcome>()
    for (record in reported.orEmpty()) {
        val control = requested.firstOrNull { it.id == record.id }
            ?: throw mismatch("for '${record.id.rawValue}', which the request did not name")
        if (records.containsKey(record.id)) throw mismatch("with '${record.id.rawValue}' twice")
        if (record.requested != control.value) {
            throw mismatch("with '${record.id.rawValue}' requested at ${record.requested}, not ${control.value}")
        }
        when (record.status) {
            SpeechControlStatus.Applied ->
                if (record.method != controlMethodFor(control.id)) {
                    throw mismatch("with '${record.id.rawValue}' applied by '${record.method?.rawValue ?: "no method"}'")
                }
            SpeechControlStatus.NotApplied ->
                if (record.reason == null) {
                    throw mismatch("with '${record.id.rawValue}' not applied for no known reason")
                }
        }
        records[record.id] = record
    }
    if (ending == ControlOutcomeEnding.Completed) {
        val unmet = requested.firstOrNull {
            it.requirement == RequirementLevel.Required && records[it.id]?.status != SpeechControlStatus.Applied
        }
        if (unmet != null) throw mismatch("without required '${unmet.id.rawValue}' applied")
    }
    return requested.map { control ->
        records[control.id] ?: SpeechControlOutcome(
            id = control.id,
            reason = SpeechControlOutcomeReason.NotReported,
            requested = control.value,
            status = SpeechControlStatus.NotApplied,
        )
    }
}

/**
 * Completes the control records of a completed run's output (see [completeControlOutcomes]). A
 * request without controls leaves the output as it is, and refuses one that carries records.
 * Records live only in the output's `speech` section, so an output without one has none. For a
 * request whose controls are all preferred it passes unchanged, with no section and no records,
 * because the engine never invents the locale a section states; with a required control it is
 * refused, since nothing says it was applied.
 *
 * @throws IndeRunException `Internal` with `details.code: output_mismatch`.
 */
fun completeOutputControls(request: TaskRequest, output: TaskOutput, providerId: String): TaskOutput {
    val reported = output.speech?.controls
    val requested = requestedControls(request)
    if (requested.isEmpty()) {
        completeControlOutcomes(request, reported, ControlOutcomeEnding.Completed, providerId)
        return output
    }
    val speech = output.speech ?: run {
        if (requested.none { it.requirement == RequirementLevel.Required }) return output
        throw createInternal(
            message = "Provider '$providerId' reported no speech outcome for a request with a required speech control.",
            providerId = providerId,
            details = mapOf("code" to "output_mismatch"),
        )
    }
    val controls = completeControlOutcomes(request, reported, ControlOutcomeEnding.Completed, providerId)
    return output.copy(speech = speech.copy(controls = controls))
}

/**
 * The speech section of a cancelled terminal outcome, from what the attempt reported through
 * `reportSpeech` before the stop: the reported records are kept and every other requested control
 * becomes `not_applied` / `not_reported`. A report that breaks the record rules cannot fail a
 * cancelled run, so none of its records is trusted: every requested control is then `not_reported`.
 * Without a report there is no section, since nothing says which locale was spoken.
 */
fun cancelledSpeechOutcome(request: TaskRequest, reported: SpeechOutput?, providerId: String): SpeechOutput? {
    if (reported == null) return null
    val controls = runCatching {
        completeControlOutcomes(request, reported.controls, ControlOutcomeEnding.Cancelled, providerId)
    }.getOrElse {
        completeControlOutcomes(request, null, ControlOutcomeEnding.Cancelled, providerId)
    }
    return reported.copy(controls = controls.ifEmpty { null })
}

/**
 * Checks a provider's output against the delivery the request asked for: inline text for
 * [OutputDelivery.Inline], a playback completion for [OutputDelivery.Playback], a media artifact
 * for [OutputDelivery.Artifact] whose media type is one the request accepts. A provider never
 * substitutes one for another (ADR 016 §4), so a mismatch is a provider fault, not a result.
 *
 * @return The exception to fail the attempt with, or null when the output matches.
 */
fun checkOutput(request: TaskRequest, delivery: OutputDelivery, output: TaskOutput?, providerId: String): IndeRunException? {
    val matches = when (delivery) {
        OutputDelivery.Inline -> output?.type == TaskOutputType.TEXT && output.text != null
        OutputDelivery.Playback -> output?.type == TaskOutputType.PLAYBACK && output.playback != null
        OutputDelivery.Artifact ->
            output?.type == TaskOutputType.ARTIFACT &&
                output.artifact?.let { acceptsMediaType(request, it.mediaType) } == true
    }
    if (matches) return null
    val produced = if (output == null) "no output" else "a '${output.type.rawValue}' output"
    return createInternal(
        message = "Provider '$providerId' returned $produced for a '${delivery.rawValue}' request.",
        providerId = providerId,
        details = mapOf("code" to "output_mismatch"),
    )
}

/** Whether [mediaType] (parameters ignored, case-insensitive) is one the request accepts. */
private fun acceptsMediaType(request: TaskRequest, mediaType: String): Boolean {
    val accepted = request.delivery?.mediaTypes ?: return true
    fun base(type: String) = type.substringBefore(';').trim().lowercase()
    return accepted.any { base(it) == base(mediaType) }
}
