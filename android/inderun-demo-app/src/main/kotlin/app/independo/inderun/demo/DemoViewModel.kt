package app.independo.inderun.demo

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal class DemoViewModel(
    private val settingsStore: DemoSettingsStore,
    private val runtime: DemoRuntime,
    private val dispatcher: CoroutineDispatcher = Dispatchers.Main
) : ViewModel() {
    private val _uiState = MutableStateFlow(
        DemoUiState().copy(
            cloudEndpointUrl = settingsStore.load().endpointUrl,
            cloudModel = settingsStore.load().model
        )
    )

    val uiState: StateFlow<DemoUiState> = _uiState.asStateFlow()

    init {
        refreshAvailability()
    }

    fun updatePrompt(prompt: String) {
        _uiState.update { state ->
            state.copy(
                prompt = prompt,
                result = null,
                error = null
            )
        }
    }

    fun updateExecutionMode(mode: DemoExecutionMode) {
        _uiState.update { state ->
            state.copy(
                executionMode = mode,
                result = null,
                error = null
            )
        }
    }

    fun updateCloudEndpointUrl(endpointUrl: String) {
        _uiState.update { state ->
            val updatedState = state.copy(
                cloudEndpointUrl = endpointUrl,
                result = null,
                error = null,
                cloudStatus = DemoAvailabilityState.checking(
                    "Cloud settings changed. Refresh status to re-check reachability."
                )
            )
            settingsStore.save(updatedState.toSettings())
            updatedState
        }
    }

    fun updateCloudModel(model: String) {
        _uiState.update { state ->
            val updatedState = state.copy(
                cloudModel = model,
                result = null,
                error = null,
                cloudStatus = DemoAvailabilityState.checking(
                    "Cloud settings changed. Refresh status to re-check reachability."
                )
            )
            settingsStore.save(updatedState.toSettings())
            updatedState
        }
    }

    fun refreshAvailability() {
        viewModelScope.launch(dispatcher) {
            _uiState.update { state ->
                state.copy(
                    onDeviceStatus = DemoAvailabilityState.checking(
                        "Checking whether Android ML Kit GenAI is usable right now."
                    ),
                    cloudStatus = DemoAvailabilityState.checking(
                        "Checking cloud configuration and endpoint reachability."
                    )
                )
            }

            val snapshot = runtime.refreshAvailability(_uiState.value.toSettings())
            _uiState.update { state ->
                state.copy(
                    onDeviceStatus = snapshot.onDevice,
                    cloudStatus = snapshot.cloud
                )
            }
        }
    }

    fun runPrompt() {
        val state = _uiState.value
        if (!state.canRun) {
            return
        }

        viewModelScope.launch(dispatcher) {
            _uiState.update { current ->
                current.copy(
                    isRunning = true,
                    result = null,
                    error = null
                )
            }

            when (val outcome = runtime.run(
                prompt = _uiState.value.prompt.trim(),
                executionMode = _uiState.value.executionMode,
                settings = _uiState.value.toSettings()
            )) {
                is DemoExecutionOutcome.Success -> {
                    _uiState.update { current ->
                        current.copy(
                            isRunning = false,
                            result = DemoResultState(
                                outputText = outcome.outputText,
                                metadata = outcome.metadata
                            ),
                            error = null,
                            onDeviceStatus = when (current.executionMode) {
                                DemoExecutionMode.OnDevice ->
                                    DemoAvailabilityState.available(
                                        "The last on-device request completed successfully."
                                    )

                                DemoExecutionMode.Cloud -> current.onDeviceStatus
                            },
                            cloudStatus = when (current.executionMode) {
                                DemoExecutionMode.Cloud ->
                                    DemoAvailabilityState.available(
                                        "The configured cloud route completed the last request successfully."
                                    )

                                DemoExecutionMode.OnDevice -> current.cloudStatus
                            }
                        )
                    }
                }

                is DemoExecutionOutcome.Failure -> {
                    _uiState.update { current ->
                        current.copy(
                            isRunning = false,
                            result = null,
                            error = outcome.error,
                            onDeviceStatus = outcome.onDeviceStatusOverride ?: current.onDeviceStatus,
                            cloudStatus = outcome.cloudStatusOverride ?: current.cloudStatus
                        )
                    }
                }
            }
        }
    }

    companion object {
        fun factory(
            settingsStore: DemoSettingsStore,
            runtime: DemoRuntime
        ): ViewModelProvider.Factory {
            return object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T {
                    return DemoViewModel(settingsStore, runtime) as T
                }
            }
        }
    }
}

private fun DemoUiState.toSettings(): DemoSettings {
    return DemoSettings(
        endpointUrl = cloudEndpointUrl,
        model = cloudModel
    )
}
