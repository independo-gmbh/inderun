package app.independo.inderun.demo

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import app.independo.inderun.contracts.AttemptOutcome
import app.independo.inderun.contracts.Privacy
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.providers.systemspeech.AndroidSystemSpeechProvider
import app.independo.inderun.sdk.SpeakOptions
import app.independo.inderun.sdk.SpeechExecutionOptions
import app.independo.inderun.sdk.SpeechPlayback
import app.independo.inderun.sdk.SpeechVoiceInfo
import app.independo.inderun.sdk.SpokenSpeech
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import org.json.JSONObject

/** The lab's own engine: system speech plus one neural provider per installed entry (see [AndroidVoicesLabRuntime]). */
internal interface VoicesLabRuntime {
    /** Rebuilds the engine for these installed entries; also registers `voices-lab:<id>` per entry. */
    fun install(entries: List<CatalogEntry>)

    suspend fun listVoices(locale: String?): List<SpeechVoiceInfo>

    suspend fun speak(options: SpeakOptions, scope: CoroutineScope): SpeechPlayback

    /** Loads the model ahead of the first run. Returns one line per failed preparation item; empty means ready. */
    suspend fun warm(entry: CatalogEntry, scope: CoroutineScope): List<String>
}

internal data class LabPreset(val id: String, val locale: String, val text: String)

internal data class VoicesLabState(
    val started: Boolean = false,
    /** True while the installed files are being checked at start. */
    val isChecking: Boolean = false,
    val loadError: String? = null,
    val installable: List<CatalogEntry> = emptyList(),
    /** Entries the catalog lists but this app cannot download, with the reason. */
    val unavailable: List<Pair<CatalogEntry, String>> = emptyList(),
    val installedIds: Set<String> = emptySet(),
    /** An entry id, or [VoicesLabViewModel.CONTROL]. */
    val selected: String = VoicesLabViewModel.CONTROL,
    val locale: String = "de-DE",
    val text: String = DemoDefaults.DEFAULT_SPEECH_TEXT,
    val presets: List<LabPreset> = emptyList(),
    val voices: List<SpeechVoiceInfo> = emptyList(),
    val voiceKey: String? = null,
    val pendingConsent: ConsentPrompt? = null,
    val progress: Pair<Long, Long>? = null,
    val isDownloading: Boolean = false,
    val isWarming: Boolean = false,
    val isSpeaking: Boolean = false,
    val status: String? = null,
    val card: List<Pair<String, String>> = emptyList(),
) {
    val isControl: Boolean get() = selected == VoicesLabViewModel.CONTROL
    val selectedEntry: CatalogEntry? get() = installable.firstOrNull { it.id == selected }

    /** Voices of the selected target: the OS voices for the control, else the entry's neural voices. */
    val currentVoices: List<SpeechVoiceInfo>
        get() {
            val wanted = if (isControl) AndroidSystemSpeechProvider.DEFAULT_ID else selectedEntry?.let { neuralProviderId(it.id) }
            return voices.filter { it.providerId == wanted }
        }

    val selectedVoice: SpeechVoiceInfo? get() = currentVoices.firstOrNull { voiceKeyOf(it) == voiceKey }

    val canSpeakNeural: Boolean get() = selectedEntry?.let { it.id in installedIds } == true
}

internal fun voiceKeyOf(voice: SpeechVoiceInfo): String = "${voice.providerId}|${voice.id}|${voice.locale}"

/** What the status card needs from a finished run. */
internal data class SpokenSummary(
    val providerId: String?,
    val failedNeuralAttempt: String?,
    val voiceName: String?,
    val locale: String?,
    val locality: String?,
    val finishReason: String?,
    val firstAudioMs: Long?,
)

internal fun SpokenSpeech.summary(neuralProviderId: String?): SpokenSummary = SpokenSummary(
    providerId = provenance?.providerId,
    failedNeuralAttempt = provenance?.attempts
        ?.firstOrNull { it.providerId == neuralProviderId && it.outcome != AttemptOutcome.Succeeded }
        ?.let { attempt -> "${attempt.outcome.rawValue}${attempt.errorClass?.let { ", ${it.rawValue}" }.orEmpty()}" },
    voiceName = speech?.voice?.name,
    locale = speech?.locale,
    locality = provenance?.locality?.rawValue,
    finishReason = finishReason?.rawValue,
    firstAudioMs = timing?.firstAudioMs?.toLong(),
)

/**
 * The card describes the provider that actually spoke, never the one that was asked: a neural
 * request answered by the OS voice reads "fell back to OS voice".
 */
