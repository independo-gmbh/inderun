package app.independo.inderun.providers.systemspeech

import app.independo.inderun.contracts.CancelSemantics
import app.independo.inderun.contracts.ControlApplicationPlan
import app.independo.inderun.contracts.ControlDecision
import app.independo.inderun.contracts.ControlDelivery
import app.independo.inderun.contracts.ControlOmissionReason
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.OutputDelivery
import app.independo.inderun.contracts.OutputDeliveryRequest
import app.independo.inderun.contracts.Privacy
import app.independo.inderun.contracts.ProviderReadiness
import app.independo.inderun.contracts.ProviderVoice
import app.independo.inderun.contracts.RequirementLevel
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.SpeechControlId
import app.independo.inderun.contracts.SpeechControlMethod
import app.independo.inderun.contracts.SpeechControlOutcomeReason
import app.independo.inderun.contracts.SpeechControlStatus
import app.independo.inderun.contracts.SpeechInput
import app.independo.inderun.contracts.TaskKind
import app.independo.inderun.contracts.TaskOutputType
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestConstraints
import app.independo.inderun.contracts.TaskRequestTask
import app.independo.inderun.core.ClockService
import app.independo.inderun.core.ConnectivityService
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderPrepareContext
import app.independo.inderun.core.ProviderStreamContext
import app.independo.inderun.core.ProviderStreamEvent
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.SecureStorageService
import app.independo.inderun.core.StreamCancellationToken
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** A scripted engine: playback finishes at once, or holds until released or cancelled. */
private class FakeSpeechEngine(
    var voiceList: List<AndroidSpeechVoice> = GERMAN,
    var readiness: AndroidSpeechReadiness = AndroidSpeechReadiness.Ready,
    var audio: ByteArray = wavBytes(),
) : AndroidSpeechEngine {
    val spoken = mutableListOf<String>()
    val selected = mutableListOf<Pair<String, AndroidSpeechVoice?>>()
    var onSelect: () -> Unit = {}
    val stopped = mutableListOf<String>()
    val held = mutableMapOf<String, CompletableDeferred<Unit>>()
    var speakFailure: Throwable? = null
    var selectable = true
    var synthesized = 0
    var closed = false

    /** Every `setSpeechRate` / `setPitch` / reset call in order, with the value it set. */
    val setterCalls = mutableListOf<Pair<String, Double>>()

    /** The user's own system defaults, which a fresh engine speaks with. Not 1.0, so a reset is visible. */
    val userRate = 1.25
    val userPitch = 0.95
    var rate = userRate
    var pitch = userPitch
    var rateFails = false
    var pitchFails = false

    /** What each `speak` found set: text to (rate, pitch, volume). */
    val seenAtSpeak = mutableMapOf<String, Triple<Double, Double, Double?>>()
    val renderedWith = mutableListOf<Pair<Double, Double>>()

    override suspend fun setSpeechRate(rate: Double): Boolean {
        setterCalls += "rate" to rate
        if (rateFails && rate != 1.0) return false
        this.rate = rate
        return true
    }

    override suspend fun setPitch(pitch: Double): Boolean {
        setterCalls += "pitch" to pitch
        if (pitchFails && pitch != 1.0) return false
        this.pitch = pitch
        return true
    }

    /** How many of the next reset calls the platform refuses, leaving the value as it was. */
    var rateResetFailures = 0
    var pitchResetFailures = 0

    override suspend fun resetSpeechRate(): Boolean {
        setterCalls += "resetRate" to userRate
        if (rateResetFailures > 0) {
            rateResetFailures -= 1
            return false
        }
        rate = userRate
        return true
    }

    override suspend fun resetPitch(): Boolean {
        setterCalls += "resetPitch" to userPitch
        if (pitchResetFailures > 0) {
            pitchResetFailures -= 1
            return false
        }
        pitch = userPitch
        return true
    }

    override suspend fun readiness() = readiness

    override suspend fun voices() = voiceList

    override suspend fun select(locale: String, voice: AndroidSpeechVoice?): Boolean {
        selected += locale to voice
        onSelect()
        return selectable
    }

    override suspend fun speak(text: String): Double? {
        spoken += text
        speakFailure?.let { throw it }
        try {
            held[text]?.await()
        } catch (cancelled: CancellationException) {
            stopped += text
            throw cancelled
        }
        return 900.0
    }

    /** Reports a first word, as an engine with range callbacks does. */
    var firstAudioMs: Double? = 120.0

    /** Whether this engine applies the volume it is passed, as the platform engine does. */
    var attenuates = true
    var attenuatesReads = 0
    override val attenuatesPlayback: Boolean
        get() {
            attenuatesReads += 1
            return attenuates
        }

    override suspend fun speakWithTimings(text: String, volume: Double?): AndroidSpokenAudio {
        seenAtSpeak[text] = Triple(rate, pitch, volume)
        return AndroidSpokenAudio(speak(text), firstAudioMs)
    }

    override suspend fun synthesize(text: String, maxBytes: Long): ByteArray {
        synthesized += 1
        renderedWith += rate to pitch
        return audio
    }

    override fun close() {
        closed = true
    }

    companion object {
        val LOCAL = AndroidSpeechVoice("de-local", "de-DE", networkRequired = false)
        val NETWORK = AndroidSpeechVoice("de-network", "de-DE", networkRequired = true)
        val LOCAL_LISTED = ProviderVoice(id = "de-local", name = "de-local", locale = "de-DE", networkRequired = false)
        val NETWORK_LISTED = ProviderVoice(id = "de-network", name = "de-network", locale = "de-DE", networkRequired = true)
        val GERMAN = listOf(NETWORK, LOCAL)
    }
}

