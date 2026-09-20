package app.independo.inderun.demo

import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.Outcome
import app.independo.inderun.contracts.Payload
import app.independo.inderun.contracts.PayloadTelemetry
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.StreamEvent
import app.independo.inderun.contracts.StreamRunHandle
import app.independo.inderun.core.ProviderCapabilitySnapshot
import app.independo.inderun.core.ProviderDescriptor
import app.independo.inderun.core.ProviderDynamicCapabilities
import app.independo.inderun.core.StreamRun
import kotlinx.coroutines.CompletableDeferred
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
            type = ProviderDescriptor.ProviderType.local,
            transport = ProviderDescriptor.TransportType.system_service,
            supports = ProviderDescriptor.SupportsCapabilities(
                run = true,
                streaming = false,
                realtime = false,
                tools = false,
                reasoningEvents = false,
                structuredOutput = false,
                multimodal = false,
            ),
            cancel = ProviderDescriptor.CancelSemantics.none,
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
                            schemaVersion = SchemaVersion.V1_0,
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
    ) : DemoRuntime {
        override suspend fun checkCapabilities(settings: DemoSettings): List<ProviderCapabilitySnapshot> = snapshots

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
                schemaVersion = SchemaVersion.V1_0,
                startedAt = 0.0,
            ),
            events = events.asFlow(),
            onCancel = onCancel,
        )

        fun delta(sequence: Long, text: String) = StreamEvent(
            payload = Payload(text = text),
            runId = "run_stream",
            schemaVersion = SchemaVersion.V1_0,
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
            schemaVersion = SchemaVersion.V1_0,
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
            schemaVersion = SchemaVersion.V1_0,
            sequence = sequence,
            timestamp = 0.0,
            type = "terminal",
        )
    }
}