internal fun statusCard(
    summary: SpokenSummary,
    askedNeural: Boolean,
    entry: CatalogEntry?,
    requestedLocale: String,
    chosenVoiceName: String?,
): Pair<String, List<Pair<String, String>>> {
    val neuralId = entry?.let { neuralProviderId(it.id) }
    val neuralSpoke = askedNeural && summary.providerId == neuralId
    val fellBack = askedNeural && !neuralSpoke
    val note = if (fellBack) {
        "fell back to OS voice" + when {
            summary.failedNeuralAttempt != null -> " (neural: ${summary.failedNeuralAttempt})"
            summary.providerId == null -> " (provider not reported)"
            else -> ""
        }
    } else {
        null
    }
    val textOnnx = entry?.files?.firstOrNull { it.path == "text.onnx" }
    val rows = listOfNotNull(
        "Provider" to (summary.providerId ?: if (askedNeural) "not reported" else AndroidSystemSpeechProvider.DEFAULT_ID),
        note?.let { "Result" to it },
        when {
            neuralSpoke -> "Model" to "${entry!!.id} (${entry.variant})"
            fellBack -> null
            else -> "Model" to "OS TTS (control)"
        },
        if (neuralSpoke && textOnnx != null) "Package checksum" to "text.onnx sha256:${textOnnx.sha256.take(12)}…" else null,
        "Voice" to (summary.voiceName ?: if (fellBack) "automatic" else (chosenVoiceName ?: "automatic")),
        "Resolved locale" to (summary.locale ?: requestedLocale),
        "Locality" to (summary.locality ?: "unknown"),
        when {
            neuralSpoke -> "Runtime" to "onnxruntime-android (CPU)"
            fellBack -> null
            else -> "Runtime" to "Android TextToSpeech"
        },
        "Delivery" to "playback (generateSpeech would return an artifact)",
        "Ended" to (summary.finishReason ?: "stop"),
        summary.firstAudioMs?.let { "First audio" to "$it ms" },
    )
    val line = note?.let { "$it: ${summary.finishReason ?: "stop"}" }
        ?: "${if (askedNeural) "neural" else "OS voice"}: ${summary.finishReason ?: "stop"}"
    return line to rows
}

/** The A/B status when the neural leg was answered by another provider: the control would compare OS with OS. */
internal fun comparisonInvalidLine(summary: SpokenSummary): String = "comparison invalid: neural fell back to ${summary.providerId ?: "a provider that was not reported"}" +
    summary.failedNeuralAttempt?.let { " (neural: $it)" }.orEmpty() +
    "; the OS control was skipped"

/**
 * The opt-in Voices lab (#260). Nothing happens until [start] (the screen calls it only when the
 * demo's "Voices lab" setting is on): no catalog read, no provider registration, no storage access.
 * Installation is read-only at start; files are created only after the person consents.
 */
