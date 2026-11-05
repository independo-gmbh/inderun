package app.independo.inderun.providers.neuralspeech

import app.independo.inderun.contracts.CancelSemantics
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.contracts.OutputDelivery
import app.independo.inderun.contracts.PlaybackOutput
import app.independo.inderun.contracts.PlaybackTiming
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
import app.independo.inderun.contracts.SourceType
import app.independo.inderun.contracts.SpeechInput
import app.independo.inderun.contracts.SpeechModelVoice
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
import app.independo.inderun.core.AudioOutputFormat
import app.independo.inderun.core.AudioOutputSession
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
import app.independo.inderun.core.createTimeout
import app.independo.inderun.core.createUnavailable
import app.independo.inderun.core.getModelPackageValidationIssues
import app.independo.inderun.core.toIndeRunException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ChannelResult
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.CoroutineContext

/**
 * Text-to-speech with a developer-supplied neural speech model, synthesized in-process by a
 * [NeuralSpeechRuntime] and played through the host's `audioOutput` or returned as an `audio/wav`
 * artifact. Mirrors the Web and Apple members of the family.
 *
 * Playback (see [play]): the provider takes its turn (one utterance at a time per instance, served
 * first in first out by a fair [Mutex]; a call cancelled while waiting leaves the queue and plays
 * nothing), checks the host has an `audioOutput` (`audio_output_unavailable`) and that the bound
 * voice is one of the package's (`voice_not_available`), loads the model, splits the text into
 * sentences and opens one output session. It then synthesizes sentence by sentence and commits on
 * the first chunk, immediately before the first `write`; a cancel before that point ends quietly
 * with nothing written. After commit, a cancel stops the session (buffered audio is discarded) and
 * stops consuming the runtime, and any error ends the run without fallback. A normal end drains,
 * then stops. The session is stopped on every exit. Chunks must carry the package's sample rate:
 * it never resamples.
 *
 * Artifact (see [writeArtifact]): the same checks without the audio output. PCM is buffered in
 * memory; when the next chunk would make the WAV exceed [MAX_ARTIFACT_BYTES], synthesis stops and
 * the run fails uncommitted with `artifact_too_large`. Otherwise the WAV is written once and
 * `finish()` commits.
 *
 * Timing: `firstChunkMs`, `firstAudioMs` and `durationMs` count from the moment the request arrived
 * (`receivedAt`), before the turn wait. `firstAudioMs` = (instant before `open()` was called −
 * `receivedAt`) + `session.firstAudioMs()`, which every host measures from the start of its
 * `open()`, so a slow open is counted once; it is absent when the session reports none.
 *
 * Cancellation is `hard`: audio stops at once; residual compute is bounded to the in-flight
 * sentence and is never audible. It is coroutine cancellation: the engine cancels the coroutine
 * collecting [stream], and [run] honours its caller's. A cancel stops the session directly, through a
 * watcher coroutine that is a child of the playing one (the counterpart of Swift's
 * `withTaskCancellationHandler` and the Web's abort listener), also while a `write` is blocked in
 * native code cancellation cannot interrupt, waits on backpressure, or `drain` waits for buffered
 * audio to play; the `finally` stop is the second net. The stream then ends without a result,
 * because the engine owns the `cancelled` terminal.
 *
 * Timeout: the budget (a request's `constraints.timeoutMs`, else [timeoutMs]; zero or less is
 * unbounded) bounds the time until the run commits, counted from the start of synthesis. Playback:
 * it bounds the wait for the first chunk only; after commit nothing times out, and a runtime that
 * stalls is ended only by a cancel, as with the system speech providers. Artifact: it bounds the
 * whole synthesis, across sentences, up to `finish()`: one absolute deadline, checked again before
 * the artifact is created and immediately before `finish()`; past it, the writer is aborted. Expiry
 * throws `Timeout` at once, without waiting for the runtime, and always before commit, so the run
 * can fall back.
 *
 * @param modelPackage The speech model package: its `speech` block names the pipeline, graphs and
 *   voices.
 * @param runtime Executes the package. Required: no default runtime ships yet.
 * @param id Defaults to `<DEFAULT_ID>:<modelPackage.id>`, so an app registers one provider per model.
 * @param timeoutMs Bounds the synthesis until the run commits: the wait for the first chunk when
 *   playing, the whole synthesis up to `finish()` when writing an artifact. A request's
 *   `constraints.timeoutMs` wins; zero or less is unbounded.
 */