class AndroidSystemSpeechProviderTest {
    private fun request(
        locale: String = "de-AT",
        delivery: OutputDelivery = OutputDelivery.Playback,
        privacy: Privacy? = null,
        text: String = "Hallo",
    ) = TaskRequest(
        schemaVersion = SchemaVersion.V1_1,
        task = TaskRequestTask(kind = TaskKind.TEXT_TO_SPEECH),
        speech = SpeechInput(locale = locale, text = text),
        delivery = OutputDeliveryRequest(mode = delivery),
        constraints = privacy?.let { TaskRequestConstraints(privacy = it) },
    )

    private fun host(online: Boolean = true) = HostServices(
        connectivity = object : ConnectivityService {
            override fun isOnline() = online
        },
        secureStorage = object : SecureStorageService {
            override fun get(authContextRef: String): String? = null

            override fun put(authContextRef: String, value: String) = Unit

            override fun remove(authContextRef: String) = Unit
        },
        clock = object : ClockService {
            override fun elapsedRealtimeMillis() = 1_000L
        },
    )

    private fun provider(engine: FakeSpeechEngine) = AndroidSystemSpeechProvider(AndroidSystemSpeechProvider.DEFAULT_ID, engine)

    private fun runContext(voice: ProviderVoice? = null, commits: Boolean = true, controls: List<ControlApplicationPlan>? = null) = RunContext(
        "run_1",
        host(),
        voice = voice,
        controls = controls,
        commitHandler = { commits },
    )

    private fun streamContext(
        voice: ProviderVoice? = null,
        controls: List<ControlApplicationPlan>? = null,
        reportSpeech: (app.independo.inderun.contracts.SpeechOutput) -> Unit = {},
        commit: () -> Boolean = { true },
    ) = ProviderStreamContext(
        runId = "run_1",
        hostServices = host(),
        cancellation = StreamCancellationToken(),
        voice = voice,
        controls = controls,
        reportSpeechHandler = reportSpeech,
        commitHandler = commit,
    )

    private fun apply(id: SpeechControlId, value: Double, requirement: RequirementLevel = RequirementLevel.Preferred) = ControlApplicationPlan(ControlDecision.Apply, id, null, requirement, value)

    private fun omit(id: SpeechControlId, value: Double, reason: ControlOmissionReason) = ControlApplicationPlan(ControlDecision.Omit, id, reason, RequirementLevel.Preferred, value)

    // --- capabilities ------------------------------------------------------------------------

    @Test
    fun declaresPlaybackAndArtifactAndHardCancel() {
        val descriptor = provider(FakeSpeechEngine()).describe()
        val task = descriptor.taskCapabilities!!.single()

        assertEquals("android_system_speech", descriptor.id)
        assertTrue(descriptor.supports.streaming)
        assertEquals(false, descriptor.privacy?.dataLeavesDevice)
        assertEquals(CancelSemantics.Hard, task.cancel)
        assertTrue(task.interaction.stream)
        assertEquals(listOf(OutputDelivery.Playback, OutputDelivery.Artifact), task.outputs.map { it.delivery })
        assertEquals(listOf("audio/wav"), task.outputs.last().mediaTypes)
    }

    @Test
    fun reportsEachVoicesOwnLocality() = runTest {
        val voices = provider(FakeSpeechEngine()).capabilities(host()).taskCapabilities!!.single().voices!!

        assertEquals(
            listOf(FakeSpeechEngine.NETWORK_LISTED, FakeSpeechEngine.LOCAL_LISTED),
            voices,
        )
    }

    @Test
    fun leavesNetworkVoicesOutWhileOffline() = runTest {
        val voices = provider(FakeSpeechEngine()).capabilities(host(online = false)).taskCapabilities!!.single().voices!!

        assertEquals(listOf(FakeSpeechEngine.LOCAL_LISTED), voices)
    }

    @Test
    fun anEngineThatFailedToStartIsUnavailable() = runTest {
        val capabilities = provider(FakeSpeechEngine(readiness = AndroidSpeechReadiness.Unavailable("no engine"))).capabilities(host())

        assertFalse(capabilities.available)
        assertEquals("no engine", capabilities.reason)
    }

    @Test
    fun anEngineThatListsNothingCannotEnumerateRatherThanHasNone() = runTest {
        val capabilities = provider(FakeSpeechEngine(voiceList = emptyList())).capabilities(host())

        assertTrue(capabilities.available)
        assertNull(capabilities.taskCapabilities!!.single().voices)
    }

    // --- playback ----------------------------------------------------------------------------

