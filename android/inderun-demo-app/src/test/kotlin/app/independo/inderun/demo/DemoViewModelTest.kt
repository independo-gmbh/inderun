package app.independo.inderun.demo

import app.independo.inderun.core.ProviderCapabilitySnapshot
import app.independo.inderun.core.ProviderDescriptor
import app.independo.inderun.core.ProviderDynamicCapabilities
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
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
    ) : DemoRuntime {
        override suspend fun checkCapabilities(settings: DemoSettings): List<ProviderCapabilitySnapshot> = snapshots

        override suspend fun run(
            prompt: String,
            privacy: PrivacyPreference,
            settings: DemoSettings,
        ): DemoExecutionOutcome = runOutcome

        override fun lastRouteDecision(): RouteDecision? = routeDecision
    }
}