class NeuralSpeechProvider(
    private val modelPackage: ModelPackage,
    private val runtime: NeuralSpeechRuntime,
    id: String? = null,
    private val timeoutMs: Long? = null,
) : StreamingProviderAdapter,
    PreparableProviderAdapter {
    val id: String = id ?: "$DEFAULT_ID:${modelPackage.id}"

    private val turn = Mutex()
    private val loading = Mutex()

    @Volatile
    private var loaded = false

    @Volatile
    private var loadFailure: String? = null

    override fun describe(): ProviderDescriptor {
        val locales = modelPackage.speech?.voices.orEmpty().flatMap { it.locales }.distinct()
        return ProviderDescriptor(
            id = id,
            type = ProviderType.Local,
            model = modelPackage.id,
            transport = ProviderTransport.InProcess,
            supports = ProviderSupports(
                run = true,
                // Lifecycle only: the stream carries no audio, it is what `speak()` can cancel.
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
                    locales = locales.takeIf { it.isNotEmpty() },
                    privacy = ProviderPrivacy(dataLeavesDevice = false),
                ),
            ),
            privacy = ProviderPrivacy(dataLeavesDevice = false),
        )
    }

    /**
     * Never loads the model: a cold provider reports `readiness: cold` until it is loaded.
     *
     * Every failure below is provider-internal detail: the shared route planner flattens it into a
     * single `capability_unavailable` rejection carrying the returned reason.
     */
    override suspend fun capabilities(host: HostServices): ProviderDynamicCapabilities {
        val issues = getModelPackageValidationIssues(modelPackage)
        if (issues.isNotEmpty()) {
            val summary = issues.joinToString(separator = "; ") { "${it.path} ${it.message}" }
            return unavailable("model package malformed: $summary")
        }

        val tasks = modelPackage.tasks.orEmpty()
        val speech = modelPackage.speech
        if (TASK !in tasks || speech == null) {
            val declared = tasks.joinToString(", ").ifEmpty { "no tasks" }
            return unavailable("unsupported task: the model package declares $declared and no speech pipeline for '$TASK'.")
        }

        val channels = speech.channels
        if (channels != null && channels != 1L) return unavailable("unsupported channels: $channels")

        val sourceType = modelPackage.source?.sourceType
        if (sourceType != null && sourceType !in supportedModelSourceTypes) {
            val supported = supportedModelSourceTypes.joinToString(", ") { it.rawValue }
            return unavailable(
                "model source unavailable: '${sourceType.rawValue}' model sources are unsupported on Android; " +
                    "supply model files as $supported.",
            )
        }

        val platforms = modelPackage.runtime?.platforms
        if (!platforms.isNullOrEmpty() && PLATFORM !in platforms) {
            return unavailable(
                "platform unsupported: the model package targets ${platforms.joinToString(", ")} and does not list '$PLATFORM'.",
            )
        }

        val availability = try {
            runtime.availability(modelPackage)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            // A throwing runtime must not take routing down for every other provider.
            return unavailable("runtime availability failed: ${error.message ?: error.toString()}")
        }
        if (!availability.available) {
            return unavailable(availability.reason ?: "The neural speech runtime cannot run this package.")
        }
        loadFailure?.let { return unavailable(it) }

        // Until the provider has loaded the model, the runtime's hint (when it gives one) wins over cold.
        val hint = if (loaded) null else availability.readiness?.let { ProviderReadiness.fromRawValue(it.rawValue) }
        return ProviderDynamicCapabilities(
            available = true,
            taskCapabilities = listOf(
                ProviderTaskAvailability(
                    kind = TASK,
                    voices = speech.voices.map { listed(it).copy(readiness = hint) },
                    readiness = if (loaded) null else hint ?: ProviderReadiness.Cold,
                ),
            ),
        )
    }

    /** Loads the model ahead of the first run. Nothing is downloaded: the host supplies the files. */
    override fun prepare(context: ProviderPrepareContext): Flow<PreparationProgress> = flow {
        ensureLoaded(context.runId)
    }

    override suspend fun run(request: TaskRequest, context: RunContext): TaskResult {
        val attempt = Attempt(context.runId, context.hostServices, context.voice, context.artifacts, context::commit)
        val output = execute(request, attempt)
            ?: throw CancellationException("The run ended before playback could start.")
        return TaskResult(
            finishReason = FinishReason.STOP,
            output = output,
            runId = context.runId,
            schemaVersion = request.schemaVersion,
            telemetry = TaskResultTelemetry(providerUsed = id, totalMs = 0.0),
        )
    }

    /**
     * The stream carries no audio: it is only the run's lifecycle, for playback and artifact
     * delivery alike. It ends with a `Result` event, or without one when the run could no longer
     * commit or was cancelled, because the engine owns the `cancelled` outcome.
     */
    override fun stream(request: TaskRequest, context: ProviderStreamContext): Flow<ProviderStreamEvent> = flow {
        val attempt = Attempt(context.runId, context.hostServices, context.voice, context.artifacts, context::commit)
        val output = execute(request, attempt)
        if (output != null) emit(ProviderStreamEvent.Result(output, FinishReason.STOP))
    }

    /** @return the output, or null when the run could no longer commit, so nothing played. */
    private suspend fun execute(request: TaskRequest, attempt: Attempt): TaskOutput? {
        // The origin of every timing: before validation, the turn wait, voice check and commit.
        val receivedAt = System.nanoTime()
        val speech = request.speech
        val mode = request.delivery?.mode
        if (speech == null || (mode != OutputDelivery.Playback && mode != OutputDelivery.Artifact)) {
            throw createCapabilityMismatch("Neural speech can only play or write text-to-speech requests.", attempt.runId, id)
        }
        val synthesis = Synthesis(attempt.runId, budgetMs(request), budgetEndsAtFirstChunk = mode == OutputDelivery.Playback)
        try {
            return if (mode == OutputDelivery.Artifact) {
                writeArtifact(speech, attempt, synthesis)
            } else {
                turn.withLock { play(speech, attempt, receivedAt, synthesis) }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: IndeRunException) {
            throw toIndeRunException(error, fallbackRunId = attempt.runId, fallbackProviderId = id)
        } catch (error: Exception) {
            throw createInternal(
                "Neural speech failed.",
                attempt.runId,
                id,
                details = mapOf("originalError" to (error.localizedMessage ?: error.toString())),
            )
        }
    }

    /** A request's `constraints.timeoutMs`, else the option; zero or less is unbounded. */
    private fun budgetMs(request: TaskRequest): Long? = (request.constraints?.timeoutMs ?: timeoutMs)?.takeIf { it > 0 }

    /**
     * Playback, in this utterance's turn. Refuses before commit when the host has no audio output
     * or the bound voice is not the package's; stops the session on every exit once it is open,
     * without waiting for the runtime to wind down.
     *
     * For the session's lifetime a watcher, a child coroutine in a [coroutineScope] tied to the
     * caller's job, waits for cancellation and stops the session in its `finally`. A `write` can be
     * blocked where cancellation cannot reach it (the default host's `AudioTrack.write(...,
     * WRITE_BLOCKING)` under `Dispatchers.IO`), so a stop that waited for the `finally` here could
     * let a buffer keep playing, or never come if the output stalls; the caller's cancel reaches
     * the watcher at once, whatever its sibling is blocked in. The watcher runs on
     * [Dispatchers.Unconfined], so its stop runs on the cancelling thread instead of waiting for a
     * busy caller dispatcher; `stop()` does not suspend and is thread-safe. When the session ends here the watcher is cancelled without stopping again; the
     * `finally` stop is the second net.
     */
    private suspend fun play(
        speech: SpeechInput,
        attempt: Attempt,
        receivedAt: Long,
        synthesis: Synthesis,
    ): TaskOutput? {
        val audioOutput = attempt.hostServices.audioOutput ?: throw createCapabilityMismatch(
            "The host offers no audio output to play speech.",
            synthesis.runId,
            id,
            details = mapOf("code" to "audio_output_unavailable"),
        )
        val voice = resolveVoice(speech, attempt.voice, synthesis.runId)
        ensureLoaded(synthesis.runId)
        val chunks = SentenceChunks(currentCoroutineContext(), sentencesOf(speech.text, synthesis.runId), voice, synthesis)

        // The session measures firstAudioMs() from the start of its own open(), so the shift to the
        // request-received origin counts from the instant before the call, not from its return.
        val openStartedAt = System.nanoTime()
        val session = try {
            audioOutput.open(AudioOutputFormat(sampleRate = voice.sampleRate))
        } catch (error: Throwable) {
            chunks.close()
            // A failure that only reports the cancel is the cancel.
            currentCoroutineContext().ensureActive()
            throw error
        }
        return coroutineScope {
            val ended = AtomicBoolean(false)
            val stopOnCancel = launch(Dispatchers.Unconfined, start = CoroutineStart.UNDISPATCHED) {
                try {
                    awaitCancellation()
                } finally {
                    if (!ended.get()) session.stop()
                }
            }

            // `stop()` does not suspend, so it runs here even in a cancelled coroutine.
            try {
                val played = playChunks(chunks, session, attempt.commit, synthesis.runId) ?: return@coroutineScope null
                session.drain()
                currentCoroutineContext().ensureActive()
                // The session counts from the start of open(); shift it to the request-received origin.
                val firstAudioMs = session.firstAudioMs()?.let { millisBetween(receivedAt, openStartedAt) + it }
                TaskOutput(
                    type = TaskOutputType.PLAYBACK,
                    playback = PlaybackOutput(
                        timing = PlaybackTiming(
                            durationMs = played.frames * 1000.0 / voice.sampleRate,
                            firstAudioMs = firstAudioMs,
                            firstChunkMs = millisBetween(receivedAt, played.firstChunkAt),
                        ),
                    ),
                    speech = voice.output,
                )
            } catch (error: Throwable) {
                if (error !is CancellationException) currentCoroutineContext().ensureActive()
                throw error
            } finally {
                chunks.close()
                session.stop()
                ended.set(true)
                stopOnCancel.cancel()
            }
        }
    }

    /**
     * Writes every chunk to [session], committing immediately before the first write.
     *
     * @return when the first chunk arrived and how many frames were written, or null when the run
     *   could no longer commit; the caller stops the session either way.
     * @throws CancellationException when cancelled.
     */
    private suspend fun playChunks(
        chunks: SentenceChunks,
        session: AudioOutputSession,
        commit: () -> Boolean,
        runId: String,
    ): Played? {
        var firstChunkAt: Long? = null
        var frames = 0L
        while (true) {
            val chunk = chunks.next() ?: break
            if (firstChunkAt == null) {
                firstChunkAt = System.nanoTime()
                currentCoroutineContext().ensureActive()
                if (!commit()) return null
            }
            frames += chunk.samples.size
            session.write(chunk.samples)
            currentCoroutineContext().ensureActive()
        }
        return Played(firstChunkAt ?: throw noAudio(runId), frames)
    }

    /**
     * Artifact delivery: buffers the PCM up to [MAX_ARTIFACT_BYTES], then writes the WAV once (the
     * engine's writer only appends, and a WAV header needs the final size). Stopping at the cap
     * stops the runtime's synthesis. The chunks' one absolute deadline is checked again before the
     * artifact is created and immediately before `finish()`.
     */
    private suspend fun writeArtifact(speech: SpeechInput, attempt: Attempt, synthesis: Synthesis): TaskOutput {
        val voice = resolveVoice(speech, attempt.voice, synthesis.runId)
        ensureLoaded(synthesis.runId)
        val chunks = SentenceChunks(currentCoroutineContext(), sentencesOf(speech.text, synthesis.runId), voice, synthesis)

        val parts = mutableListOf<ShortArray>()
        var frames = 0L
        try {
            while (true) {
                val chunk = chunks.next() ?: break
                if (SpeechWavEncoder.HEADER_BYTES + 2 * (frames + chunk.samples.size) > MAX_ARTIFACT_BYTES) {
                    throw createUnavailable(
                        "The synthesized audio exceeds the artifact size limit.",
                        synthesis.runId,
                        id,
                        details = mapOf("code" to "artifact_too_large"),
                    )
                }
                // Already a copy: SentenceChunks copies every chunk before the runtime's emit returns.
                parts += chunk.samples
                frames += chunk.samples.size
            }
        } finally {
            chunks.close()
        }
        if (frames == 0L) throw noAudio(synthesis.runId)

        val samples = ShortArray(frames.toInt())
        var offset = 0
        for (part in parts) {
            part.copyInto(samples, offset)
            offset += part.size
        }
        parts.clear()
        if (chunks.pastDeadline()) throw timedOut(synthesis.runId)
        val writer = attempt.artifacts.create(ArtifactSpec(mediaType = MEDIA_TYPE, durationMs = frames * 1000.0 / voice.sampleRate))
        try {
            writer.write(SpeechWavEncoder.encode(samples, voice.sampleRate))
            if (chunks.pastDeadline()) throw timedOut(synthesis.runId)
            return TaskOutput(type = TaskOutputType.ARTIFACT, artifact = writer.finish(), speech = voice.output)
        } catch (error: Throwable) {
            writer.abort()
            throw error
        }
    }

    /**
     * Picks the package voice that speaks. A voice the plan bound must be one of the package's, else
     * the run is refused before commit so it can still fall back. Unbound, the request's voice id is
     * honoured when the package has it, then the first voice for the request's language, then the
     * first voice.
     */
    private fun resolveVoice(speech: SpeechInput, bound: ProviderVoice?, runId: String): ResolvedVoice {
        val speechPackage = modelPackage.speech
            ?: throw createCapabilityMismatch("The model package has no speech pipeline.", runId, id)
        val voices = speechPackage.voices
        val boundId = bound?.id
        val voice = if (boundId != null) {
            voices.firstOrNull { it.id == boundId } ?: throw createCapabilityMismatch(
                "The model package has no voice '$boundId'.",
                runId,
                id,
                details = mapOf("code" to "voice_not_available"),
            )
        } else {
            val requested = speech.voice?.id
            voices.firstOrNull { requested != null && it.id == requested }
                ?: voices.firstOrNull { candidate -> candidate.locales.any { sameLanguage(it, speech.locale) } }
                ?: voices.first()
        }
        return ResolvedVoice(voice, localeFor(voice, speech.locale), speechPackage.sampleRate.toInt())
    }

    private fun sentencesOf(text: String, runId: String): List<String> = SpeechTextFrontend.splitSentences(text).ifEmpty {
        throw createCapabilityMismatch("The text has nothing to say.", runId, id)
    }

    /**
     * Loads the model once; concurrent callers wait for the same load. A failed load is remembered,
     * so routing stops choosing this provider instead of every call retrying it; it refuses before
     * any output, so the run can fall back.
     */
    private suspend fun ensureLoaded(runId: String) {
        if (!loaded && loadFailure == null) {
            loading.withLock {
                if (loaded || loadFailure != null) return@withLock
                val result = try {
                    runtime.prepare(modelPackage)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    throw mapRuntimeError(error, runId)
                }
                if (result.available) loaded = true else loadFailure = result.reason ?: LOAD_FAILED
            }
        }
        if (!loaded) throw createCapabilityMismatch(loadFailure ?: LOAD_FAILED, runId, id)
    }

    private fun unavailable(reason: String) = ProviderDynamicCapabilities(available = false, reason = reason)

    private fun noAudio(runId: String) = createInternal("The neural speech runtime produced no audio.", runId, id)

    private fun timedOut(runId: String) = createTimeout("Neural speech synthesis timed out.", runId, id)

    private fun wrongSampleRate(chunk: PcmChunk, expected: Int, runId: String) = createInternal(
        "The runtime produced ${chunk.sampleRate} Hz audio for a $expected Hz package; the provider never resamples.",
        runId,
        id,
    )

    private fun mapRuntimeError(error: Throwable, runId: String): IndeRunException {
        if (error is NeuralSpeechRuntimeError) {
            val details = error.cause?.let { mapOf("originalError" to (it.localizedMessage ?: it.toString())) }
            val message = error.message ?: "The neural speech runtime failed."
            return when (error.kind) {
                NeuralSpeechRuntimeErrorKind.Capability -> createCapabilityMismatch(message, runId, id, details = details)
                NeuralSpeechRuntimeErrorKind.Unavailable -> createUnavailable(message, runId, id, details = details)
                NeuralSpeechRuntimeErrorKind.Timeout -> createTimeout(message, runId, id, details = details)
                NeuralSpeechRuntimeErrorKind.Internal -> createInternal(message, runId, id, details = details)
            }
        }
        if (error is IndeRunException) return toIndeRunException(error, fallbackRunId = runId, fallbackProviderId = id)
        return createInternal(
            "The neural speech runtime failed.",
            runId,
            id,
            details = mapOf("originalError" to (error.localizedMessage ?: error.toString())),
        )
    }

    /**
     * The chunks of every sentence in order, pulled by the coroutine that plays or buffers them; the
     * playback and artifact paths share it. Each sentence gets its own runtime collection, run in
     * [producers], which hands chunks over one at a time. The budget starts with the first pull and
     * races every pull until it ends: at the first chunk when `budgetEndsAtFirstChunk`, else with the
     * synthesis. A cancel of the pulling coroutine throws `CancellationException`; an expired budget
     * throws `Timeout`; a chunk at another sample rate throws `Internal`; a runtime failure is mapped
     * onto the IndeRun taxonomy. [close] cancels the runtime's collection, which ends its synthesis;
     * it keeps the deadline, which [pastDeadline] reads for the work that follows the synthesis.
     */
    private inner class SentenceChunks(
        context: CoroutineContext,
        private val sentences: List<String>,
        private val voice: ResolvedVoice,
        private val synthesis: Synthesis,
    ) {
        /**
         * Runs the runtime's collections and the budget's timer on the caller's dispatcher, outside
         * the caller's job, so nothing joins them: an expired budget or a cancel returns at once while
         * a producer is still suspended. A producer that blocks a single-threaded dispatcher would
         * block the timer too, which is why the seam requires runtimes to move inference off the
         * caller's dispatcher. [close] cancels the scope.
         */
        private val producers = CoroutineScope(context.minusKey(Job) + SupervisorJob())
        private var index = 0
        private var current: Sentence? = null
        private var started = false

        /** Completes when the budget runs out; null while there is none. */
        private var budget: CompletableDeferred<Unit>? = null
        private var budgetTimer: Job? = null

        /**
         * The budget's one absolute deadline, on `System.nanoTime()`; null while there is none. It is
         * on the wall clock while the budget timer is `delay`-based because the stretch from the last
         * chunk to `finish()` never suspends, so a timer flag could not flip during it.
         */
        private var deadline: Long? = null

        suspend fun next(): PcmChunk? {
            if (!started) {
                started = true
                startBudget()
            }
            while (true) {
                currentCoroutineContext().ensureActive()
                val sentence = current ?: run {
                    if (index >= sentences.size) return null
                    start(sentences[index++]).also { current = it }
                }
                val result = pull(sentence) ?: run {
                    close()
                    throw timedOut(synthesis.runId)
                }
                if (result.isClosed) {
                    current = null
                    result.exceptionOrNull()?.let { error ->
                        close()
                        currentCoroutineContext().ensureActive()
                        throw mapRuntimeError(error, synthesis.runId)
                    }
                    continue
                }
                val chunk = result.getOrThrow()
                if (chunk.sampleRate != voice.sampleRate) {
                    close()
                    throw wrongSampleRate(chunk, voice.sampleRate, synthesis.runId)
                }
                if (synthesis.budgetEndsAtFirstChunk) endBudget()
                return chunk
            }
        }

        /** Stops the current sentence's synthesis and the budget's timer, and ends the chunks. Idempotent. */
        fun close() {
            current?.cancel()
            current = null
            index = sentences.size
            stopBudgetTimer()
            producers.cancel()
        }

        /** Whether the budget's one absolute deadline has passed; false when there is none or it ended. */
        fun pastDeadline(): Boolean = deadline?.let { System.nanoTime() - it >= 0 } ?: false

        private fun startBudget() {
            val budgetMs = synthesis.timeoutMs ?: return
            deadline = System.nanoTime() + budgetMs * 1_000_000
            val expired = CompletableDeferred<Unit>()
            budget = expired
            budgetTimer = producers.launch {
                delay(budgetMs)
                expired.complete(Unit)
            }
        }

        /** Lifts the budget: nothing times out after it. */
        private fun endBudget() {
            stopBudgetTimer()
            deadline = null
        }

        private fun stopBudgetTimer() {
            budgetTimer?.cancel()
            budgetTimer = null
            budget = null
        }

        /**
         * Collects one sentence from the runtime, handing over a copy of each chunk, so the runtime
         * may reuse its buffer once `emit` returns; a failure closes the channel with it.
         */
        private fun start(text: String): Sentence {
            val chunks = Channel<PcmChunk>(Channel.RENDEZVOUS)
            val input = NeuralSpeechSynthesisInput(modelPackage, text, voice.locale, voice.voice.id)
            val job = producers.launch {
                try {
                    // Copied before `emit` returns: a rendezvous `send` to a waiting puller returns
                    // before the puller runs, and the runtime may refill its buffer once it does.
                    runtime.synthesize(input).collect { chunks.send(it.copy(samples = it.samples.copyOf())) }
                    chunks.close()
                } catch (error: Throwable) {
                    // Reported to the puller rather than failing the scope; a cancel of this
                    // collection is not a runtime failure.
                    if (error is CancellationException && !isActive) throw error
                    chunks.close(error)
                }
            }
            return Sentence(chunks, job)
        }

        /** The sentence's next chunk or end, or null when the budget runs out first. */
        private suspend fun pull(sentence: Sentence): ChannelResult<PcmChunk>? {
            val expired = budget ?: return sentence.chunks.receiveCatching()
            return select {
                sentence.chunks.onReceiveCatching { it }
                expired.onAwait { null }
            }
        }
    }

    private class Sentence(val chunks: Channel<PcmChunk>, val job: Job) {
        fun cancel() {
            job.cancel()
            chunks.cancel()
        }
    }

    companion object {
        /** Default provider id of the Android neural speech provider; an instance composes `<DEFAULT_ID>:<package id>`. */
        const val DEFAULT_ID = "local.onnx.speech.android"

        /**
         * Model source types this provider can honor on Android. Hosts download `remote` files
         * themselves and hand them over as one of these; `registry` is not supported.
         */
        val supportedModelSourceTypes: List<SourceType> = listOf(
            SourceType.Bundled,
            SourceType.Programmatic,
            SourceType.AppManaged,
            SourceType.Filesystem,
        )

        /**
         * Largest WAV artifact this provider writes. Duplicates the engine's default per-artifact
         * limit on purpose, as the system speech providers do, so synthesis stops at the cap instead
         * of producing audio the store would refuse.
         */
        const val MAX_ARTIFACT_BYTES = 16L * 1024 * 1024

        private val TASK = TaskKind.TEXT_TO_SPEECH.rawValue
        private const val MEDIA_TYPE = "audio/wav"
        private const val PLATFORM = "android"
        private const val LOAD_FAILED = "The speech model failed to load."
    }
}

