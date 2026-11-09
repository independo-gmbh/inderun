package app.independo.inderun.demo

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

/** The Voices lab section (#260). Composing it is what starts the lab: the host shows it only when the setting is on. */
@Composable
internal fun VoicesLabScreen(viewModel: VoicesLabViewModel) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { viewModel.start() }
    VoicesLabContent(
        state = state,
        onTextChange = viewModel::updateText,
        onPresetChange = viewModel::selectPreset,
        onLocaleChange = viewModel::updateLocale,
        onModelChange = viewModel::selectModel,
        onVoiceChange = viewModel::selectVoice,
        onDownloadClick = viewModel::downloadOrWarm,
        onCancelDownloadClick = viewModel::cancelDownload,
        onConsent = viewModel::answerConsent,
        onSpeakClick = viewModel::speakSelected,
        onStopClick = viewModel::stop,
        onRepeatClick = viewModel::repeatLast,
        onCompareClick = viewModel::compareAB,
    )
}

@Composable
internal fun VoicesLabContent(
    state: VoicesLabState,
    onTextChange: (String) -> Unit,
    onPresetChange: (String) -> Unit,
    onLocaleChange: (String) -> Unit,
    onModelChange: (String) -> Unit,
    onVoiceChange: (String?) -> Unit,
    onDownloadClick: () -> Unit,
    onCancelDownloadClick: () -> Unit,
    onConsent: (Boolean) -> Unit,
    onSpeakClick: () -> Unit,
    onStopClick: () -> Unit,
    onRepeatClick: () -> Unit,
    onCompareClick: () -> Unit,
) {
    state.pendingConsent?.let { prompt -> ConsentDialog(prompt, onConsent) }
    Section(title = "Voices lab") {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            state.loadError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            Text("Language", style = MaterialTheme.typography.labelLarge)
            ChipRow {
                VoicesLabViewModel.LANGUAGES.forEach { tag ->
                    FilterChip(selected = state.locale == tag, onClick = { onLocaleChange(tag) }, label = { Text(tag) })
                }
            }
            Text("Model", style = MaterialTheme.typography.labelLarge)
            ChipRow {
                state.installable.forEach { entry ->
                    val mark = if (entry.id in state.installedIds) "" else " (not downloaded)"
                    FilterChip(selected = state.selected == entry.id, onClick = { onModelChange(entry.id) }, label = { Text("${entry.variant}$mark") })
                }
                FilterChip(
                    selected = state.isControl,
                    onClick = { onModelChange(VoicesLabViewModel.CONTROL) },
                    label = { Text("OS TTS (control)") },
                )
            }
            state.unavailable.forEach { (entry, reason) ->
                Text("${entry.id} (${entry.variant}): unavailable, $reason", style = MaterialTheme.typography.bodySmall)
            }
            Text("Voice", style = MaterialTheme.typography.labelLarge)
            ChipRow {
                FilterChip(selected = state.voiceKey == null, onClick = { onVoiceChange(null) }, label = { Text("Automatic") })
                state.currentVoices.forEach { voice ->
                    val key = voiceKeyOf(voice)
                    FilterChip(selected = state.voiceKey == key, onClick = { onVoiceChange(key) }, label = { Text(voice.name ?: voice.id ?: voice.locale) })
                }
            }
            if (state.presets.isNotEmpty()) {
                Text("Preset text", style = MaterialTheme.typography.labelLarge)
                ChipRow {
                    state.presets.forEach { preset ->
                        FilterChip(selected = false, onClick = { onPresetChange(preset.id) }, label = { Text("${preset.id} (${preset.locale})") })
                    }
                }
            }
            OutlinedTextField(
                value = state.text,
                onValueChange = onTextChange,
                label = { Text("Text to speak") },
                modifier = Modifier.fillMaxWidth(),
            )
            state.selectedEntry?.let { entry ->
                val installed = entry.id in state.installedIds
                Button(onClick = onDownloadClick, enabled = !state.isDownloading && !state.isWarming && !state.isControl) {
                    Text(if (installed) "Warm up model" else "Download model (${megabytes(entry.totalBytes)})")
                }
            }
            if (state.isDownloading) TextButton(onClick = onCancelDownloadClick) { Text("Cancel download") }
            if (state.isChecking) Text("Checking installed files…", style = MaterialTheme.typography.bodySmall)
            state.progress?.let { (done, total) ->
                LinearProgressIndicator(progress = { if (total > 0) done.toFloat() / total else 0f }, modifier = Modifier.fillMaxWidth())
                Text("${megabytes(done)} of ${megabytes(total)}", style = MaterialTheme.typography.bodySmall)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = onSpeakClick, enabled = !state.isSpeaking && state.text.isNotBlank() && (state.isControl || state.canSpeakNeural)) {
                    Text("Speak")
                }
                TextButton(onClick = onStopClick, enabled = state.isSpeaking) { Text("Stop") }
                TextButton(onClick = onRepeatClick, enabled = !state.isSpeaking) { Text("Repeat") }
                TextButton(
                    onClick = onCompareClick,
                    enabled = !state.isSpeaking && state.text.isNotBlank() && state.canSpeakNeural,
                ) { Text("A/B") }
            }
            state.status?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
            if (state.card.isNotEmpty()) {
                Column {
                    state.card.forEach { (name, value) ->
                        Text("$name: $value", style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        }
    }
}

@Composable
private fun ChipRow(content: @Composable () -> Unit) {
    Row(
        modifier = Modifier.horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) { content() }
}

@Composable
private fun ConsentDialog(prompt: ConsentPrompt, onAnswer: (Boolean) -> Unit) {
    AlertDialog(
        onDismissRequest = { onAnswer(false) },
        title = { Text("Download ${prompt.entry.id}?") },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text("This downloads ${megabytes(prompt.totalBytes)} (the model and ${prompt.entry.voices.size} voices) to app storage. Wi-Fi recommended.")
                prompt.licenses.forEach { Text(it, style = MaterialTheme.typography.bodySmall) }
            }
        },
        confirmButton = { TextButton(onClick = { onAnswer(true) }) { Text("Download") } },
        dismissButton = { TextButton(onClick = { onAnswer(false) }) { Text("Cancel") } },
    )
}

/** Whole decimal megabytes, rounded half up; the web and iOS demos use the same rule. */
internal fun megabytes(bytes: Long): String = "${(bytes + 500_000L) / 1_000_000L} MB"
