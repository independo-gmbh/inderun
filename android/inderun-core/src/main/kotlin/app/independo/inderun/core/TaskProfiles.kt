package app.independo.inderun.core

import app.independo.inderun.contracts.DeliveryRequirement
import app.independo.inderun.contracts.LocaleMatch
import app.independo.inderun.contracts.LocaleRequirement
import app.independo.inderun.contracts.OutputDelivery
import app.independo.inderun.contracts.Privacy
import app.independo.inderun.contracts.ProviderVoice
import app.independo.inderun.contracts.RequirementLevel
import app.independo.inderun.contracts.RoutePlannerInputTask
import app.independo.inderun.contracts.TaskInputKind
import app.independo.inderun.contracts.TaskKind
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
            if (speech.voice?.requirement == RequirementLevel.Required && speech.voice?.gender == null) {
                add("speech.voice with requirement 'required' must name a gender.")
            }
        }

        val delivery = request.delivery
        if (delivery == null) {
            add("delivery is required for task.kind 'text_to_speech'.")
        } else {
            if (delivery.mode != OutputDelivery.Playback && delivery.mode != OutputDelivery.Artifact) {
                add("delivery.mode must be 'playback' or 'artifact' for task.kind 'text_to_speech'.")
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
                VoiceRequirement(gender = voice.gender, requirement = voice.requirement ?: RequirementLevel.Preferred)
            },
        )
    }

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
