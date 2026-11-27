package app.independo.inderun.providers.systemspeech

import android.content.Context
import app.independo.inderun.contracts.CancelSemantics
import app.independo.inderun.contracts.ControlApplicationPlan
import app.independo.inderun.contracts.ControlDecision
import app.independo.inderun.contracts.ControlDelivery
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.LocaleMatch
import app.independo.inderun.contracts.OutputDelivery
import app.independo.inderun.contracts.PlaybackOutput
import app.independo.inderun.contracts.PlaybackTiming
import app.independo.inderun.contracts.Privacy
import app.independo.inderun.contracts.ProviderDescriptor
import app.independo.inderun.contracts.ProviderDynamicCapabilities
import app.independo.inderun.contracts.ProviderPrivacy
import app.independo.inderun.contracts.ProviderReadiness
import app.independo.inderun.contracts.ProviderSupports
import app.independo.inderun.contracts.ProviderTaskAvailability
import app.independo.inderun.contracts.ProviderTaskCapability
import app.independo.inderun.contracts.ProviderTaskInteraction
import app.independo.inderun.contracts.ProviderTaskOutput
import app.independo.inderun.contracts.ProviderTransport
import app.independo.inderun.contracts.ProviderType
import app.independo.inderun.contracts.ProviderVoice
import app.independo.inderun.contracts.RequirementLevel
import app.independo.inderun.contracts.SpeechControlDeclaration
import app.independo.inderun.contracts.SpeechControlId
import app.independo.inderun.contracts.SpeechControlLifetime
import app.independo.inderun.contracts.SpeechControlMethod
import app.independo.inderun.contracts.SpeechControlOutcome
import app.independo.inderun.contracts.SpeechControlOutcomeReason
import app.independo.inderun.contracts.SpeechControlPhase
import app.independo.inderun.contracts.SpeechControlRange
import app.independo.inderun.contracts.SpeechControlState
import app.independo.inderun.contracts.SpeechControlStatus
import app.independo.inderun.contracts.SpeechControlValueKind
import app.independo.inderun.contracts.SpeechInput
import app.independo.inderun.contracts.SpeechOutput
import app.independo.inderun.contracts.SpeechOutputVoice
import app.independo.inderun.contracts.TaskInputKind
import app.independo.inderun.contracts.TaskKind
import app.independo.inderun.contracts.TaskOutput
import app.independo.inderun.contracts.TaskOutputType
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TaskResultTelemetry
import app.independo.inderun.core.ArtifactSink
import app.independo.inderun.core.ArtifactSpec
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.PreparableProviderAdapter
import app.independo.inderun.core.PreparationProgress
import app.independo.inderun.core.ProviderPrepareContext
import app.independo.inderun.core.ProviderStreamContext
import app.independo.inderun.core.ProviderStreamEvent
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.StreamingProviderAdapter
import app.independo.inderun.core.createCapabilityMismatch
import app.independo.inderun.core.createInternal
import app.independo.inderun.core.createUnavailable
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.ConcurrentHashMap

/**
 * System text-to-speech through `android.speech.tts.TextToSpeech`: managed playback and
 * retrievable `audio/wav`, in both modes.
 *
 * Registered explicitly, never by `IndeRun.initialize`: the router probes every registered
 * provider on every request, and an application that does not speak should not bind a TTS
 * service (ADR 018).
 *
 * Playback commits immediately before the engine starts, so a failure after that ends the run
 * rather than speaking the text twice through another provider. `speak()` uses [stream], which the
 * engine cancels to stop the audio; [run] stops it on coroutine cancellation.
 *
 * The engine's voice selection and queue are shared, so one call runs at a time, playback and
 * synthesis alike. Waiters are served first in first out by a fair [Mutex], and playback commits
 * only at its turn, so a cancelled waiter never plays. Applications that want to interrupt cancel
 * first.
 *
 * Locality is reported per voice from `Voice.isNetworkConnectionRequired`. An engine that lists no
 * voices gives nothing to check, so a `local_required` request is refused before commit.
 *
 * Speech controls are applied inside the turn, before commit, so their refusals are
 * `CapabilityMismatch` errors that leave fallback open: `speech_control_unsupported` for a `required`
 * control the platform refuses or no longer applies, and `speech_settings_not_restored` when the
 * engine twice refuses to put back the user's default rate or pitch after an earlier utterance or a
 * refused setter changed it.
 */
