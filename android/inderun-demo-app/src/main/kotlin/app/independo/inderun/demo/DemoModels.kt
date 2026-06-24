package app.independo.inderun.demo

import app.independo.inderun.contracts.PrivacyEnum
import app.independo.inderun.contracts.TaskRequestConstraints
import java.util.Locale

internal object DemoDefaults {
    const val defaultCloudEndpointUrl = "http://10.0.2.2:8787/api/inderun/openai-responses"
    const val defaultCloudModel = "gpt-5.2"
    const val defaultPrompt = "Summarize when on-device AI is preferable to cloud AI in two short sentences."
}

internal enum class DemoExecutionMode(
    val title: String,
    val requestConstraints: TaskRequestConstraints,
    val providerFallback: String
) {
    OnDevice(
        title = "On Device",
        requestConstraints = TaskRequestConstraints(privacy = PrivacyEnum.LocalRequired),
        providerFallback = "on_device"
    ),
    Cloud(
        title = "Cloud",
        requestConstraints = TaskRequestConstraints(privacy = PrivacyEnum.CloudRequired),
        providerFallback = "cloud"
    )
}

internal enum class DemoAvailabilityKind {
    Checking,
    Available,
    Downloadable,
    Downloading,
    Unavailable
}

internal data class DemoAvailabilityState(
    val badgeTitle: String,
    val kind: DemoAvailabilityKind,
    val message: String
) {
    companion object {
        fun checking(message: String) = DemoAvailabilityState("Checking", DemoAvailabilityKind.Checking, message)
        fun available(message: String) = DemoAvailabilityState("Available", DemoAvailabilityKind.Available, message)
        fun downloadable(message: String) = DemoAvailabilityState("Downloadable", DemoAvailabilityKind.Downloadable, message)
        fun downloading(message: String) = DemoAvailabilityState("Downloading", DemoAvailabilityKind.Downloading, message)
        fun unavailable(message: String) = DemoAvailabilityState("Unavailable", DemoAvailabilityKind.Unavailable, message)
    }
}

internal data class DemoSettings(
    val endpointUrl: String,
    val model: String
)

internal data class AttemptMetadata(
    val runId: String,
    val providerUsed: String,
    val totalMs: Double?,
    val providerId: String?,
    val retryAfterMs: Long?
) {
    val totalMsDescription: String
        get() = totalMs?.let { String.format(Locale.US, "%.0f", it) } ?: "n/a"
}

internal data class DemoResultState(
    val outputText: String,
    val metadata: AttemptMetadata
)

internal data class DemoErrorState(
    val title: String,
    val body: String,
    val metadata: AttemptMetadata?
)

internal data class DemoAvailabilitySnapshot(
    val onDevice: DemoAvailabilityState,
    val cloud: DemoAvailabilityState
)

internal sealed interface DemoExecutionOutcome {
    data class Success(
        val outputText: String,
        val metadata: AttemptMetadata
    ) : DemoExecutionOutcome

    data class Failure(
        val error: DemoErrorState,
        val onDeviceStatusOverride: DemoAvailabilityState? = null,
        val cloudStatusOverride: DemoAvailabilityState? = null
    ) : DemoExecutionOutcome
}

internal data class DemoUiState(
    val prompt: String = DemoDefaults.defaultPrompt,
    val executionMode: DemoExecutionMode = DemoExecutionMode.OnDevice,
    val cloudEndpointUrl: String = DemoDefaults.defaultCloudEndpointUrl,
    val cloudModel: String = DemoDefaults.defaultCloudModel,
    val onDeviceStatus: DemoAvailabilityState = DemoAvailabilityState.checking(
        "Checking whether Android ML Kit GenAI is usable right now."
    ),
    val cloudStatus: DemoAvailabilityState = DemoAvailabilityState.checking(
        "Checking cloud configuration and endpoint reachability."
    ),
    val result: DemoResultState? = null,
    val error: DemoErrorState? = null,
    val isRunning: Boolean = false
) {
    val executionModeDescription: String
        get() = when (executionMode) {
            DemoExecutionMode.OnDevice ->
                "Use Android ML Kit GenAI through the IndeRun Android provider. This depends on Gemini Nano, AI Core, and device support."

            DemoExecutionMode.Cloud ->
                "Use the IndeRun OpenAI-compatible provider against the configured endpoint. For emulator testing, point this at the standalone demo proxy."
        }

    val cloudSettingsHint: String
        get() = "The default emulator endpoint targets the local demo proxy through 10.0.2.2:8787. Physical devices need a LAN IP or remote server URL instead."

    val runButtonTitle: String
        get() = when (executionMode) {
            DemoExecutionMode.OnDevice -> "Run On Device"
            DemoExecutionMode.Cloud -> "Run Through Cloud"
        }

    val canRun: Boolean
        get() {
            if (isRunning || prompt.trim().isEmpty()) {
                return false
            }

            if (executionMode == DemoExecutionMode.OnDevice) {
                return true
            }

            return cloudModel.trim().isNotEmpty() &&
                cloudEndpointUrl.trim().isNotEmpty() &&
                isValidEndpointUrl(cloudEndpointUrl.trim())
        }
}
