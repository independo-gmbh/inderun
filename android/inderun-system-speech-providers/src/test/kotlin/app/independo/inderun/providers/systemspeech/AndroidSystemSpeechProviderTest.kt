package app.independo.inderun.providers.systemspeech

import app.independo.inderun.contracts.CancelSemantics
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.OutputDelivery
import app.independo.inderun.contracts.OutputDeliveryRequest
import app.independo.inderun.contracts.Privacy
import app.independo.inderun.contracts.ProviderReadiness
import app.independo.inderun.contracts.ProviderVoice
import app.independo.inderun.contracts.SchemaVersion
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

    override suspend fun speakWithTimings(text: String) = AndroidSpokenAudio(speak(text), firstAudioMs)

    override suspend fun synthesize(text: String, maxBytes: Long): ByteArray {
        synthesized += 1
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
        schemaVersion = SchemaVersion.V1_0,
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

    private fun runContext(voice: ProviderVoice? = null, commits: Boolean = true) = RunContext(
        "run_1",
        host(),
        voice = voice,
        commitHandler = { commits },
    )

    private fun streamContext(voice: ProviderVoice? = null, commit: () -> Boolean = { true }) = ProviderStreamContext(
        runId = "run_1",
        hostServices = host(),
        cancellation = StreamCancellationToken(),
        voice = voice,
        commitHandler = commit,
    )

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

    @Test
    fun closeReleasesTheEngine() {
        val engine = FakeSpeechEngine()

        provider(engine).close()

        assertTrue(engine.closed)
    }
}