    @Test
    fun playsTheBoundVoiceAndReportsIt() = runTest {
        val engine = FakeSpeechEngine()

        val result = provider(engine).run(request(), runContext(FakeSpeechEngine.LOCAL_LISTED))

        assertEquals(listOf("de-DE" to FakeSpeechEngine.LOCAL), engine.selected)
        assertEquals(listOf("Hallo"), engine.spoken)
        assertEquals(TaskOutputType.PLAYBACK, result.output.type)
        assertEquals(900.0, result.output.playback?.timing?.durationMs)
        // The seam's 120 ms plus the provider's own request-entry overhead.
        assertTrue(result.output.playback?.timing?.firstAudioMs!! >= 120.0)
        assertEquals("de-DE", result.output.speech?.locale)
        assertEquals("de-local", result.output.speech?.voice?.id)
    }

    @Test
    fun firstAudioCountsFromTheRequestNotTheHandoff() = runTest {
        val engine = FakeSpeechEngine()
        // Wall clock, not virtual time: the provider measures with System.nanoTime().
        engine.onSelect = { Thread.sleep(60) }

        val result = provider(engine).run(request(), runContext(FakeSpeechEngine.LOCAL_LISTED))

        assertTrue(result.output.playback?.timing?.firstAudioMs!! >= 180.0)
    }

    @Test
    fun firstAudioAbsentWhenTheEngineReportsNone() = runTest {
        val engine = FakeSpeechEngine()
        engine.firstAudioMs = null
        engine.onSelect = { Thread.sleep(60) }

        val result = provider(engine).run(request(), runContext(FakeSpeechEngine.LOCAL_LISTED))

        assertNull(result.output.playback?.timing?.firstAudioMs)
        assertEquals(900.0, result.output.playback?.timing?.durationMs)
    }

    @Test
    fun refusesABoundVoiceThatBecameANetworkVoiceBeforeCommit() = runTest {
        val changed = FakeSpeechEngine.LOCAL.copy(networkRequired = true)
        val engine = FakeSpeechEngine(voiceList = listOf(changed))

        try {
            provider(engine).run(request(privacy = Privacy.LocalRequired), runContext(FakeSpeechEngine.LOCAL_LISTED))
            fail("Expected the changed voice to be refused.")
        } catch (error: IndeRunException) {
            assertEquals(IndeRunErrorClass.CapabilityMismatch, error.errorClass)
        }
        assertEquals(emptyList<String>(), engine.spoken)
        assertEquals(emptyList<Pair<String, AndroidSpeechVoice?>>(), engine.selected)
    }

    @Test
    fun refusesABoundVoiceThatIsNoLongerInstalledBeforeCommit() = runTest {
        val engine = FakeSpeechEngine(voiceList = listOf(FakeSpeechEngine.LOCAL.copy(installed = false)))

        try {
            provider(engine).run(request(), runContext(FakeSpeechEngine.LOCAL_LISTED))
            fail("Expected the voice to be refused.")
        } catch (error: IndeRunException) {
            assertEquals(IndeRunErrorClass.CapabilityMismatch, error.errorClass)
        }
    }

    @Test
    fun refusesABoundVoiceOfAnotherLanguageBeforeCommit() = runTest {
        val engine = FakeSpeechEngine(voiceList = listOf(FakeSpeechEngine.LOCAL.copy(locale = "en-US")))

        try {
            provider(engine).run(request(), runContext(FakeSpeechEngine.LOCAL_LISTED))
            fail("Expected the voice to be refused.")
        } catch (error: IndeRunException) {
            assertEquals(IndeRunErrorClass.CapabilityMismatch, error.errorClass)
        }
    }

    @Test
    fun listsAVoiceStillToDownloadInsteadOfHidingIt() = runTest {
        val missing = AndroidSpeechVoice("de-new", "de-DE", networkRequired = false, installed = false)
        val engine = FakeSpeechEngine(voiceList = listOf(missing))

        val voices = provider(engine).capabilities(host()).taskCapabilities!!.single().voices!!

        assertEquals(ProviderReadiness.NotPrepared, voices.single().readiness)
    }

    @Test
    fun prepareSelectsAVoiceSoTheEngineDownloadsItThenWaitsForIt() = runTest {
        val missing = AndroidSpeechVoice("de-new", "de-DE", networkRequired = false, installed = false)
        val engine = FakeSpeechEngine(voiceList = listOf(missing))
        engine.onSelect = { engine.voiceList = listOf(missing.copy(installed = true)) }

        provider(engine)
            .prepare(ProviderPrepareContext("run_1", host(), "text_to_speech", voice = ProviderVoice(id = "de-new", locale = "de-DE")))
            .toList()

        assertEquals(listOf("de-DE" to missing), engine.selected)
    }

    @Test
    fun anUnboundRunNeverPicksAVoiceStillToDownload() = runTest {
        val missing = AndroidSpeechVoice("de-new", "de-DE", networkRequired = false, installed = false)
        val engine = FakeSpeechEngine(voiceList = listOf(missing, FakeSpeechEngine.LOCAL))

        provider(engine).run(request(), runContext())

        assertEquals(listOf("de-DE" to FakeSpeechEngine.LOCAL), engine.selected)
    }

