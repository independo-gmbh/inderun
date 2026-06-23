package app.independo.inderun.demo

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
    fun init_loadsPersistedSettingsAndAvailability() = runTest {
        val settingsStore = FakeSettingsStore(
            DemoSettings(
                endpointUrl = "http://example.com/v1/responses",
                model = "gemma4:latest"
            )
        )
        val runtime = FakeRuntime(
            availabilitySnapshot = DemoAvailabilitySnapshot(
                onDevice = DemoAvailabilityState.available("On-device ready."),
                cloud = DemoAvailabilityState.available("Cloud ready.")
            )
        )

        val viewModel = DemoViewModel(settingsStore, runtime, mainDispatcherRule.dispatcher)
        advanceUntilIdle()

        val state = viewModel.uiState.value
        assertEquals("http://example.com/v1/responses", state.cloudEndpointUrl)
        assertEquals("gemma4:latest", state.cloudModel)
        assertEquals("Cloud ready.", state.cloudStatus.message)
        assertEquals("On-device ready.", state.onDeviceStatus.message)
    }

    @Test
    fun canRun_requiresValidCloudConfiguration() = runTest {
        val viewModel = DemoViewModel(
            FakeSettingsStore(),
            FakeRuntime(),
            mainDispatcherRule.dispatcher
        )
        advanceUntilIdle()

        viewModel.updateExecutionMode(DemoExecutionMode.Cloud)
        viewModel.updateCloudEndpointUrl("not-a-url")
        advanceUntilIdle()
        assertFalse(viewModel.uiState.value.canRun)

        viewModel.updateCloudEndpointUrl(DemoDefaults.defaultCloudEndpointUrl)
        viewModel.updateCloudModel("")
        advanceUntilIdle()
        assertFalse(viewModel.uiState.value.canRun)

        viewModel.updateCloudModel("gpt-5.2")
        advanceUntilIdle()
        assertTrue(viewModel.uiState.value.canRun)
    }

    @Test
    fun runPrompt_mapsSuccessMetadataIntoUiState() = runTest {
        val runtime = FakeRuntime(
            runOutcome = DemoExecutionOutcome.Success(
                outputText = "Generated answer",
                metadata = AttemptMetadata(
                    runId = "run_123",
                    providerUsed = "openai_compatible_cloud",
                    totalMs = 42.0,
                    providerId = "openai_compatible_cloud",
                    retryAfterMs = null
                )
            )
        )
        val viewModel = DemoViewModel(FakeSettingsStore(), runtime, mainDispatcherRule.dispatcher)
        advanceUntilIdle()

        viewModel.updateExecutionMode(DemoExecutionMode.Cloud)
        viewModel.runPrompt()
        advanceUntilIdle()

        val result = viewModel.uiState.value.result
        assertNotNull(result)
        assertEquals("Generated answer", result?.outputText)
        assertEquals("run_123", result?.metadata?.runId)
        assertEquals("The configured cloud route completed the last request successfully.", viewModel.uiState.value.cloudStatus.message)
    }

    @Test
    fun runPrompt_mapsFailureAndAvailabilityOverride() = runTest {
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
                        retryAfterMs = null
                    )
                ),
                cloudStatusOverride = DemoAvailabilityState.unavailable("Could not reach the local demo proxy.")
            )
        )
        val viewModel = DemoViewModel(FakeSettingsStore(), runtime, mainDispatcherRule.dispatcher)
        advanceUntilIdle()

        viewModel.updateExecutionMode(DemoExecutionMode.Cloud)
        viewModel.runPrompt()
        advanceUntilIdle()

        assertEquals("Normalized Error", viewModel.uiState.value.error?.title)
        assertEquals("Could not reach the local demo proxy.", viewModel.uiState.value.cloudStatus.message)
    }

    private class FakeSettingsStore(
        private var settings: DemoSettings = DemoSettings(
            endpointUrl = DemoDefaults.defaultCloudEndpointUrl,
            model = DemoDefaults.defaultCloudModel
        )
    ) : DemoSettingsStore {
        override fun load(): DemoSettings = settings

        override fun save(settings: DemoSettings) {
            this.settings = settings
        }
    }

    private class FakeRuntime(
        private val availabilitySnapshot: DemoAvailabilitySnapshot = DemoAvailabilitySnapshot(
            onDevice = DemoAvailabilityState.available("On-device available."),
            cloud = DemoAvailabilityState.available("Cloud available.")
        ),
        private val runOutcome: DemoExecutionOutcome = DemoExecutionOutcome.Success(
            outputText = "Default response",
            metadata = AttemptMetadata(
                runId = "run_default",
                providerUsed = "android_mlkit_genai",
                totalMs = 1.0,
                providerId = "android_mlkit_genai",
                retryAfterMs = null
            )
        )
    ) : DemoRuntime {
        override suspend fun refreshAvailability(settings: DemoSettings): DemoAvailabilitySnapshot {
            return availabilitySnapshot
        }

        override suspend fun run(
            prompt: String,
            executionMode: DemoExecutionMode,
            settings: DemoSettings
        ): DemoExecutionOutcome {
            return runOutcome
        }
    }
}
