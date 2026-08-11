package app.independo.inderun.demo

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import app.independo.inderun.core.ProviderCapabilitySnapshot
import app.independo.inderun.providers.onnx.AndroidOnnxRuntimeProvider
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

private val providerLabels: Map<String, String> = mapOf(
    "android_mlkit_genai" to "On-Device (ML Kit)",
    "openai_compatible_cloud" to "Cloud",
    AndroidOnnxRuntimeProvider.DEFAULT_ID to "ONNX Local",
)

internal class DemoViewModel(
    private val settingsStore: DemoSettingsStore,
    private val runtime: DemoRuntime,
    private val onnxDownloader: DemoOnnxDownloader,
    private val dispatcher: CoroutineDispatcher = Dispatchers.Main,
) : ViewModel() {
    private val _uiState = MutableStateFlow(
        DemoUiState().let { state ->
            val settings = settingsStore.load()
            state.copy(
                cloudEndpointUrl = settings.endpointUrl,
                cloudModel = settings.model,
                onnxModelSelection = settings.onnxModelSelection,
            )
        },
    )

    val uiState: StateFlow<DemoUiState> = _uiState.asStateFlow()

    init {
        viewModelScope.launch(dispatcher) {
            ensureSelectedOnnxModelDownloaded()
            refreshCapabilities()
        }
    }

    fun updatePrompt(prompt: String) {
        _uiState.update { state ->
            state.copy(prompt = prompt, result = null, error = null)
        }
    }

    fun updatePrivacy(privacy: PrivacyPreference) {
        _uiState.update { state ->
            state.copy(privacy = privacy, result = null, error = null)
        }
    }

    fun updateCloudEndpointUrl(endpointUrl: String) {
        _uiState.update { state ->
            val updatedState = state.copy(cloudEndpointUrl = endpointUrl, result = null, error = null)
            settingsStore.save(updatedState.toSettings())
            updatedState
        }
    }

    fun updateCloudModel(model: String) {
        _uiState.update { state ->
            val updatedState = state.copy(cloudModel = model, result = null, error = null)
            settingsStore.save(updatedState.toSettings())
            updatedState
        }
    }

    fun updateOnnxModelSelection(selection: DemoOnnxModelSelection) {
        _uiState.update { state ->
            val updatedState = state.copy(onnxModelSelection = selection, result = null, error = null)
            settingsStore.save(updatedState.toSettings())
            updatedState
        }
        viewModelScope.launch(dispatcher) {
            ensureSelectedOnnxModelDownloaded()
        }
    }

    /**
     * Kicks off (or resumes) the download for the selected model, if any and not already cached.
     * Called on selection change and on ViewModel init alongside [refreshCapabilities].
     */
    suspend fun ensureSelectedOnnxModelDownloaded() {
        val model = _uiState.value.onnxModelSelection.modelOption
        if (model == null) {
            _uiState.update { it.copy(onnxDownloadState = DemoOnnxDownloadState.Idle) }
            return
        }

        if (onnxDownloader.isDownloaded(model)) {
            _uiState.update { it.copy(onnxDownloadState = DemoOnnxDownloadState.Ready) }
            return
        }

        _uiState.update { it.copy(onnxDownloadState = DemoOnnxDownloadState.Downloading(progress = 0f)) }

        try {
            onnxDownloader.download(model) { progress ->
                _uiState.update { it.copy(onnxDownloadState = DemoOnnxDownloadState.Downloading(progress = progress)) }
            }
            _uiState.update { it.copy(onnxDownloadState = DemoOnnxDownloadState.Ready) }
            refreshCapabilities()
        } catch (error: Throwable) {
            _uiState.update {
                it.copy(onnxDownloadState = DemoOnnxDownloadState.Failed(error.localizedMessage ?: error.toString()))
            }
        }
    }

    fun refreshCapabilities() {
        viewModelScope.launch(dispatcher) {
            _uiState.update { it.copy(capabilitiesState = CapabilitiesState.Loading) }

            try {
                val snapshots = runtime.checkCapabilities(_uiState.value.toSettings())
                val usingRealOnnxModel = _uiState.value.onnxModelSelection.modelOption
                    ?.let { onnxDownloader.isDownloaded(it) }
                    ?: false
                val badges = snapshots.map { snapshot -> snapshot.toBadge(usingRealOnnxModel) }
                _uiState.update { it.copy(capabilitiesState = CapabilitiesState.Ready(badges)) }
            } catch (error: Throwable) {
                _uiState.update { it.copy(capabilitiesState = CapabilitiesState.Failed) }
            }
        }
    }

    fun runPrompt() {
        val state = _uiState.value
        if (!state.canRun) {
            return
        }

        viewModelScope.launch(dispatcher) {
            _uiState.update { it.copy(isRunning = true, result = null, error = null) }

            val current = _uiState.value
            when (val outcome = runtime.run(current.prompt.trim(), current.privacy, current.toSettings())) {
                is DemoExecutionOutcome.Success -> {
                    _uiState.update {
                        it.copy(
                            isRunning = false,
                            result = DemoResultState(outputText = outcome.outputText, metadata = outcome.metadata),
                            error = null,
                        )
                    }
                }

                is DemoExecutionOutcome.Failure -> {
                    _uiState.update {
                        it.copy(isRunning = false, result = null, error = outcome.error)
                    }
                }
            }

            _uiState.update { it.copy(lastRouteDecision = runtime.lastRouteDecision()) }
            refreshCapabilities()
        }
    }

    companion object {
        fun factory(
            settingsStore: DemoSettingsStore,
            runtime: DemoRuntime,
            onnxDownloader: DemoOnnxDownloader,
        ): ViewModelProvider.Factory = object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T = DemoViewModel(settingsStore, runtime, onnxDownloader) as T
        }
    }
}

private fun ProviderCapabilitySnapshot.toBadge(usingRealOnnxModel: Boolean): ProviderBadge {
    var label = providerLabels[providerId] ?: descriptor.type.toString()
    if (providerId == AndroidOnnxRuntimeProvider.DEFAULT_ID && !usingRealOnnxModel) {
        label += " (fixture)"
    }
    return ProviderBadge(
        id = providerId,
        label = label,
        available = capabilities.available,
        reason = capabilities.reason,
    )
}