    @Test
    fun selectsTheBoundVoiceOutOfVoicesWithIdenticalTraits() = runTest {
        val twin = AndroidSpeechVoice("de-local-2", "de-DE", networkRequired = false)
        val engine = FakeSpeechEngine(voiceList = listOf(FakeSpeechEngine.LOCAL, twin))

        provider(engine).run(request(), runContext(ProviderVoice(id = "de-local-2", locale = "de-DE")))

        assertEquals(listOf("de-DE" to twin), engine.selected)
    }

    @Test
    fun neverStartsAudioWhenTheRunCannotCommit() = runTest {
        val engine = FakeSpeechEngine()

        val events = provider(engine).stream(request(), streamContext(commit = { false })).toList()

        assertTrue(events.isEmpty())
        assertTrue(engine.spoken.isEmpty())
    }

    @Test
    fun runRefusesToStartWhenItCannotCommit() = runTest {
        val engine = FakeSpeechEngine()

        try {
            provider(engine).run(request(), runContext(commits = false))
            fail("expected a cancellation")
        } catch (_: CancellationException) {
            assertTrue(engine.spoken.isEmpty())
        }
    }

    @Test
    fun cancellingTheCollectorStopsTheAudio() = runTest {
        val engine = FakeSpeechEngine().apply { held["Hallo"] = CompletableDeferred() }

        val job = launch { provider(engine).stream(request(), streamContext()).toList() }
        runCurrent()
        job.cancel()
        job.join()

        assertEquals(listOf("Hallo"), engine.stopped)
    }

    @Test
    fun streamEndsWithAResultAndNoContent() = runTest {
        val events = provider(FakeSpeechEngine()).stream(request(), streamContext()).toList()

        assertEquals(TaskOutputType.PLAYBACK, (events.single() as ProviderStreamEvent.Result).output.type)
    }

    @Test
    fun aVoiceRemovedSincePlanningIsRefusedBeforeCommit() = runTest {
        val engine = FakeSpeechEngine(voiceList = listOf(FakeSpeechEngine.NETWORK))
        var committed = false

        try {
            provider(engine).stream(
                request(),
                streamContext(FakeSpeechEngine.LOCAL_LISTED) {
                    committed = true
                    true
                },
            ).toList()
            fail("expected a refusal")
        } catch (error: IndeRunException) {
            assertEquals(IndeRunErrorClass.CapabilityMismatch, error.errorClass)
            assertEquals("voice_not_available", error.details?.get("code"))
        }
        assertFalse(committed)
    }

    @Test
    fun aLocaleTheEngineRefusesFailsBeforeCommit() = runTest {
        val engine = FakeSpeechEngine().apply { selectable = false }

        try {
            provider(engine).run(request(), runContext(FakeSpeechEngine.LOCAL_LISTED))
            fail("expected a refusal")
        } catch (error: IndeRunException) {
            assertEquals(IndeRunErrorClass.CapabilityMismatch, error.errorClass)
        }
        assertTrue(engine.spoken.isEmpty())
    }

    @Test
    fun localRequiredIsRefusedWhenTheEngineListsNoVoices() = runTest {
        val engine = FakeSpeechEngine(voiceList = emptyList())

        try {
            provider(engine).run(request(privacy = Privacy.LocalRequired), runContext())
            fail("expected a refusal")
        } catch (error: IndeRunException) {
            assertEquals("voice_locality_unknown", error.details?.get("code"))
        }
        assertTrue(engine.spoken.isEmpty())
    }

    @Test
    fun withoutAListTheEngineChoosesForTheLocale() = runTest {
        val engine = FakeSpeechEngine(voiceList = emptyList())

        provider(engine).run(request(locale = "de-AT"), runContext())

        assertEquals(listOf("de-AT" to null), engine.selected)
        assertEquals(listOf("Hallo"), engine.spoken)
    }

    @Test
    fun withoutABoundVoiceLocalRequiredPicksAnOnDeviceVoice() = runTest {
        val engine = FakeSpeechEngine()

        provider(engine).run(request(privacy = Privacy.LocalRequired), runContext())

        assertEquals(FakeSpeechEngine.LOCAL, engine.selected.single().second)
    }

    // --- one call at a time ------------------------------------------------------------------

    @Test
    fun utterancesPlayInOrderAndCommitOnlyAtTheirTurn() = runTest {
        val gate = CompletableDeferred<Unit>()
        val engine = FakeSpeechEngine().apply { held["eins"] = gate }
        val speech = provider(engine)
        val commits = mutableListOf<String>()
        fun context(text: String) = streamContext {
            commits += text
            true
        }

        val first = launch { speech.stream(request(text = "eins"), context("eins")).toList() }
        runCurrent()
        val second = launch { speech.stream(request(text = "zwei"), context("zwei")).toList() }
        runCurrent()
        assertEquals(listOf("eins"), commits)

        gate.complete(Unit)
        first.join()
        second.join()

        assertEquals(listOf("eins", "zwei"), commits)
        assertEquals(listOf("eins", "zwei"), engine.spoken)
    }