/** What one attempt was handed, from a [RunContext] or a [ProviderStreamContext]. */
private class Attempt(
    val runId: String,
    val hostServices: HostServices,
    /** The voice the plan bound, if any. */
    val voice: ProviderVoice?,
    val artifacts: ArtifactSink,
    val commit: () -> Boolean,
)

/** What every sentence of one run shares. */
private class Synthesis(
    val runId: String,
    /** The budget, from the start of synthesis. Null is unbounded. */
    val timeoutMs: Long?,
    /** True for playback, which commits on the first chunk; false for an artifact. */
    val budgetEndsAtFirstChunk: Boolean,
)

/** The package voice that speaks, the tag it speaks for the request, and the package's rate. */
private class ResolvedVoice(val voice: SpeechModelVoice, val locale: String, val sampleRate: Int) {
    /** The locale and voice actually used, as the run's output reports them. */
    val output: SpeechOutput get() = SpeechOutput(locale = locale, voice = SpeechOutputVoice(id = voice.id, name = voice.name))
}

/** When the first chunk arrived (`System.nanoTime()`) and how many frames were written. */
private class Played(val firstChunkAt: Long, val frames: Long)

private fun listed(voice: SpeechModelVoice) = ProviderVoice(
    id = voice.id,
    name = voice.name,
    locale = voice.locales.first(),
    locales = voice.locales,
    gender = voice.gender,
    networkRequired = false,
)

private fun millisBetween(from: Long, to: Long): Double = (to - from) / 1_000_000.0

private fun language(tag: String) = tag.lowercase().split('-', '_').first()

private fun sameLanguage(a: String, b: String) = language(a) == language(b)

/** The voice's tag for the requested locale: exact first, then by language, else the request's. */
private fun localeFor(voice: SpeechModelVoice, requested: String): String = voice.locales.firstOrNull { it.equals(requested, ignoreCase = true) }
    ?: voice.locales.firstOrNull { sameLanguage(it, requested) }
    ?: requested
