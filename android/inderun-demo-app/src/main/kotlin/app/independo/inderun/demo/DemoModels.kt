package app.independo.inderun.demo

import app.independo.inderun.contracts.PrivacyEnum
import app.independo.inderun.contracts.TaskRequestConstraints
import java.util.Locale

internal object DemoDefaults {
    const val DEFAULT_CLOUD_ENDPOINT_URL = "http://10.0.2.2:8787/api/inderun/openai-responses"
    const val DEFAULT_CLOUD_MODEL = "gpt-5.2"

    // A declarative sentence fragment, not an instruction: the default ONNX Local model
    // (DistilGPT-2, a non-instruction-tuned base model with no chat template) continues plain
    // text far more reliably than it follows a task instruction, which it often responds to by
    // immediately predicting the end-of-sequence token -- i.e. empty output.
    const val DEFAULT_PROMPT = "On-device AI is useful because"

    val DEFAULT_ONNX_MODEL_SELECTION = DemoOnnxModelSelection.Distilgpt2Quantized
}

/**
 * A 4-way privacy preference IndeRun's capability-based routing selects a provider from,
 * mirroring the web demo's `Privacy` selector and the iOS demo's `PrivacyPreference`.
 */
internal enum class PrivacyPreference(val title: String, val constraints: TaskRequestConstraints) {
    LocalRequired(title = "Local Only", constraints = TaskRequestConstraints(privacy = PrivacyEnum.LocalRequired)),
    LocalPreferred(title = "Prefer Local", constraints = TaskRequestConstraints(privacy = PrivacyEnum.LocalPreferred)),
    CloudAllowed(title = "Cloud Allowed", constraints = TaskRequestConstraints(privacy = PrivacyEnum.CloudAllowed)),
    CloudRequired(title = "Cloud Only", constraints = TaskRequestConstraints(privacy = PrivacyEnum.CloudRequired)),
}

internal data class ProviderBadge(
    val id: String,
    val label: String,
    val available: Boolean,
    val reason: String?,
)

internal sealed interface CapabilitiesState {
    data object Loading : CapabilitiesState
    data class Ready(val badges: List<ProviderBadge>) : CapabilitiesState
    data object Failed : CapabilitiesState
}

internal data class RouteDecision(
    val selectedProviderId: String?,
    val explanation: String,
    val rejectedProviderIds: List<String>,
    val fallbackProviderIds: List<String>,
)

internal data class DemoSettings(
    val endpointUrl: String,
    val model: String,
    val onnxModelSelection: DemoOnnxModelSelection,
)

internal data class AttemptMetadata(
    val runId: String,
    val providerUsed: String,
    val totalMs: Double?,
    val providerId: String?,
    val retryAfterMs: Long?,
) {
    val totalMsDescription: String
        get() = totalMs?.let { String.format(Locale.US, "%.0f", it) } ?: "n/a"
}

internal data class DemoResultState(
    val outputText: String,
    val metadata: AttemptMetadata,
)

internal data class DemoErrorState(
    val title: String,
    val body: String,
    val metadata: AttemptMetadata?,
)

internal sealed interface DemoExecutionOutcome {
    data class Success(
        val outputText: String,
        val metadata: AttemptMetadata,
    ) : DemoExecutionOutcome

    data class Failure(
        val error: DemoErrorState,
    ) : DemoExecutionOutcome
}

internal data class DemoUiState(
    val prompt: String = DemoDefaults.DEFAULT_PROMPT,
    val privacy: PrivacyPreference = PrivacyPreference.CloudAllowed,
    val cloudEndpointUrl: String = DemoDefaults.DEFAULT_CLOUD_ENDPOINT_URL,
    val cloudModel: String = DemoDefaults.DEFAULT_CLOUD_MODEL,
    val onnxModelSelection: DemoOnnxModelSelection = DemoDefaults.DEFAULT_ONNX_MODEL_SELECTION,
    val onnxDownloadState: DemoOnnxDownloadState = DemoOnnxDownloadState.Idle,
    val capabilitiesState: CapabilitiesState = CapabilitiesState.Loading,
    val result: DemoResultState? = null,
    val error: DemoErrorState? = null,
    val lastRouteDecision: RouteDecision? = null,
    val isRunning: Boolean = false,
) {
    val cloudSettingsHint: String
        get() = "The default emulator endpoint targets the local demo proxy through 10.0.2.2:8787. Physical devices need a LAN IP or remote server URL instead."

    val onnxSettingsHint: String
        get() = when (val state = onnxDownloadState) {
            DemoOnnxDownloadState.Idle ->
                if (onnxModelSelection.modelOption == null) {
                    "The fixture runtime echoes the prompt back instead of generating text."
                } else {
                    "Downloads automatically on first use and is cached afterward. Wi-Fi recommended."
                }

            is DemoOnnxDownloadState.Downloading ->
                "Downloading model... ${(state.progress * 100).toInt()}%. The fixture runtime is used until this completes."

            DemoOnnxDownloadState.Ready -> "Model downloaded and ready for on-device inference."

            is DemoOnnxDownloadState.Failed ->
                "Download failed: ${state.message}. Falls back to the fixture runtime until this succeeds; pick the model again to retry."
        }

    val canRun: Boolean
        get() = !isRunning && prompt.trim().isNotEmpty()

    fun toSettings(): DemoSettings = DemoSettings(
        endpointUrl = cloudEndpointUrl,
        model = cloudModel,
        onnxModelSelection = onnxModelSelection,
    )
}