    @Test
    fun cancellingAWaitingUtteranceNeverPlaysIt() = runTest {
        val gate = CompletableDeferred<Unit>()
        val engine = FakeSpeechEngine().apply { held["eins"] = gate }
        val speech = provider(engine)

        val first = launch { speech.stream(request(text = "eins"), streamContext()).toList() }
        runCurrent()
        val second: Job = launch { speech.stream(request(text = "zwei"), streamContext()).toList() }
        runCurrent()
        second.cancel()
        gate.complete(Unit)
        first.join()
        second.join()

        assertEquals(listOf("eins"), engine.spoken)
    }

    // --- artifact ----------------------------------------------------------------------------

    @Test
    fun synthesizesAWavArtifactWithoutPlaying() = runTest {
        val engine = FakeSpeechEngine()
        val context = runContext(FakeSpeechEngine.LOCAL_LISTED)

        val output = provider(engine).run(request(delivery = OutputDelivery.Artifact), context).output

        assertTrue(engine.spoken.isEmpty())
        assertEquals(1, engine.synthesized)
        assertEquals("audio/wav", output.artifact?.mediaType)
        assertEquals(100.0, output.artifact?.durationMs)
        assertEquals(wavBytes().size.toLong(), output.artifact?.byteLength)
    }

    @Test
    fun outputThatIsNotWavIsRefusedBeforeCommit() = runTest {
        val engine = FakeSpeechEngine(audio = ByteArray(128))
        val context = runContext(FakeSpeechEngine.LOCAL_LISTED)

        try {
            provider(engine).run(request(delivery = OutputDelivery.Artifact), context)
            fail("expected a refusal")
        } catch (error: IndeRunException) {
            assertEquals(IndeRunErrorClass.CapabilityMismatch, error.errorClass)
            assertEquals("output_format_not_supported", error.details?.get("code"))
        }
    }

    @Test
    fun aRuntimeFailureNormalizesToInternal() = runTest {
        val engine = FakeSpeechEngine().apply { speakFailure = IllegalStateException("boom") }

        val outcome = async { runCatching { provider(engine).run(request(), runContext(FakeSpeechEngine.LOCAL_LISTED)) } }

        assertEquals(IndeRunErrorClass.Internal, (outcome.await().exceptionOrNull() as IndeRunException).errorClass)
    }

    // --- speech controls ---------------------------------------------------------------------

    @Test
    fun declaresRatePitchAndPlaybackOnlyVolumeWithTaskStates() = runTest {
        val speech = provider(FakeSpeechEngine())

        val declared = speech.describe().taskCapabilities!!.single().controls!!
        assertEquals(
            listOf(SpeechControlId.SpeechSpeakingRate, SpeechControlId.SpeechPitch, SpeechControlId.PlaybackVolume),
            declared.map { it.id },
        )
        assertEquals(listOf(ControlDelivery.Playback, ControlDelivery.Artifact), declared[0].deliveries)
        assertEquals(listOf(ControlDelivery.Playback), declared[2].deliveries)

        val states = speech.capabilities(host()).taskCapabilities!!.single().controlStates!!
        val rate = states.single { it.id == SpeechControlId.SpeechSpeakingRate && it.delivery == ControlDelivery.Artifact }
        assertEquals(0.5, rate.range!!.min, 0.0)
        assertEquals(2.0, rate.range!!.max, 0.0)
        val volume = states.single { it.id == SpeechControlId.PlaybackVolume }
        assertEquals(ControlDelivery.Playback, volume.delivery)
        assertEquals(1.0, volume.range!!.max, 0.0)
        assertEquals(5, states.size)
    }

    @Test
    fun aRunWithoutControlsReportsNoRecordsAndKeepsTheUsersSettings() = runTest {
        val engine = FakeSpeechEngine()

        val output = provider(engine).run(request(), runContext(FakeSpeechEngine.LOCAL_LISTED)).output

        assertNull(output.speech!!.controls)
        // No setter at all: the user's own system rate and pitch stay in force.
        assertTrue(engine.setterCalls.isEmpty())
        assertEquals(Triple(engine.userRate, engine.userPitch, null), engine.seenAtSpeak["Hallo"])
    }

    @Test
    fun anOmittedRateIsRestoredToTheUsersDefaultSoItNeverLeaksIntoTheNextQueuedUtterance() = runTest {
        val engine = FakeSpeechEngine()
        val speech = provider(engine)

        speech.run(
            request(text = "eins"),
            runContext(FakeSpeechEngine.LOCAL_LISTED, controls = listOf(apply(SpeechControlId.SpeechSpeakingRate, 0.8))),
        )
        speech.run(request(text = "zwei"), runContext(FakeSpeechEngine.LOCAL_LISTED))
        speech.run(request(text = "drei"), runContext(FakeSpeechEngine.LOCAL_LISTED))

        assertEquals(0.8, engine.seenAtSpeak["eins"]!!.first, 0.0)
        assertEquals(engine.userRate, engine.seenAtSpeak["zwei"]!!.first, 0.0)
        // Restored once; the pitch was never touched.
        assertEquals(listOf("rate" to 0.8, "resetRate" to engine.userRate), engine.setterCalls)
        assertEquals(engine.userPitch, engine.seenAtSpeak["drei"]!!.second, 0.0)
    }

