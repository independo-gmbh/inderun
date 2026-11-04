package app.independo.inderun.demo

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import app.independo.inderun.contracts.Outcome
import app.independo.inderun.contracts.Payload
import app.independo.inderun.contracts.PrepareRequest
import app.independo.inderun.contracts.PrepareVoice
import app.independo.inderun.contracts.Privacy
import app.independo.inderun.contracts.ProviderCapabilitySnapshot
import app.independo.inderun.contracts.StreamEvent
import app.independo.inderun.contracts.TaskKind
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.StreamRun
import app.independo.inderun.providers.onnx.AndroidOnnxRuntimeProvider
import app.independo.inderun.providers.systemspeech.AndroidSystemSpeechProvider
import app.independo.inderun.sdk.SpeakOptions
import app.independo.inderun.sdk.SpeechExecutionOptions
import app.independo.inderun.sdk.SpeechPlayback
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
    AndroidSystemSpeechProvider.DEFAULT_ID to "System Speech",
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

    private var activeStream: StreamRun? = null
    private var activePlayback: SpeechPlayback? = null

    /** When Stop was tapped, so the outcome can show how long stopping took (#251). */
    @Volatile
    private var stopTappedAtNanos: Long? = null

    init {
        viewModelScope.launch(dispatcher) {
            ensureSelectedOnnxModelDownloaded()
            refreshCapabilities()
            refreshSpeechVoices()
        }
    }

    fun updatePrompt(prompt: String) {
        _uiState.update { state ->
            state.copy(prompt = prompt, result = null, error = null, stream = null)
        }
    }

    fun updatePrivacy(privacy: PrivacyPreference) {
        _uiState.update { state ->
            state.copy(privacy = privacy, result = null, error = null, stream = null)
        }
    }

    fun updateCloudEndpointUrl(endpointUrl: String) {
        _uiState.update { state ->
            val updatedState = state.copy(cloudEndpointUrl = endpointUrl, result = null, error = null, stream = null)
            settingsStore.save(updatedState.toSettings())
            updatedState
        }
    }

    fun updateCloudModel(model: String) {
        _uiState.update { state ->
            val updatedState = state.copy(cloudModel = model, result = null, error = null, stream = null)
            settingsStore.save(updatedState.toSettings())
            updatedState
        }
    }

    fun updateOnnxModelSelection(selection: DemoOnnxModelSelection) {
        _uiState.update { state ->
            val updatedState = state.copy(onnxModelSelection = selection, result = null, error = null, stream = null)
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
            _uiState.update { it.copy(isRunning = true, result = null, error = null, stream = null) }

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

    /**
     * Drives Mode 2. Content events are appended for `content_delta` and replace the
     * panel for `content_snapshot`, because a provider streaming cumulative snapshots
     * would otherwise be rendered as duplicated prefixes. The terminal event ends the
     * run in all three cases, including `cancelled`, which is a normal outcome rather
     * than an error.
     */
    fun updateSpeechText(text: String) {
        _uiState.update { it.copy(speechText = text, speechOutcome = null) }
    }

    fun updateSpeechLocale(locale: String) {
        _uiState.update { it.copy(speechLocale = locale, speechVoiceId = null, speechOutcome = null) }
        refreshSpeechVoices()
    }

    fun updateSpeechVoice(id: String?) {
        _uiState.update { it.copy(speechVoiceId = id, speechOutcome = null) }
        prepareSelectedVoice()
    }

    /**
     * Picking a voice is the user's decision, so it may start the engine's download of that voice.
     * Optional: without it, the voice stays unavailable until the engine has it.
     */
    private fun prepareSelectedVoice() {
        val state = _uiState.value
        val voice = state.selectedSpeechVoice ?: return
        viewModelScope.launch(dispatcher) {
            val request = PrepareRequest(
                allowDownload = true,
                locale = state.speechLocale,
                tasks = listOf(TaskKind.TEXT_TO_SPEECH.rawValue),
                voice = PrepareVoice(gender = voice.gender, id = voice.id, providerId = voice.providerId),
            )
            try {
                runtime.prepareSpeech(request, state.toSettings(), viewModelScope)
            } catch (_: IndeRunException) {
                // Only a head start: the speak call reports what is wrong.
            }
            refreshSpeechVoices()
        }
    }

    /** Lists every voice of the selected locale. A selection that is gone falls back to routing. */
    private fun refreshSpeechVoices() {
        val state = _uiState.value
        viewModelScope.launch(dispatcher) {
            val voices = runtime.listVoices(state.speechLocale, state.toSettings())
            _uiState.update { current ->
                current.copy(
                    speechVoices = voices,
                    speechVoiceId = current.speechVoiceId?.takeIf { id -> voices.any { it.id == id } },
                )
            }
        }
    }

    /**
     * Speaks through the primary API: routing, cancellation and provenance are the engine's, and
     * this app never touches `TextToSpeech`.
     */
    fun speak() {
        val state = _uiState.value
        if (state.isSpeaking || state.speechText.isBlank()) {
            return
        }
        _uiState.update { it.copy(isSpeaking = true, speechOutcome = null) }
        stopTappedAtNanos = null
        viewModelScope.launch(dispatcher) {
            val outcome = try {
                val options = SpeakOptions(
                    state.speechText,
                    locale = state.speechLocale,
                    voice = state.selectedSpeechVoice?.asSpeechVoice(),
                    execution = SpeechExecutionOptions(privacy = Privacy.LocalRequired),
                )
                val playback = runtime.speak(options, state.toSettings(), viewModelScope)
                activePlayback = playback
                _uiState.update { it.copy(canStopSpeaking = true) }
                val ending = playback.result.await()
                val provenance = ending.provenance
                // Measurements for docs/verification/system-speech.md: the engine's first word,
                // and from the Stop tap to the run's ending.
                val timings = listOfNotNull(
                    ending.timing?.firstAudioMs?.let { "first word ${it.toInt()} ms" },
                    stopTappedAtNanos?.let { "stopped in ${(System.nanoTime() - it) / 1_000_000} ms" },
                )
                (
                    listOf(
                        "${ending.finishReason?.rawValue}",
                        ending.speech?.locale ?: state.speechLocale,
                        ending.speech?.voice?.name ?: "unknown voice",
                        "${provenance?.providerId}",
                        "${provenance?.locality?.rawValue}",
                    ) + timings
                    ).joinToString(" · ")
            } catch (error: IndeRunException) {
                "failed: ${error.errorClass.rawValue}: ${error.message}"
            }
            activePlayback = null
            _uiState.update { it.copy(isSpeaking = false, canStopSpeaking = false, speechOutcome = outcome) }
        }
    }

    /** Synthesizes silently, reads the audio back and releases it. */
    fun synthesizeSpeech() {
        val state = _uiState.value
        if (state.isSpeaking || state.speechText.isBlank()) {
            return
        }
        _uiState.update { it.copy(isSpeaking = true, speechOutcome = null) }
        viewModelScope.launch(dispatcher) {
            val outcome = try {
                val options = SpeakOptions(
                    state.speechText,
                    locale = state.speechLocale,
                    voice = state.selectedSpeechVoice?.asSpeechVoice(),
                    // The same posture as speak: a retrievable artifact must not leave the device either.
                    execution = SpeechExecutionOptions(privacy = Privacy.LocalRequired),
                )
                runtime.synthesizeSpeech(options, state.toSettings())
            } catch (error: IndeRunException) {
                "failed: ${error.errorClass.rawValue}: ${error.message}"
            }
            _uiState.update { it.copy(isSpeaking = false, speechOutcome = outcome) }
        }
    }

    /** Stops the audio. Idempotent; the run ends as cancelled, not as an error. */
    fun stopSpeaking() {
        if (stopTappedAtNanos == null) stopTappedAtNanos = System.nanoTime()
        activePlayback?.cancel("stopped from the demo app")
    }

    fun streamPrompt() {
        val state = _uiState.value
        if (!state.canStream || state.isStreaming) {
            return
        }

        viewModelScope.launch(dispatcher) {
            _uiState.update {
                it.copy(isStreaming = true, result = null, error = null, stream = DemoStreamState())
            }

            val current = _uiState.value
            when (val start = runtime.stream(current.prompt.trim(), current.privacy, current.toSettings())) {
                is DemoStreamStart.Refused ->
                    _uiState.update { it.copy(isStreaming = false, stream = null, error = start.error) }

                is DemoStreamStart.Started -> {
                    activeStream = start.run
                    try {
                        start.run.events.collect(::applyStreamEvent)
                    } catch (error: Throwable) {
                        _uiState.update { it.copy(stream = it.stream?.copy(detail = error.localizedMessage ?: error.toString())) }
                    } finally {
                        activeStream = null
                        _uiState.update { it.copy(isStreaming = false) }
                    }
                }
            }

            _uiState.update { it.copy(lastRouteDecision = runtime.lastRouteDecision()) }
            refreshCapabilities()
        }
    }

    /** Idempotent, like `StreamRun.cancel` itself: repeated taps are harmless. */
    fun cancelStream() {
        activeStream?.cancel("cancelled from the demo app")
    }

    private fun applyStreamEvent(event: StreamEvent) {
        _uiState.update { state ->
            val stream = state.stream ?: DemoStreamState()
            val updated = when (event.type) {
                "content_delta" -> stream.copy(text = stream.text + event.payload?.text.orEmpty())
                "content_snapshot" -> stream.copy(text = event.payload?.text.orEmpty())
                "terminal" -> stream.copy(
                    text = event.payload?.finalText ?: event.payload?.partialText ?: stream.text,
                    outcome = event.payload?.outcome,
                    detail = terminalDetail(event.payload),
                    providerUsed = event.payload?.telemetry?.providerUsed,
                )
                // The event type set is open and additive, so an unrecognized one is
                // ignored rather than treated as an error.
                else -> stream
            }
            state.copy(stream = updated)
        }
    }

    private fun terminalDetail(payload: Payload?): String? = when (payload?.outcome) {
        Outcome.Completed -> payload.finishReason?.rawValue?.let { "finish reason: $it" }
        Outcome.Cancelled -> payload.reason?.let { "reason: $it" }
        Outcome.Error -> payload.error?.let { "${it.errorClass.rawValue}: ${it.message}" }
        null -> null
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