internal class VoicesLabViewModel(
    private val catalogSource: () -> String,
    private val corpusSource: () -> String?,
    private val downloader: DemoNeuralModelDownloader,
    private val runtime: VoicesLabRuntime,
    private val dispatcher: CoroutineDispatcher = Dispatchers.Main,
) : ViewModel() {
    private val _state = MutableStateFlow(VoicesLabState())
    val state: StateFlow<VoicesLabState> = _state.asStateFlow()

    private var downloadJob: Job? = null
    private var startJob: Job? = null
    private var consentAnswer: CompletableDeferred<Boolean>? = null
    private var playback: SpeechPlayback? = null
    private var stopRequested = false
    private var lastJob: (suspend () -> Unit)? = null

    fun start() {
        if (_state.value.started) return
        _state.update { it.copy(started = true, isChecking = true) }
        startJob = viewModelScope.launch(dispatcher) {
            try {
                load()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                _state.update { it.copy(isChecking = false, loadError = "could not start the Voices lab: ${error.message ?: error::class.simpleName}") }
            }
        }
    }

    private suspend fun load() {
        run {
            val entries = try {
                NeuralCatalogParser.parse(catalogSource())
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                _state.update { it.copy(isChecking = false, loadError = "could not read the model catalog: ${error.message}") }
                return
            }
            val installable = entries.filter { it.isInstallable }
            val unavailable = entries.filter { !it.isInstallable }
                .map { it to (it.reviewNotes ?: it.reviewStatus) }
            val installed = installable.filter { downloader.isInstalled(it) }
            runtime.install(installed)
            val presets = runCatching { parsePresets(corpusSource()) }.getOrDefault(emptyList())
            val first = presets.firstOrNull { it.locale == "de-DE" } ?: presets.firstOrNull()
            _state.update {
                it.copy(
                    isChecking = false,
                    installable = installable,
                    unavailable = unavailable,
                    installedIds = installed.map { entry -> entry.id }.toSet(),
                    selected = installed.firstOrNull()?.id ?: installable.firstOrNull()?.id ?: CONTROL,
                    presets = presets,
                    text = first?.text ?: it.text,
                    locale = first?.locale?.takeIf { l -> l in LANGUAGES } ?: it.locale,
                )
            }
            refreshVoices()
        }
    }

    private fun parsePresets(json: String?): List<LabPreset> {
        if (json == null) return emptyList()
        val array = JSONObject(json).getJSONArray("utterances")
        return (0 until array.length()).map { array.getJSONObject(it) }
            .filter { it.optString("expect") != "refuse" }
            .map { LabPreset(it.getString("id"), it.getString("locale"), it.getString("text")) }
    }

    fun updateText(text: String) = _state.update { it.copy(text = text) }

    fun selectPreset(id: String) {
        val preset = _state.value.presets.firstOrNull { it.id == id } ?: return
        _state.update { it.copy(text = preset.text, locale = preset.locale.takeIf { l -> l in LANGUAGES } ?: it.locale) }
        refreshVoices()
    }

    fun updateLocale(locale: String) {
        _state.update { it.copy(locale = locale) }
        refreshVoices()
    }

    fun selectModel(id: String) {
        _state.update { it.copy(selected = id, voiceKey = null) }
        applyDefaultVoice()
    }

    fun selectVoice(key: String?) = _state.update { it.copy(voiceKey = key) }

    private fun applyDefaultVoice() {
        _state.update { s ->
            if (s.isControl) s.copy(voiceKey = null) else s.copy(voiceKey = s.currentVoices.firstOrNull()?.let(::voiceKeyOf))
        }
    }

    private fun refreshVoices() {
        viewModelScope.launch(dispatcher) {
            val locale = _state.value.locale
            val neural = runCatching { runtime.listVoices(null) }.getOrDefault(emptyList())
                .filter { it.providerId != AndroidSystemSpeechProvider.DEFAULT_ID }
            val control = runCatching { runtime.listVoices(locale) }.getOrDefault(emptyList())
                .filter { it.providerId == AndroidSystemSpeechProvider.DEFAULT_ID }
            _state.update { it.copy(voices = neural + control) }
            applyDefaultVoice()
        }
    }

    // --- Download ---------------------------------------------------------------------------

    /** Downloads the selected entry after consent, or warms an installed one. */
    fun downloadOrWarm() {
        val entry = _state.value.selectedEntry ?: return
        if (_state.value.isDownloading || _state.value.isWarming) return
        val warming = entry.id in _state.value.installedIds
        _state.update { it.copy(isDownloading = !warming, isWarming = warming, status = null, progress = null) }
        downloadJob = viewModelScope.launch(dispatcher) {
            try {
                if (warming) {
                    _state.update { it.copy(status = "Warming up ${entry.id}…") }
                    val failed = runtime.warm(entry, viewModelScope)
                    _state.update {
                        it.copy(status = if (failed.isEmpty()) "${entry.id} is ready." else "Warm-up failed: ${failed.joinToString("; ")}")
                    }
                    return@launch
                }
                val result = downloader.download(
                    entry,
                    consent = ::askConsent,
                    onProgress = { done, total -> _state.update { it.copy(progress = done to total) } },
                )
                when (result) {
                    NeuralDownloadResult.Declined ->
                        _state.update { it.copy(status = "Download declined; nothing was requested.") }

                    NeuralDownloadResult.Installed -> {
                        val ids = _state.value.installedIds + entry.id
                        runtime.install(_state.value.installable.filter { it.id in ids })
                        _state.update { it.copy(installedIds = ids, status = "${entry.id} installed.") }
                        refreshVoices()
                    }
                }
            } catch (error: CancellationException) {
                _state.update {
                    it.copy(status = if (warming) "Warm-up cancelled." else "Download cancelled; verified files are kept, so a retry resumes.")
                }
                throw error
            } catch (error: NeuralDownloadException) {
                _state.update { it.copy(status = error.message) }
            } catch (error: Exception) {
                _state.update { it.copy(status = "failed: ${error.message ?: error::class.simpleName}") }
            } finally {
                _state.update { it.copy(isDownloading = false, isWarming = false, progress = null, pendingConsent = null) }
            }
        }
    }

    fun cancelDownload() {
        // A pending consent counts as declined, so nothing is requested.
        answerConsent(false)
        downloadJob?.cancel()
    }

    /** Stops everything the lab started: called when the lab is switched off, and when the ViewModel is cleared. */
    fun shutdown() {
        startJob?.cancel()
        cancelDownload()
        stop()
        _state.update { it.copy(started = false, isChecking = false) }
    }

    override fun onCleared() {
        cancelDownload()
        stop()
    }

    private suspend fun askConsent(prompt: ConsentPrompt): Boolean {
        val answer = CompletableDeferred<Boolean>()
        consentAnswer = answer
        _state.update { it.copy(pendingConsent = prompt) }
        return answer.await()
    }

    fun answerConsent(accepted: Boolean) {
        _state.update { it.copy(pendingConsent = null) }
        consentAnswer?.complete(accepted)
        consentAnswer = null
    }

    // --- Speaking ---------------------------------------------------------------------------

    fun speakSelected() = launchJob { if (_state.value.isControl) speakOnce(neural = false) else speakOnce(neural = true) }

    /** Neural voice first, then the OS control, one after the other; a neural fallback ends the comparison. */
    fun compareAB() = launchJob {
        if (speakOnce(neural = true, comparing = true) && !stopRequested) speakOnce(neural = false)
    }

    fun repeatLast() {
        val job = lastJob ?: return
        launchJob(remember = false, job = job)
    }

    fun stop() {
        stopRequested = true
        playback?.cancel("stopped from the demo")
    }

    private fun launchJob(remember: Boolean = true, job: suspend () -> Unit) {
        if (_state.value.isSpeaking) return
        stopRequested = false
        if (remember) lastJob = job
        _state.update { it.copy(isSpeaking = true) }
        viewModelScope.launch(dispatcher) {
            try {
                job()
            } catch (error: CancellationException) {
                throw error
            } catch (error: IndeRunException) {
                _state.update { it.copy(status = "failed: ${error.errorClass.rawValue}: ${error.message}") }
            } catch (error: Exception) {
                _state.update { it.copy(status = "failed: ${error.message ?: error::class.simpleName}") }
            } finally {
                playback = null
                _state.update { it.copy(isSpeaking = false) }
            }
        }
    }

    /**
     * One utterance; fills the status card. Returns false when nothing was spoken or a neural request
     * was answered by another provider; for an A/B run ([comparing]) the status then says so.
     */
    private suspend fun speakOnce(neural: Boolean, comparing: Boolean = false): Boolean {
        val state = _state.value
        val entry = state.selectedEntry
        if (neural && !state.canSpeakNeural) {
            _state.update { it.copy(status = "Download the model first.") }
            return false
        }
        // The A/B control uses the OS voice list; a neural voice choice does not carry over.
        val chosen = if (neural == !state.isControl) state.selectedVoice else null
        val profile = if (neural) labProfileName(entry!!.id) else CONTROL_PROFILE
        val options = SpeakOptions(
            state.text,
            locale = state.locale,
            voice = chosen?.asSpeechVoice(),
            model = profile,
            execution = SpeechExecutionOptions(privacy = Privacy.LocalRequired),
        )
        _state.update { it.copy(status = if (neural) "Speaking (neural)…" else "Speaking (OS voice)…") }
        val started = runtime.speak(options, viewModelScope)
        playback = started
        if (stopRequested) started.cancel("stopped from the demo")
        val done = started.result.await()
        playback = null
        val summary = done.summary(entry?.let { neuralProviderId(it.id) })
        val (line, rows) = statusCard(
            summary,
            askedNeural = neural,
            entry = entry,
            requestedLocale = state.locale,
            chosenVoiceName = chosen?.name,
        )
        val fellBack = neural && summary.providerId != neuralProviderId(entry!!.id)
        _state.update { it.copy(status = if (fellBack && comparing) comparisonInvalidLine(summary) else line, card = rows) }
        return !fellBack
    }

    companion object {
        const val CONTROL = "control"
        const val CONTROL_PROFILE = "voices-lab:control"
        val LANGUAGES = listOf("de-DE", "de-AT", "en-US", "en-GB")

        fun factory(
            catalogSource: () -> String,
            corpusSource: () -> String?,
            downloader: DemoNeuralModelDownloader,
            runtime: () -> VoicesLabRuntime,
        ): ViewModelProvider.Factory = object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T = VoicesLabViewModel(catalogSource, corpusSource, downloader, runtime()) as T
        }
    }
}