class AndroidSystemSpeechProvider(
    private val id: String,
    private val engine: AndroidSpeechEngine,
) : StreamingProviderAdapter,
    PreparableProviderAdapter,
    AutoCloseable {
    /** Creates a provider backed by the device's default TTS engine. */
    constructor(context: Context, id: String = DEFAULT_ID) : this(id, PlatformAndroidSpeechEngine(context))

    private val turn = Mutex()
    private val downloading = ConcurrentHashMap.newKeySet<String>()

    /**
     * The engine settings an earlier utterance changed and nothing has restored yet. Read and
     * written only inside [turn]. A setter that was called counts as a change even when it failed
     * or the run ended before speaking, so the next utterance that does not set it restores the
     * user's default.
     */
    private val changedSettings = mutableSetOf<SpeechControlId>()

    override fun describe(): ProviderDescriptor = ProviderDescriptor(
        id = id,
        type = ProviderType.Local,
        transport = ProviderTransport.SystemService,
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
        tasks = listOf(TASK),
        taskCapabilities = listOf(
            ProviderTaskCapability(
                kind = TASK,
                inputs = listOf(TaskInputKind.Text),
                interaction = ProviderTaskInteraction(prepare = true, run = true, stream = true),
                cancel = CancelSemantics.Hard,
                outputs = listOf(
                    ProviderTaskOutput(delivery = OutputDelivery.Playback),
                    ProviderTaskOutput(delivery = OutputDelivery.Artifact, mediaTypes = listOf(MEDIA_TYPE)),
                ),
                controls = declaredControls(engine.attenuatesPlayback),
            ),
        ),
        // Per task, not per provider: each listed voice states its own `networkRequired`.
        privacy = ProviderPrivacy(dataLeavesDevice = false),
    )

    /**
     * Reports the voices usable right now. Network voices are left out while offline, because the
     * planner cannot know they would fail. An engine that lists nothing reports no `voices` at
     * all, which is "cannot enumerate", not "has none".
     */
    override suspend fun capabilities(host: HostServices): ProviderDynamicCapabilities {
        val readiness = engine.readiness()
        if (readiness is AndroidSpeechReadiness.Unavailable) {
            return ProviderDynamicCapabilities(available = false, reason = readiness.reason)
        }
        val voices = engine.voices()
        if (voices.isEmpty()) {
            return ProviderDynamicCapabilities(
                available = true,
                taskCapabilities = listOf(ProviderTaskAvailability(kind = TASK, controlStates = controlStates(engine.attenuatesPlayback))),
            )
        }
        val online = host.connectivity.isOnline()
        val listed = voices
            .filter { online || !it.networkRequired }
            .map { voice ->
                ProviderVoice(
                    id = voice.name,
                    name = voice.name,
                    locale = voice.locale,
                    networkRequired = voice.networkRequired,
                    readiness = when {
                        voice.installed -> null
                        voice.name in downloading -> ProviderReadiness.Preparing
                        else -> ProviderReadiness.NotPrepared
                    },
                )
            }
        return ProviderDynamicCapabilities(
            available = true,
            taskCapabilities = listOf(
                ProviderTaskAvailability(kind = TASK, voices = listed, controlStates = controlStates(engine.attenuatesPlayback)),
            ),
        )
    }

    /**
     * Makes the engine download the bound voice and waits until it reports the voice as installed.
     * The engine owns the data and exposes no progress, so the fraction stays unknown. Cancelling
     * stops the waiting, not the engine's download.
     */
    override fun prepare(context: ProviderPrepareContext): Flow<PreparationProgress> = flow {
        val id = context.voice?.id ?: return@flow
        val voice = engine.voices().firstOrNull { it.name == id } ?: throw notAvailable(id, context.runId)
        if (voice.installed) return@flow
        if (!context.hostServices.connectivity.isOnline()) {
            throw createUnavailable(
                "Voice '$id' needs a download, and the device is offline.",
                context.runId,
                this@AndroidSystemSpeechProvider.id,
                details = mapOf("code" to "not_ready"),
            )
        }
        downloading.add(id)
        try {
            if (!turn.withLock { engine.select(voice.locale, voice) }) throw notAvailable(id, context.runId)
            emit(PreparationProgress())
            val waited = withTimeoutOrNull(DOWNLOAD_TIMEOUT_MS) {
                while (engine.voices().firstOrNull { it.name == id }?.installed != true) delay(DOWNLOAD_POLL_MS)
            }
            if (waited == null) {
                throw createUnavailable(
                    "The TTS engine did not finish downloading voice '$id' in time.",
                    context.runId,
                    this@AndroidSystemSpeechProvider.id,
                    details = mapOf("code" to "not_ready"),
                )
            }
        } finally {
            downloading.remove(id)
        }
    }

    private fun notAvailable(voice: String, runId: String) = createCapabilityMismatch(
        "The TTS engine cannot download voice '$voice'.",
        runId,
        id,
        details = mapOf("code" to "voice_not_available"),
    )

    override suspend fun run(request: TaskRequest, context: RunContext): TaskResult {
        val output = execute(request, context.runId, context.voice, context.controls, context.artifacts, context::reportSpeech, context::commit)
            ?: throw CancellationException("The run was cancelled before it could commit.")
        return TaskResult(
            finishReason = FinishReason.STOP,
            output = output,
            runId = context.runId,
            schemaVersion = request.schemaVersion,
            telemetry = TaskResultTelemetry(providerUsed = id, totalMs = 0.0),
        )
    }

    /**
     * The stream carries no audio: it is only the run's lifecycle. It ends with a `Result` event, or
     * by falling through when it may not start, because the engine owns the `cancelled` outcome.
     */
    override fun stream(request: TaskRequest, context: ProviderStreamContext): Flow<ProviderStreamEvent> = flow {
        val output = execute(request, context.runId, context.voice, context.controls, context.artifacts, context::reportSpeech, context::commit)
        if (output != null) emit(ProviderStreamEvent.Result(output, FinishReason.STOP))
    }

    override fun close() = engine.close()

    /** @return the output, or null when the run could no longer commit, so nothing played. */
    private suspend fun execute(
        request: TaskRequest,
        runId: String,
        bound: ProviderVoice?,
        controls: List<ControlApplicationPlan>?,
        artifacts: ArtifactSink,
        reportSpeech: (SpeechOutput) -> Unit,
        commit: () -> Boolean,
    ): TaskOutput? {
        // The clock for `firstAudioMs` starts here, so waiting for the turn lock and voice
        // selection count toward the first word, not just the platform's own latency.
        val receivedAt = System.nanoTime()
        val speech = request.speech
        val delivery = request.delivery?.mode
        if (speech == null || delivery == null) {
            throw createCapabilityMismatch("Android system speech serves text-to-speech requests only.", runId, id)
        }
        try {
            return turn.withLock {
                val voice = selectVoice(speech, bound, request.constraints?.privacy, runId)
                // Every setter runs here, inside the turn and before commit, so a refused required
                // control still falls back and no setting leaks into the next queued utterance.
                val applied = applyControls(controls, delivery, runId)
                val used = SpeechOutput(
                    controls = applied.records,
                    locale = voice?.locale ?: speech.locale,
                    voice = voice?.let { SpeechOutputVoice(id = it.name, name = it.name) },
                )
                when (delivery) {
                    OutputDelivery.Playback -> {
                        // Committed only now: a call that waited its turn has made no sound, and
                        // may have been cancelled meanwhile.
                        if (!commit()) return@withLock null
                        // What the final output carries is known now, so a stop keeps the records.
                        // No suspension point lies between the commit and this report.
                        reportSpeech(used)
                        val handoffAt = System.nanoTime()
                        val spoken = engine.speakWithTimings(speech.text, applied.volume)
                        // The engine times from its own handoff; add what came before it. An
                        // engine that reports no first word leaves it absent, never overhead-only.
                        val firstAudioMs = spoken.firstAudioMs?.let { it + (handoffAt - receivedAt) / 1_000_000.0 }
                        TaskOutput(
                            type = TaskOutputType.PLAYBACK,
                            playback = PlaybackOutput(
                                timing = if (spoken.durationMs == null && firstAudioMs == null) {
                                    null
                                } else {
                                    PlaybackTiming(durationMs = spoken.durationMs, firstAudioMs = firstAudioMs)
                                },
                            ),
                            speech = used,
                        )
                    }
                    OutputDelivery.Artifact -> synthesize(speech.text, used, artifacts, runId)
                    OutputDelivery.Inline -> throw createCapabilityMismatch("Android system speech cannot deliver speech inline.", runId, id)
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: IndeRunException) {
            throw error
        } catch (error: Exception) {
            throw createInternal(
                "Android system speech failed.",
                runId,
                id,
                details = mapOf("originalError" to error.message),
            )
        }
    }

    /** What the plan's controls came to: the output records, and the volume a playback run passes on. */
    private class AppliedControls(val records: List<SpeechControlOutcome>?, val volume: Double?)

    /**
     * Sets rate and pitch on the engine and builds one record per plan entry, in plan order.
     * The engine's rate and pitch are shared and outlive the utterance, and they start at the
     * user's own system defaults: an utterance that does not apply one leaves it alone, unless an
     * earlier utterance changed it, which is then restored to the user's default first so it never
     * carries over. A request without controls on a fresh provider calls no setter at all.
     * A setter the platform refuses fails a `required` control before commit and records a
     * `preferred` one as `provider_rejected` with that setting restored. A restore the platform
     * refuses twice fails the attempt before commit with `speech_settings_not_restored`, because
     * the engine would otherwise speak with a value this utterance did not ask for.
     *
     * Volume has no setter: it is the speak parameter, and a render never gets one. It is checked
     * first, against one reading of [AndroidSpeechEngine.attenuatesPlayback], because the engine can
     * stop attenuating after planning: a `required` volume it no longer applies fails before any
     * setter runs, and a `preferred` one is recorded `unsupported`.
     */
    private suspend fun applyControls(plan: List<ControlApplicationPlan>?, delivery: OutputDelivery, runId: String): AppliedControls {
        val playback = delivery == OutputDelivery.Playback
        val volumeApplies = playback && engine.attenuatesPlayback
        val volumeEntry = plan?.firstOrNull { it.id == SpeechControlId.PlaybackVolume && it.decision == ControlDecision.Apply }
        if (volumeEntry?.requirement == RequirementLevel.Required && playback && !volumeApplies) {
            throw createCapabilityMismatch(
                "The TTS engine no longer applies the required control '${SpeechControlId.PlaybackVolume.rawValue}'.",
                runId,
                this.id,
                details = mapOf("code" to "speech_control_unsupported"),
            )
        }
        val rejected = mutableSetOf<SpeechControlId>()
        for (id in listOf(SpeechControlId.SpeechSpeakingRate, SpeechControlId.SpeechPitch)) {
            val entry = plan?.firstOrNull { it.id == id && it.decision == ControlDecision.Apply }
            if (entry == null) {
                if (id in changedSettings) restore(id, runId)
                continue
            }
            changedSettings += id
            if (!set(id, entry.value)) {
                if (entry.requirement == RequirementLevel.Required) {
                    throw createCapabilityMismatch(
                        "The TTS engine refused the required control '${id.rawValue}'.",
                        runId,
                        this.id,
                        details = mapOf("code" to "speech_control_unsupported"),
                    )
                }
                restore(id, runId)
                rejected += id
            }
        }
        if (plan == null) return AppliedControls(null, null)
        var volume: Double? = null
        val records = plan.map { entry ->
            fun notApplied(reason: SpeechControlOutcomeReason) = SpeechControlOutcome(
                id = entry.id,
                reason = reason,
                requested = entry.value,
                status = SpeechControlStatus.NotApplied,
            )
            when {
                entry.decision != ControlDecision.Apply ->
                    notApplied(entry.reason?.let { SpeechControlOutcomeReason.fromRawValue(it.rawValue) } ?: SpeechControlOutcomeReason.Unsupported)
                entry.id in rejected -> notApplied(SpeechControlOutcomeReason.ProviderRejected)
                entry.id == SpeechControlId.PlaybackVolume && !volumeApplies ->
                    notApplied(SpeechControlOutcomeReason.Unsupported)
                else -> {
                    if (entry.id == SpeechControlId.PlaybackVolume) volume = entry.value
                    SpeechControlOutcome(
                        effective = entry.value,
                        id = entry.id,
                        method = if (entry.id == SpeechControlId.PlaybackVolume) {
                            SpeechControlMethod.PlaybackAttenuation
                        } else {
                            SpeechControlMethod.PlatformSynthesis
                        },
                        requested = entry.value,
                        status = SpeechControlStatus.Applied,
                    )
                }
            }
        }
        return AppliedControls(records, volume)
    }

    private suspend fun set(control: SpeechControlId, value: Double): Boolean = if (control == SpeechControlId.SpeechSpeakingRate) {
        engine.setSpeechRate(value)
    } else {
        engine.setPitch(value)
    }

    /**
     * Puts the user's default back, retrying once. A restore refused twice fails the attempt before
     * commit and stays marked, so the next utterance tries again. The provider never substitutes a
     * value of its own for the user's default.
     */
    private suspend fun restore(control: SpeechControlId, runId: String) {
        repeat(RESTORE_ATTEMPTS) {
            val restored = if (control == SpeechControlId.SpeechSpeakingRate) engine.resetSpeechRate() else engine.resetPitch()
            if (restored) {
                changedSettings -= control
                return
            }
        }
        throw createCapabilityMismatch(
            "The TTS engine refused to restore the user's default for '${control.rawValue}'.",
            runId,
            id,
            details = mapOf("code" to "speech_settings_not_restored"),
        )
    }

    /**
     * Re-finds the voice the plan bound. A voice removed or changed since planning is refused
     * before commit, so the run can still fall back.
     */
    private suspend fun selectVoice(
        speech: SpeechInput,
        bound: ProviderVoice?,
        privacy: Privacy?,
        runId: String,
    ): AndroidSpeechVoice? {
        val voices = engine.voices()
        if (voices.isEmpty() && privacy == Privacy.LocalRequired) {
            throw createCapabilityMismatch(
                "The TTS engine does not list its voices, so local-required privacy cannot be verified.",
                runId,
                id,
                details = mapOf("code" to "voice_locality_unknown"),
            )
        }
        val voice = voices.firstOrNull { voice ->
            if (bound != null) {
                voice.name == bound.id
            } else {
                voice.installed && fits(voice.locale, speech) && (privacy != Privacy.LocalRequired || !voice.networkRequired)
            }
        }
        val boundStillFits = bound == null || (voice != null && stillFits(voice, bound, speech))
        if (!boundStillFits || (voices.isNotEmpty() && voice == null) || !engine.select(voice?.locale ?: speech.locale, voice)) {
            throw createCapabilityMismatch(
                "No installed voice can speak locale '${speech.locale}'.",
                runId,
                id,
                details = mapOf("code" to "voice_not_available"),
            )
        }
        return voice
    }

    /**
     * The engine's catalog can change after routing, so the plan's reading of a voice is checked
     * against the voice as it is now. Privacy and provenance both rest on `networkRequired`.
     */
    private fun stillFits(voice: AndroidSpeechVoice, bound: ProviderVoice, speech: SpeechInput): Boolean = voice.installed &&
        fits(voice.locale, speech) &&
        (!voice.networkRequired || bound.networkRequired == true)

    private suspend fun synthesize(text: String, used: SpeechOutput, artifacts: ArtifactSink, runId: String): TaskOutput {
        val bytes = engine.synthesize(text, MAX_RENDERED_BYTES)
        val durationMs = SpeechWav.durationMs(bytes) ?: throw createCapabilityMismatch(
            "The TTS engine did not produce WAV audio.",
            runId,
            id,
            details = mapOf("code" to "output_format_not_supported"),
        )
        val writer = artifacts.create(ArtifactSpec(mediaType = MEDIA_TYPE, durationMs = durationMs))
        try {
            writer.write(bytes)
            return TaskOutput(type = TaskOutputType.ARTIFACT, artifact = writer.finish(), speech = used)
        } catch (error: Throwable) {
            writer.abort()
            throw error
        }
    }

    private fun fits(available: String, speech: SpeechInput): Boolean = if (speech.localeMatch == LocaleMatch.Exact) {
        available.equals(speech.locale, ignoreCase = true)
    } else {
        language(available).equals(language(speech.locale), ignoreCase = true)
    }

    private fun language(tag: String) = tag.split('-', '_').first()

    companion object {
        /** Stable provider id used in routing explanations and telemetry. */
        const val DEFAULT_ID = "android_system_speech"

        private val TASK = TaskKind.TEXT_TO_SPEECH.rawValue

        /**
         * Rate and pitch shape the synthesis in both deliveries; volume attenuates playback only, and
         * only on an engine that applies it ([AndroidSpeechEngine.attenuatesPlayback]).
         */
        private fun declaredControls(attenuates: Boolean) = listOfNotNull(
            declaration(SpeechControlId.SpeechSpeakingRate, SpeechControlPhase.Synthesis, ControlDelivery.Playback, ControlDelivery.Artifact),
            declaration(SpeechControlId.SpeechPitch, SpeechControlPhase.Synthesis, ControlDelivery.Playback, ControlDelivery.Artifact),
            if (attenuates) declaration(SpeechControlId.PlaybackVolume, SpeechControlPhase.Playback, ControlDelivery.Playback) else null,
        )

        private fun declaration(id: SpeechControlId, phase: SpeechControlPhase, vararg deliveries: ControlDelivery) = SpeechControlDeclaration(
            deliveries = deliveries.toList(),
            id = id,
            lifetime = SpeechControlLifetime.Utterance,
            phase = phase,
            valueKind = SpeechControlValueKind.Number,
        )

        private val RATE_PITCH_RANGE = SpeechControlRange(default = 1.0, max = 2.0, min = 0.5, step = 0.05)
        private val VOLUME_RANGE = SpeechControlRange(default = 1.0, max = 1.0, min = 0.0, step = 0.05)

        /**
         * `TextToSpeech.setSpeechRate` and `setPitch` document 1.0 as normal with no upper bound, so
         * 0.5 to 2 is a conservative choice pending device evidence. Volume is `KEY_PARAM_VOLUME`,
         * 0 to 1, stated only when the engine applies it. The ranges hold for every installed voice,
         * so they are task-level states.
         */
        private fun controlStates(attenuates: Boolean) = if (attenuates) RATE_PITCH_STATES + VOLUME_STATE else RATE_PITCH_STATES

        private val RATE_PITCH_STATES = listOf(
            SpeechControlState(available = true, delivery = ControlDelivery.Playback, id = SpeechControlId.SpeechSpeakingRate, range = RATE_PITCH_RANGE),
            SpeechControlState(available = true, delivery = ControlDelivery.Artifact, id = SpeechControlId.SpeechSpeakingRate, range = RATE_PITCH_RANGE),
            SpeechControlState(available = true, delivery = ControlDelivery.Playback, id = SpeechControlId.SpeechPitch, range = RATE_PITCH_RANGE),
            SpeechControlState(available = true, delivery = ControlDelivery.Artifact, id = SpeechControlId.SpeechPitch, range = RATE_PITCH_RANGE),
        )
        private val VOLUME_STATE = SpeechControlState(available = true, delivery = ControlDelivery.Playback, id = SpeechControlId.PlaybackVolume, range = VOLUME_RANGE)
        private const val MEDIA_TYPE = "audio/wav"

        /** A refused restore is tried once more before the attempt is refused. */
        private const val RESTORE_ATTEMPTS = 2
        private const val DOWNLOAD_POLL_MS = 1_000L
        private const val DOWNLOAD_TIMEOUT_MS = 10L * 60 * 1_000

        /** The engine's default per-artifact limit; past it the writer would refuse the bytes. */
        private const val MAX_RENDERED_BYTES = 16L * 1024 * 1024

        internal fun tooLarge() = createUnavailable(
            "The rendered speech exceeds the artifact size limit.",
            details = mapOf("code" to "artifact_too_large"),
        )
    }
}
