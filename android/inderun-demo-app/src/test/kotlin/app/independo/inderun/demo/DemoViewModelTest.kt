package app.independo.inderun.demo

import app.independo.inderun.contracts.ArtifactReadRequest
import app.independo.inderun.contracts.CancelSemantics
import app.independo.inderun.contracts.ControlDelivery
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.MediaArtifact
import app.independo.inderun.contracts.Outcome
import app.independo.inderun.contracts.Payload
import app.independo.inderun.contracts.PayloadTelemetry
import app.independo.inderun.contracts.ProviderCapabilitySnapshot
import app.independo.inderun.contracts.ProviderDescriptor
import app.independo.inderun.contracts.ProviderDynamicCapabilities
import app.independo.inderun.contracts.ProviderSupports
import app.independo.inderun.contracts.ProviderTransport
import app.independo.inderun.contracts.ProviderType
import app.independo.inderun.contracts.RequestedNumber
import app.independo.inderun.contracts.RequestedUnitNumber
import app.independo.inderun.contracts.RequirementLevel
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.SharedSynthesisControls
import app.independo.inderun.contracts.SpeechControlId
import app.independo.inderun.contracts.SpeechControlPhase
import app.independo.inderun.contracts.SpeechControlRange
import app.independo.inderun.contracts.StreamEvent
import app.independo.inderun.contracts.StreamRunHandle
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.core.ArtifactChunk
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.StreamRun
import app.independo.inderun.sdk.SpeakOptions
import app.independo.inderun.sdk.SpeechPlayback
import app.independo.inderun.sdk.SpeechVoiceControl
import app.independo.inderun.sdk.SpeechVoiceInfo
import app.independo.inderun.sdk.generated.IndeRunApi
import app.independo.inderun.sdk.speak
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.asFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class DemoViewModelTest {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    @Test
    fun init_loadsPersistedSettingsAndCapabilities() = runTest {
        val settingsStore = FakeSettingsStore(
            DemoSettings(
                endpointUrl = "http://example.com/v1/responses",
                model = "gemma4:latest",
                onnxModelSelection = DemoOnnxModelSelection.Fixture,
            ),
        )
        val runtime = FakeRuntime(
            snapshots = listOf(fakeSnapshot("android_mlkit_genai", available = true)),
        )

        val viewModel = DemoViewModel(settingsStore, runtime, FakeOnnxDownloader(), mainDispatcherRule.dispatcher)
        advanceUntilIdle()

        val state = viewModel.uiState.value
        assertEquals("http://example.com/v1/responses", state.cloudEndpointUrl)
        assertEquals("gemma4:latest", state.cloudModel)
        assertEquals(DemoOnnxModelSelection.Fixture, state.onnxModelSelection)
        val capabilitiesState = state.capabilitiesState
        assertTrue(capabilitiesState is CapabilitiesState.Ready)
        assertEquals(1, (capabilitiesState as CapabilitiesState.Ready).badges.size)
    }

    @Test
    fun voicesLab_isOffByDefaultAndTheChoiceIsPersisted() = runTest {
        val store = FakeSettingsStore()
        val viewModel = DemoViewModel(store, FakeRuntime(), FakeOnnxDownloader(), mainDispatcherRule.dispatcher)
        advanceUntilIdle()
        assertFalse(viewModel.uiState.value.voicesLabEnabled)
        assertFalse(store.load().voicesLabEnabled)

        viewModel.updateVoicesLabEnabled(true)

        assertTrue(viewModel.uiState.value.voicesLabEnabled)
        assertTrue(store.load().voicesLabEnabled)
        val reloaded = DemoViewModel(store, FakeRuntime(), FakeOnnxDownloader(), mainDispatcherRule.dispatcher)
        assertTrue(reloaded.uiState.value.voicesLabEnabled)
    }

    @Test
    fun canRun_requiresNonBlankPrompt() = runTest {
        val viewModel = DemoViewModel(FakeSettingsStore(), FakeRuntime(), FakeOnnxDownloader(), mainDispatcherRule.dispatcher)
        advanceUntilIdle()

        viewModel.updatePrompt("   ")
        advanceUntilIdle()
        assertFalse(viewModel.uiState.value.canRun)

        viewModel.updatePrompt("Tell me a story.")
        advanceUntilIdle()
        assertTrue(viewModel.uiState.value.canRun)
    }

    @Test
    fun runPrompt_mapsSuccessMetadataAndRouteDecisionIntoUiState() = runTest {
        val runtime = FakeRuntime(
            runOutcome = DemoExecutionOutcome.Success(
                outputText = "Generated answer",
                metadata = AttemptMetadata(
                    runId = "run_123",
                    providerUsed = "openai_compatible_cloud",
                    totalMs = 42.0,
                    providerId = "openai_compatible_cloud",
                    retryAfterMs = null,
                ),
            ),
            routeDecision = RouteDecision(
                selectedProviderId = "openai_compatible_cloud",
                explanation = "cloud allowed",
                rejectedProviderIds = emptyList(),
                fallbackProviderIds = emptyList(),
            ),
        )
        val viewModel = DemoViewModel(FakeSettingsStore(), runtime, FakeOnnxDownloader(), mainDispatcherRule.dispatcher)
        advanceUntilIdle()

        viewModel.updatePrivacy(PrivacyPreference.CloudRequired)
        viewModel.runPrompt()
        advanceUntilIdle()

        val result = viewModel.uiState.value.result
        assertNotNull(result)
        assertEquals("Generated answer", result?.outputText)
        assertEquals("run_123", result?.metadata?.runId)
        assertEquals("openai_compatible_cloud", viewModel.uiState.value.lastRouteDecision?.selectedProviderId)
    }

    @Test
    fun runPrompt_mapsFailureIntoUiState() = runTest {
        val runtime = FakeRuntime(
            runOutcome = DemoExecutionOutcome.Failure(
                error = DemoErrorState(
                    title = "Normalized Error",
                    body = "Unavailable\n\nCould not reach the configured cloud endpoint.",
                    metadata = AttemptMetadata(
                        runId = "run_456",
                        providerUsed = "cloud",
                        totalMs = 7.0,
                        providerId = null,
                        retryAfterMs = null,
                    ),
                ),
            ),
        )
        val viewModel = DemoViewModel(FakeSettingsStore(), runtime, FakeOnnxDownloader(), mainDispatcherRule.dispatcher)
        advanceUntilIdle()

        viewModel.runPrompt()
        advanceUntilIdle()

        assertEquals("Normalized Error", viewModel.uiState.value.error?.title)
    }

    private fun fakeSnapshot(providerId: String, available: Boolean): ProviderCapabilitySnapshot = ProviderCapabilitySnapshot(
        providerId = providerId,
        descriptor = ProviderDescriptor(
            id = providerId,
            type = ProviderType.Local,
            transport = ProviderTransport.SystemService,
            supports = ProviderSupports(
                run = true,
                streaming = false,
                realtime = false,
                tools = false,
                reasoningEvents = false,
                structuredOutput = false,
                multimodal = false,
            ),
            cancel = CancelSemantics.None,
            tasks = listOf("text_to_text"),
        ),
        capabilities = ProviderDynamicCapabilities(available = available),
    )

    private class FakeSettingsStore(
        private var settings: DemoSettings = DemoSettings(
            endpointUrl = DemoDefaults.DEFAULT_CLOUD_ENDPOINT_URL,
            model = DemoDefaults.DEFAULT_CLOUD_MODEL,
            onnxModelSelection = DemoDefaults.DEFAULT_ONNX_MODEL_SELECTION,
        ),
    ) : DemoSettingsStore {
        override fun load(): DemoSettings = settings

        override fun save(settings: DemoSettings) {
            this.settings = settings
        }
    }

    private class FakeOnnxDownloader : DemoOnnxDownloader {
        override fun relativeRef(model: DemoOnnxModelOption): String = "fake/${model.id}"
        override fun isDownloaded(model: DemoOnnxModelOption): Boolean = false
        override suspend fun download(model: DemoOnnxModelOption, onProgress: (Float) -> Unit) = Unit
    }

    @Test
    fun streamPrompt_appendsDeltasAndRecordsTheCompletedTerminal() = runTest {
        val runtime = FakeRuntime(
            streamStart = {
                DemoStreamStart.Started(
                    streamRun(listOf(delta(0, "Hello"), delta(1, " world"), completed(2, "Hello world"))),
                )
            },
        )
        val viewModel = DemoViewModel(FakeSettingsStore(), runtime, FakeOnnxDownloader(), mainDispatcherRule.dispatcher)
        advanceUntilIdle()

        viewModel.streamPrompt()
        advanceUntilIdle()

        val state = viewModel.uiState.value
        assertFalse(state.isStreaming)
        assertEquals("Hello world", state.stream?.text)
        assertEquals(Outcome.Completed, state.stream?.outcome)
        assertEquals("finish reason: stop", state.stream?.detail)
        assertEquals("android_mlkit_genai", state.stream?.providerUsed)
    }

    @Test
    fun streamPrompt_surfacesARoutingRefusalAsAnErrorWithNoStreamPanel() = runTest {
        val runtime = FakeRuntime(
            streamStart = {
                DemoStreamStart.Refused(
                    DemoErrorState(title = "Normalized Error", body = "capability_mismatch", metadata = null),
                )
            },
        )
        val viewModel = DemoViewModel(FakeSettingsStore(), runtime, FakeOnnxDownloader(), mainDispatcherRule.dispatcher)
        advanceUntilIdle()

        viewModel.streamPrompt()
        advanceUntilIdle()

        val state = viewModel.uiState.value
        assertFalse(state.isStreaming)
        assertNull(state.stream)
        assertEquals("capability_mismatch", state.error?.body)
    }

    @Test
    fun cancelStream_forwardsToTheRunHandleAndEndsWithACancelledOutcome() = runTest {
        var cancelReason: String? = null
        val gate = CompletableDeferred<Unit>()
        val runtime = FakeRuntime(
            streamStart = {
                DemoStreamStart.Started(
                    StreamRun(
                        handle = StreamRunHandle(
                            providerId = "android_mlkit_genai",
                            runId = "run_stream",
                            schemaVersion = SchemaVersion.V1_1,
                            startedAt = 0.0,
                        ),
                        // Parks after the first delta, the way a real stream waits for
                        // the next chunk, so cancelling has something to interrupt.
                        events = flow {
                            emit(delta(0, "one"))
                            gate.await()
                            emit(cancelled(1, partialText = "one", reason = "cancelled from the demo app"))
                        },
                        onCancel = { reason ->
                            cancelReason = reason
                            gate.complete(Unit)
                        },
                    ),
                )
            },
        )
        val viewModel = DemoViewModel(FakeSettingsStore(), runtime, FakeOnnxDownloader(), mainDispatcherRule.dispatcher)
        advanceUntilIdle()

        viewModel.streamPrompt()
        advanceUntilIdle()
        assertTrue(viewModel.uiState.value.isStreaming)

        viewModel.cancelStream()
        advanceUntilIdle()

        assertEquals("cancelled from the demo app", cancelReason)
        val state = viewModel.uiState.value
        assertFalse(state.isStreaming)
        assertEquals(Outcome.Cancelled, state.stream?.outcome)
        assertEquals("one", state.stream?.text)
    }

    @Test
    fun stopIsOfferedOnlyWhileAPlaybackHandleExists() = runTest {
        val routed = CompletableDeferred<Unit>()
        val playing = CompletableDeferred<Unit>()
        var cancelReason: String? = null
        val runtime = FakeRuntime(
            speakStart = { scope ->
                routed.await()
                FakeSpeechApi(
                    onCancel = { reason ->
                        cancelReason = reason
                        playing.complete(Unit)
                    },
                    playing = playing,
                ).speak(SpeakOptions("Hallo", locale = "de-DE"), scope)
            },
        )
        val viewModel = DemoViewModel(FakeSettingsStore(), runtime, FakeOnnxDownloader(), mainDispatcherRule.dispatcher)
        advanceUntilIdle()

        viewModel.updateSpeechText("Hallo")
        viewModel.speak()
        advanceUntilIdle()
        assertTrue(viewModel.uiState.value.isSpeaking)
        assertFalse(viewModel.uiState.value.canStopSpeaking)

        routed.complete(Unit)
        advanceUntilIdle()
        assertTrue(viewModel.uiState.value.canStopSpeaking)

        viewModel.stopSpeaking()
        advanceUntilIdle()
        assertEquals("stopped from the demo app", cancelReason)
        assertFalse(viewModel.uiState.value.isSpeaking)
        assertFalse(viewModel.uiState.value.canStopSpeaking)
    }

    @Test
    fun speakSendsNoControlsUntilOneIsTurnedOn() = runTest {
        val runtime = FakeRuntime(
            speakStart = { throw IndeRunException(IndeRunErrorClass.Internal, "stub") },
            voices = listOf(voiceWithControls),
        )
        val viewModel = DemoViewModel(FakeSettingsStore(), runtime, FakeOnnxDownloader(), mainDispatcherRule.dispatcher)
        advanceUntilIdle()

        viewModel.speak()
        advanceUntilIdle()

        assertNull(runtime.spoken.single().speech.controls)
        assertNull(runtime.spoken.single().playback)
    }

    // Playback accepts all three; the artifact accepts rate only within 0.8-1.2 and has no pitch.
    private val voiceWithControls = SpeechVoiceInfo(
        providerId = "p",
        locale = "de-DE",
        id = "anna",
        controls = listOf(
            control(SpeechControlId.SpeechSpeakingRate, ControlDelivery.Playback, 0.5, 2.0),
            control(SpeechControlId.SpeechSpeakingRate, ControlDelivery.Artifact, 0.8, 1.2),
            control(SpeechControlId.SpeechPitch, ControlDelivery.Playback, 0.5, 2.0),
            SpeechVoiceControl(
                SpeechControlId.SpeechPitch,
                ControlDelivery.Artifact,
                SpeechControlPhase.Synthesis,
                available = false,
                reason = "unsupported",
            ),
            control(SpeechControlId.PlaybackVolume, ControlDelivery.Playback, 0.0, 1.0),
        ),
    )

    private fun control(id: SpeechControlId, delivery: ControlDelivery, min: Double, max: Double) = SpeechVoiceControl(
        id,
        delivery,
        SpeechControlPhase.Synthesis,
        available = true,
        range = SpeechControlRange(max = max, min = min),
    )

    @Test
    fun speakAndSynthesizeBuildTheirOptionsFromTheChosenControls() = runTest {
        val runtime = FakeRuntime(
            speakStart = { throw IndeRunException(IndeRunErrorClass.Internal, "stub") },
            synthesizeOutcome = "audio/wav",
            voices = listOf(voiceWithControls),
        )
        val viewModel = DemoViewModel(FakeSettingsStore(), runtime, FakeOnnxDownloader(), mainDispatcherRule.dispatcher)
        advanceUntilIdle()
        viewModel.updateSpeechVoice("anna")
        advanceUntilIdle()
        viewModel.updateSpeechControl(SpeechControlId.SpeechSpeakingRate, 1.0)
        viewModel.updateSpeechControl(SpeechControlId.SpeechPitch, 0.8)
        viewModel.updateSpeechControl(SpeechControlId.PlaybackVolume, 0.4)
        viewModel.updateRequireRate(true)

        viewModel.speak()
        advanceUntilIdle()
        viewModel.synthesizeSpeech()
        advanceUntilIdle()

        val rate = RequestedNumber(requirement = RequirementLevel.Required, value = 1.0)
        val expected = SharedSynthesisControls(pitch = RequestedNumber(value = 0.8), speakingRate = rate)
        assertEquals(expected, runtime.spoken.single().speech.controls)
        assertEquals(RequestedUnitNumber(value = 0.4), runtime.spoken.single().playback?.volume)
        // Generate reads the artifact state: rate 1.0 is inside 0.8-1.2, pitch is unavailable there,
        // and there is never a volume.
        assertEquals(SharedSynthesisControls(pitch = null, speakingRate = rate), runtime.synthesized.single().speech.controls)
        assertNull(runtime.synthesized.single().playback)
    }

    @Test
    fun aNewVoiceStartsWithEveryControlOff() = runTest {
        val viewModel = DemoViewModel(FakeSettingsStore(), FakeRuntime(), FakeOnnxDownloader(), mainDispatcherRule.dispatcher)
        advanceUntilIdle()
        viewModel.updateSpeechControl(SpeechControlId.SpeechPitch, 0.8)
        viewModel.updateRequireRate(true)

        viewModel.updateSpeechLocale("en-US")

        assertEquals(SpeechControlChoices(requireRate = true), viewModel.uiState.value.speechControls)
    }

    /** An engine whose one playback holds until cancelled, then ends as a cancelled stream. */
    private class FakeSpeechApi(
        private val onCancel: (String?) -> Unit,
        private val playing: CompletableDeferred<Unit>,
    ) : IndeRunApi {
        override suspend fun prepare(request: app.independo.inderun.contracts.PrepareRequest): app.independo.inderun.core.StreamRun = error("not scripted")

        override suspend fun stream(request: TaskRequest): StreamRun = StreamRun(
            handle = StreamRunHandle(
                providerId = "android_system_speech",
                runId = "run_speech",
                schemaVersion = SchemaVersion.V1_1,
                startedAt = 0.0,
            ),
            events = flow {
                playing.await()
                emit(cancelled(0, partialText = "", reason = "stopped from the demo app"))
            },
            onCancel = onCancel,
        )

        override suspend fun run(request: TaskRequest): TaskResult = error("not scripted")

        override suspend fun checkCapabilities(): List<ProviderCapabilitySnapshot> = emptyList()

        override suspend fun readArtifact(request: ArtifactReadRequest): ArtifactChunk = error("not scripted")

        override suspend fun disposeArtifact(artifact: MediaArtifact) = error("not scripted")

        override suspend fun close() = error("not scripted")
    }

    private class FakeRuntime(
        private val snapshots: List<ProviderCapabilitySnapshot> = emptyList(),
        private val runOutcome: DemoExecutionOutcome = DemoExecutionOutcome.Success(
            outputText = "Default response",
            metadata = AttemptMetadata(
                runId = "run_default",
                providerUsed = "android_mlkit_genai",
                totalMs = 1.0,
                providerId = "android_mlkit_genai",
                retryAfterMs = null,
            ),
        ),
        private val routeDecision: RouteDecision? = null,
        private val streamStart: () -> DemoStreamStart = { DemoStreamStart.Started(streamRun(emptyList())) },
        private val speakStart: suspend (CoroutineScope) -> SpeechPlayback = { error("not scripted") },
        private val synthesizeOutcome: String = "not scripted",
        private val voices: List<SpeechVoiceInfo> = emptyList(),
    ) : DemoRuntime {
        val spoken = mutableListOf<SpeakOptions>()
        val synthesized = mutableListOf<SpeakOptions>()

        override suspend fun checkCapabilities(settings: DemoSettings): List<ProviderCapabilitySnapshot> = snapshots

        override suspend fun listVoices(locale: String, settings: DemoSettings): List<SpeechVoiceInfo> = voices

        override suspend fun prepareSpeech(request: app.independo.inderun.contracts.PrepareRequest, settings: DemoSettings, scope: CoroutineScope) = Unit

        override suspend fun speak(options: SpeakOptions, settings: DemoSettings, scope: CoroutineScope): SpeechPlayback {
            spoken += options
            return speakStart(scope)
        }

        override suspend fun synthesizeSpeech(options: SpeakOptions, settings: DemoSettings): String {
            synthesized += options
            return synthesizeOutcome
        }

        override suspend fun run(
            prompt: String,
            privacy: PrivacyPreference,
            settings: DemoSettings,
        ): DemoExecutionOutcome = runOutcome

        override suspend fun stream(
            prompt: String,
            privacy: PrivacyPreference,
            settings: DemoSettings,
        ): DemoStreamStart = streamStart()

        override fun lastRouteDecision(): RouteDecision? = routeDecision
    }

    private companion object {
        fun streamRun(events: List<StreamEvent>, onCancel: (String?) -> Unit = {}): StreamRun = StreamRun(
            handle = StreamRunHandle(
                providerId = "android_mlkit_genai",
                runId = "run_stream",
                schemaVersion = SchemaVersion.V1_1,
                startedAt = 0.0,
            ),
            events = events.asFlow(),
            onCancel = onCancel,
        )

        fun delta(sequence: Long, text: String) = StreamEvent(
            payload = Payload(text = text),
            runId = "run_stream",
            schemaVersion = SchemaVersion.V1_1,
            sequence = sequence,
            timestamp = 0.0,
            type = "content_delta",
        )

        fun completed(sequence: Long, finalText: String) = StreamEvent(
            payload = Payload(
                finalText = finalText,
                finishReason = FinishReason.STOP,
                outcome = Outcome.Completed,
                runId = "run_stream",
                telemetry = PayloadTelemetry(providerUsed = "android_mlkit_genai", totalMs = 12.0),
            ),
            runId = "run_stream",
            schemaVersion = SchemaVersion.V1_1,
            sequence = sequence,
            timestamp = 0.0,
            type = "terminal",
        )

        fun cancelled(sequence: Long, partialText: String, reason: String) = StreamEvent(
            payload = Payload(
                outcome = Outcome.Cancelled,
                partialText = partialText,
                reason = reason,
                runId = "run_stream",
            ),
            runId = "run_stream",
            schemaVersion = SchemaVersion.V1_1,
            sequence = sequence,
            timestamp = 0.0,
            type = "terminal",
        )
    }
}