    @Test
    fun aRunThatEndsBeforeSpeakingStillHasItsRateRestoredNextTime() = runTest {
        val engine = FakeSpeechEngine()
        val speech = provider(engine)

        // Set, then the run can no longer commit: nothing plays, the engine keeps 0.8.
        try {
            speech.run(
                request(text = "eins"),
                runContext(FakeSpeechEngine.LOCAL_LISTED, commits = false, controls = listOf(apply(SpeechControlId.SpeechSpeakingRate, 0.8))),
            )
            fail("expected the run to end before commit")
        } catch (_: CancellationException) {
        }
        speech.run(request(text = "zwei"), runContext(FakeSpeechEngine.LOCAL_LISTED))

        assertNull(engine.seenAtSpeak["eins"])
        assertEquals(engine.userRate, engine.seenAtSpeak["zwei"]!!.first, 0.0)
        assertEquals("resetRate" to engine.userRate, engine.setterCalls.last())
    }

    @Test
    fun aRunThatFailsAfterSettingTheRateStillHasItRestoredNextTime() = runTest {
        val engine = FakeSpeechEngine().apply { pitchFails = true }
        val speech = provider(engine)

        // The rate is set, then the required pitch is refused before commit.
        try {
            speech.run(
                request(text = "eins"),
                runContext(
                    FakeSpeechEngine.LOCAL_LISTED,
                    controls = listOf(
                        apply(SpeechControlId.SpeechSpeakingRate, 0.8),
                        apply(SpeechControlId.SpeechPitch, 1.4, RequirementLevel.Required),
                    ),
                ),
            )
            fail("expected a refusal")
        } catch (error: IndeRunException) {
            assertEquals("speech_control_unsupported", error.details?.get("code"))
        }
        speech.run(request(text = "zwei"), runContext(FakeSpeechEngine.LOCAL_LISTED))

        assertEquals(listOf("zwei"), engine.spoken)
        assertEquals(Triple(engine.userRate, engine.userPitch, null), engine.seenAtSpeak["zwei"])
        assertEquals(listOf("resetRate" to engine.userRate, "resetPitch" to engine.userPitch), engine.setterCalls.takeLast(2))
    }

    @Test
    fun appliedControlsAreRecordedWithTheirMethodAndOmittedOnesWithThePlansReason() = runTest {
        val engine = FakeSpeechEngine()
        val plan = listOf(
            apply(SpeechControlId.SpeechSpeakingRate, 1.5),
            omit(SpeechControlId.SpeechPitch, 3.0, ControlOmissionReason.OutOfRange),
            apply(SpeechControlId.PlaybackVolume, 0.4),
        )

        val records = provider(engine).run(request(), runContext(FakeSpeechEngine.LOCAL_LISTED, controls = plan)).output.speech!!.controls!!

        assertEquals(listOf(SpeechControlId.SpeechSpeakingRate, SpeechControlId.SpeechPitch, SpeechControlId.PlaybackVolume), records.map { it.id })
        assertEquals(SpeechControlStatus.Applied, records[0].status)
        assertEquals(1.5, records[0].effective!!, 0.0)
        assertEquals(SpeechControlMethod.PlatformSynthesis, records[0].method)
        assertEquals(SpeechControlStatus.NotApplied, records[1].status)
        assertEquals(SpeechControlOutcomeReason.OutOfRange, records[1].reason)
        assertNull(records[1].effective)
        assertEquals(SpeechControlMethod.PlaybackAttenuation, records[2].method)
        assertEquals(0.4, records[2].effective!!, 0.0)
        // The omitted pitch is never set: the user's own pitch stays.
        assertEquals(Triple(1.5, engine.userPitch, 0.4), engine.seenAtSpeak["Hallo"])
    }

    @Test
    fun aRefusedRequiredControlFailsBeforeCommitSoTheEngineCanFallBack() = runTest {
        val engine = FakeSpeechEngine().apply { rateFails = true }
        var committed = false

        try {
            provider(engine).run(
                request(),
                RunContext(
                    "run_1",
                    host(),
                    voice = FakeSpeechEngine.LOCAL_LISTED,
                    controls = listOf(apply(SpeechControlId.SpeechSpeakingRate, 0.8, RequirementLevel.Required)),
                    commitHandler = {
                        committed = true
                        true
                    },
                ),
            )
            fail("expected a refusal")
        } catch (error: IndeRunException) {
            assertEquals(IndeRunErrorClass.CapabilityMismatch, error.errorClass)
            assertEquals("speech_control_unsupported", error.details?.get("code"))
        }
        assertFalse(committed)
        assertTrue(engine.spoken.isEmpty())
    }

    @Test
    fun aRefusedPreferredControlIsRecordedAsProviderRejectedAndRestoredToTheUsersDefault() = runTest {
        val engine = FakeSpeechEngine().apply { pitchFails = true }
        val plan = listOf(apply(SpeechControlId.SpeechSpeakingRate, 1.2), apply(SpeechControlId.SpeechPitch, 1.4))

        val records = provider(engine).run(request(), runContext(FakeSpeechEngine.LOCAL_LISTED, controls = plan)).output.speech!!.controls!!

        assertEquals(SpeechControlStatus.Applied, records[0].status)
        assertEquals(SpeechControlStatus.NotApplied, records[1].status)
        assertEquals(SpeechControlOutcomeReason.ProviderRejected, records[1].reason)
        assertNull(records[1].method)
        assertEquals(engine.userPitch, engine.seenAtSpeak["Hallo"]!!.second, 0.0)
        assertEquals("resetPitch" to engine.userPitch, engine.setterCalls.last())
    }

    @Test
    fun volumeTravelsOnlyWithSpeakAndAnArtifactNeverGetsIt() = runTest {
        val engine = FakeSpeechEngine()
        val speech = provider(engine)
        val plan = listOf(apply(SpeechControlId.SpeechSpeakingRate, 1.3), apply(SpeechControlId.PlaybackVolume, 0.5))

        speech.run(request(text = "eins"), runContext(FakeSpeechEngine.LOCAL_LISTED, controls = plan))
        val artifact = speech.run(
            request(delivery = OutputDelivery.Artifact),
            runContext(FakeSpeechEngine.LOCAL_LISTED, controls = plan),
        ).output

        assertEquals(0.5, engine.seenAtSpeak["eins"]!!.third!!, 0.0)
        // The render path has no volume parameter: rate is applied, volume is not applied.
        assertEquals(listOf(1.3 to engine.userPitch), engine.renderedWith)
        val records = artifact.speech!!.controls!!
        assertEquals(SpeechControlStatus.Applied, records[0].status)
        assertEquals(SpeechControlStatus.NotApplied, records[1].status)
    }

    @Test
    fun anEngineThatIgnoresVolumeDeclaresNoVolumeAndNeverClaimsIt() = runTest {
        val engine = FakeSpeechEngine().apply { attenuates = false }
        val speech = provider(engine)

        // Neither the declaration nor any state names volume, so the planner omits a preferred
        // volume as unsupported and never routes a required one here.
        val declared = speech.describe().taskCapabilities!!.single().controls!!
        assertEquals(listOf(SpeechControlId.SpeechSpeakingRate, SpeechControlId.SpeechPitch), declared.map { it.id })
        val states = speech.capabilities(host()).taskCapabilities!!.single().controlStates!!
        assertTrue(states.none { it.id == SpeechControlId.PlaybackVolume })
        assertEquals(4, states.size)
        engine.voiceList = emptyList()
        assertTrue(speech.capabilities(host()).taskCapabilities!!.single().controlStates!!.none { it.id == SpeechControlId.PlaybackVolume })
        engine.voiceList = FakeSpeechEngine.GERMAN

        // A stale plan that still applies volume is recorded as not applied, and none is passed on.
        val records = speech.run(
            request(),
            runContext(FakeSpeechEngine.LOCAL_LISTED, controls = listOf(apply(SpeechControlId.PlaybackVolume, 0.5))),
        ).output.speech!!.controls!!
        assertEquals(SpeechControlStatus.NotApplied, records.single().status)
        assertEquals(SpeechControlOutcomeReason.Unsupported, records.single().reason)
        assertNull(engine.seenAtSpeak["Hallo"]!!.third)
    }

    private fun committingContext(controls: List<ControlApplicationPlan>? = null, onCommit: () -> Unit) = RunContext(
        "run_1",
        host(),
        voice = FakeSpeechEngine.LOCAL_LISTED,
        controls = controls,
        commitHandler = {
            onCommit()
            true
        },
    )

    @Test
    fun aRestoreRefusedTwiceRefusesTheRunBeforeCommitAndStaysPendingForTheNextUtterance() = runTest {
        val engine = FakeSpeechEngine()
        val speech = provider(engine)
        speech.run(
            request(text = "eins"),
            runContext(FakeSpeechEngine.LOCAL_LISTED, controls = listOf(apply(SpeechControlId.SpeechSpeakingRate, 0.8))),
        )
        engine.rateResetFailures = 2
        var committed = false

        // The engine still speaks at 0.8, so this no-control run must not commit.
        try {
            speech.run(request(text = "zwei"), committingContext { committed = true })
            fail("expected a refusal")
        } catch (error: IndeRunException) {
            assertEquals(IndeRunErrorClass.CapabilityMismatch, error.errorClass)
            assertEquals("speech_settings_not_restored", error.details?.get("code"))
        }
        assertFalse(committed)
        assertEquals(listOf("eins"), engine.spoken)
        assertEquals(listOf("resetRate" to engine.userRate, "resetRate" to engine.userRate), engine.setterCalls.drop(1))

        // Still marked: the next utterance restores it and speaks with the user's rate.
        speech.run(request(text = "drei"), runContext(FakeSpeechEngine.LOCAL_LISTED))
        assertEquals(listOf("eins", "drei"), engine.spoken)
        assertEquals(engine.userRate, engine.seenAtSpeak["drei"]!!.first, 0.0)
    }

    @Test
    fun aRestoreRefusedOnceIsRetriedAndTheRunSpeaks() = runTest {
        val engine = FakeSpeechEngine()
        val speech = provider(engine)
        speech.run(
            request(text = "eins"),
            runContext(FakeSpeechEngine.LOCAL_LISTED, controls = listOf(apply(SpeechControlId.SpeechSpeakingRate, 0.8))),
        )
        engine.rateResetFailures = 1

        speech.run(request(text = "zwei"), runContext(FakeSpeechEngine.LOCAL_LISTED))
        speech.run(request(text = "drei"), runContext(FakeSpeechEngine.LOCAL_LISTED))

        assertEquals(listOf("eins", "zwei", "drei"), engine.spoken)
        assertEquals(engine.userRate, engine.seenAtSpeak["zwei"]!!.first, 0.0)
        // Two reset calls, then nothing: the retry restored it, so "drei" has nothing to restore.
        assertEquals(
            listOf("rate" to 0.8, "resetRate" to engine.userRate, "resetRate" to engine.userRate),
            engine.setterCalls,
        )
    }

    @Test
    fun aRefusedPreferredSetterWhoseRestoreIsRefusedTwiceRefusesTheRunBeforeCommit() = runTest {
        val engine = FakeSpeechEngine().apply {
            pitchFails = true
            pitchResetFailures = 2
        }
        var committed = false

        try {
            provider(engine).run(
                request(),
                committingContext(listOf(apply(SpeechControlId.SpeechPitch, 1.4))) { committed = true },
            )
            fail("expected a refusal")
        } catch (error: IndeRunException) {
            assertEquals(IndeRunErrorClass.CapabilityMismatch, error.errorClass)
            assertEquals("speech_settings_not_restored", error.details?.get("code"))
        }
        assertFalse(committed)
        assertTrue(engine.spoken.isEmpty())
        assertEquals(
            listOf("pitch" to 1.4, "resetPitch" to engine.userPitch, "resetPitch" to engine.userPitch),
            engine.setterCalls,
        )
    }

    @Test
    fun aRequiredVolumeTheEngineStoppedAttenuatingSincePlanningIsRefusedBeforeAnySetter() = runTest {
        val engine = FakeSpeechEngine()
        val speech = provider(engine)
        // Planned while the engine attenuated.
        assertTrue(speech.describe().taskCapabilities!!.single().controls!!.any { it.id == SpeechControlId.PlaybackVolume })
        assertTrue(speech.capabilities(host()).taskCapabilities!!.single().controlStates!!.any { it.id == SpeechControlId.PlaybackVolume })
        engine.attenuates = false
        var committed = false
        val plan = listOf(
            apply(SpeechControlId.SpeechSpeakingRate, 0.8),
            apply(SpeechControlId.PlaybackVolume, 0.5, RequirementLevel.Required),
        )

        try {
            speech.run(request(), committingContext(plan) { committed = true })
            fail("expected a refusal")
        } catch (error: IndeRunException) {
            assertEquals(IndeRunErrorClass.CapabilityMismatch, error.errorClass)
            assertEquals("speech_control_unsupported", error.details?.get("code"))
        }
        assertFalse(committed)
        assertTrue(engine.spoken.isEmpty())
        assertTrue(engine.setterCalls.isEmpty())
    }

    @Test
    fun aPreferredVolumeTheEngineStoppedAttenuatingSincePlanningIsNotAppliedAndNotPassedOn() = runTest {
        val engine = FakeSpeechEngine()
        val speech = provider(engine)
        speech.describe()
        speech.capabilities(host())
        engine.attenuates = false
        engine.attenuatesReads = 0

        val records = speech.run(
            request(),
            runContext(FakeSpeechEngine.LOCAL_LISTED, controls = listOf(apply(SpeechControlId.PlaybackVolume, 0.5))),
        ).output.speech!!.controls!!

        assertEquals(listOf("Hallo"), engine.spoken)
        assertEquals(SpeechControlStatus.NotApplied, records.single().status)
        assertEquals(SpeechControlOutcomeReason.Unsupported, records.single().reason)
        assertNull(engine.seenAtSpeak["Hallo"]!!.third)
        // One reading per attempt, so the check and the records cannot disagree.
        assertEquals(1, engine.attenuatesReads)
    }

    @Test
    fun theSpeechIsReportedOnceAfterTheCommitAndMatchesTheFinalOutput() = runTest {
        val engine = FakeSpeechEngine()
        val events = mutableListOf<String>()
        val reported = mutableListOf<app.independo.inderun.contracts.SpeechOutput>()
        val context = streamContext(
            FakeSpeechEngine.LOCAL_LISTED,
            controls = listOf(apply(SpeechControlId.SpeechSpeakingRate, 0.9)),
            reportSpeech = {
                events += "report"
                reported += it
            },
            commit = {
                events += "commit"
                true
            },
        )

        val result = provider(engine).stream(request(), context).toList().single() as ProviderStreamEvent.Result

        assertEquals(listOf("commit", "report"), events)
        assertEquals(result.output.speech, reported.single())
    }

    @Test
    fun closeReleasesTheEngine() {
        val engine = FakeSpeechEngine()

        provider(engine).close()

        assertTrue(engine.closed)
    }
}
