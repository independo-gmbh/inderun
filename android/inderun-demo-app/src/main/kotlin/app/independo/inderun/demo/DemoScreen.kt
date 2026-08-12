package app.independo.inderun.demo

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp

@Composable
internal fun DemoScreen(
    uiState: DemoUiState,
    onPromptChange: (String) -> Unit,
    onPrivacyChange: (PrivacyPreference) -> Unit,
    onCloudEndpointUrlChange: (String) -> Unit,
    onCloudModelChange: (String) -> Unit,
    onOnnxModelSelectionChange: (DemoOnnxModelSelection) -> Unit,
    onRefreshClick: () -> Unit,
    onRunClick: () -> Unit,
) {
    Surface(modifier = Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            IntroSection()
            CloudSettingsSection(
                endpointUrl = uiState.cloudEndpointUrl,
                model = uiState.cloudModel,
                hint = uiState.cloudSettingsHint,
                onEndpointUrlChange = onCloudEndpointUrlChange,
                onModelChange = onCloudModelChange,
            )
            OnnxSettingsSection(
                selection = uiState.onnxModelSelection,
                downloadState = uiState.onnxDownloadState,
                hint = uiState.onnxSettingsHint,
                onSelectionChange = onOnnxModelSelectionChange,
            )
            PrivacySection(privacy = uiState.privacy, onPrivacyChange = onPrivacyChange)

            Section(title = "Prompt") {
                OutlinedTextField(
                    value = uiState.prompt,
                    onValueChange = onPromptChange,
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text("Prompt") },
                    minLines = 6,
                )
            }

            ActionRow(
                isRunning = uiState.isRunning,
                canRun = uiState.canRun,
                onRefreshClick = onRefreshClick,
                onRunClick = onRunClick,
            )

            Section(title = "Provider Availability") {
                when (val state = uiState.capabilitiesState) {
                    CapabilitiesState.Loading ->
                        Text(
                            text = "Checking provider availability...",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )

                    CapabilitiesState.Failed ->
                        Text(
                            text = "Unable to check provider availability.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )

                    is CapabilitiesState.Ready ->
                        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            state.badges.forEach { badge -> AvailabilityCard(badge) }
                        }
                }
            }

            Section(title = "Result") {
                when {
                    uiState.result != null -> {
                        ResultPanel(title = "Output", body = uiState.result.outputText, accentColor = Color(0xFF1B5E20))
                        Spacer(modifier = Modifier.height(12.dp))
                        MetadataPanel(uiState.result.metadata)
                    }

                    uiState.error != null -> {
                        ResultPanel(title = uiState.error.title, body = uiState.error.body, accentColor = MaterialTheme.colorScheme.error)
                        uiState.error.metadata?.let { metadata ->
                            Spacer(modifier = Modifier.height(12.dp))
                            MetadataPanel(metadata)
                        }
                    }

                    else -> {
                        ResultPanel(
                            title = "Idle",
                            body = "Run the prompt to capture generated text or a normalized IndeRun error.",
                            accentColor = MaterialTheme.colorScheme.primary,
                        )
                    }
                }
            }

            RoutingDecisionSection(uiState.lastRouteDecision)
            LimitationsSection()
        }
    }
}

@Composable
private fun IntroSection() {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            text = "Run the same text request through IndeRun's capability-based provider routing: Android ML Kit GenAI on-device, an ONNX Runtime local provider, or a cloud endpoint exposed through the demo proxy.",
            style = MaterialTheme.typography.bodyLarge,
        )
        Text(
            text = "IndeRun picks the provider automatically from your privacy preference and each provider's reported capabilities.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun CloudSettingsSection(
    endpointUrl: String,
    model: String,
    hint: String,
    onEndpointUrlChange: (String) -> Unit,
    onModelChange: (String) -> Unit,
) {
    Section(title = "Cloud Settings") {
        OutlinedTextField(
            value = endpointUrl,
            onValueChange = onEndpointUrlChange,
            modifier = Modifier.fillMaxWidth(),
            label = { Text("Endpoint URL") },
            minLines = 2,
        )
        Spacer(modifier = Modifier.height(12.dp))
        OutlinedTextField(
            value = model,
            onValueChange = onModelChange,
            modifier = Modifier.fillMaxWidth(),
            label = { Text("Model") },
        )
        Spacer(modifier = Modifier.height(8.dp))
        Text(text = hint, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun OnnxSettingsSection(
    selection: DemoOnnxModelSelection,
    downloadState: DemoOnnxDownloadState,
    hint: String,
    onSelectionChange: (DemoOnnxModelSelection) -> Unit,
) {
    Section(title = "ONNX Local Settings") {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            DemoOnnxModelSelection.entries.forEach { option ->
                FilterChip(
                    selected = selection == option,
                    onClick = { onSelectionChange(option) },
                    label = { Text(option.title) },
                )
            }
        }
        if (downloadState is DemoOnnxDownloadState.Downloading) {
            Spacer(modifier = Modifier.height(12.dp))
            LinearProgressIndicator(
                progress = { downloadState.progress },
                modifier = Modifier.fillMaxWidth(),
            )
        }
        Spacer(modifier = Modifier.height(8.dp))
        Text(text = hint, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun PrivacySection(
    privacy: PrivacyPreference,
    onPrivacyChange: (PrivacyPreference) -> Unit,
) {
    Section(title = "Privacy Preference") {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            PrivacyPreference.entries.forEach { preference ->
                FilterChip(
                    selected = privacy == preference,
                    onClick = { onPrivacyChange(preference) },
                    label = { Text(preference.title) },
                )
            }
        }
    }
}

@Composable
private fun ActionRow(
    isRunning: Boolean,
    canRun: Boolean,
    onRefreshClick: () -> Unit,
    onRunClick: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        TextButton(onClick = onRefreshClick, enabled = !isRunning) {
            Text("Refresh Status")
        }

        Button(
            onClick = onRunClick,
            enabled = canRun,
            modifier = Modifier.weight(1f),
        ) {
            if (isRunning) {
                CircularProgressIndicator(modifier = Modifier.height(18.dp), strokeWidth = 2.dp)
            } else {
                Text("Run")
            }
        }
    }
}

@Composable
private fun RoutingDecisionSection(decision: RouteDecision?) {
    Section(title = "Routing Decision") {
        if (decision == null) {
            Text(
                text = "No run yet. The routing decision appears after the first attempt.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            return@Section
        }

        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)),
        ) {
            Column(
                modifier = Modifier.padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                MetadataRow(label = "Selected", value = decision.selectedProviderId ?: "none")
                MetadataRow(label = "Explanation", value = decision.explanation.ifEmpty { "n/a" })
                if (decision.rejectedProviderIds.isNotEmpty()) {
                    MetadataRow(label = "Rejected", value = decision.rejectedProviderIds.joinToString(", "))
                }
                if (decision.fallbackProviderIds.isNotEmpty()) {
                    MetadataRow(label = "Fallbacks", value = decision.fallbackProviderIds.joinToString(", "))
                }
            }
        }
    }
}

@Composable
private fun LimitationsSection() {
    Section(title = "Known Limitations") {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                text = "• DistilGPT-2 (the default ONNX Local model) is a small base language model, not instruction-tuned, so expect rambly continuations rather than direct answers.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                text = "• Android ML Kit GenAI availability depends on device class, OS version, and Gemini Nano/AICore readiness.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                text = "• The app never embeds cloud credentials. The demo proxy resolves upstream endpoint and auth server-side.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun Section(
    title: String,
    content: @Composable () -> Unit,
) {
    Column {
        Text(text = title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Spacer(modifier = Modifier.height(12.dp))
        content()
    }
}

@Composable
private fun AvailabilityCard(badge: ProviderBadge) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)),
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(text = badge.label, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
            Box(
                modifier = Modifier
                    .background(
                        color = (if (badge.available) Color(0xFF1B5E20) else MaterialTheme.colorScheme.error).copy(alpha = 0.12f),
                        shape = RoundedCornerShape(999.dp),
                    )
                    .padding(horizontal = 10.dp, vertical = 5.dp),
            ) {
                Text(
                    text = if (badge.available) "Available" else "Unavailable",
                    color = if (badge.available) Color(0xFF1B5E20) else MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.labelLarge,
                )
            }
            Text(text = badge.id, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (!badge.available && badge.reason != null) {
                Text(text = badge.reason, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun ResultPanel(
    title: String,
    body: String,
    accentColor: Color,
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)),
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(text = title, color = accentColor, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
            SelectionContainer {
                Text(text = body, style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
}

@Composable
private fun MetadataPanel(metadata: AttemptMetadata) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)),
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(text = "Attempt Metadata", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
            MetadataRow(label = "Run ID", value = metadata.runId)
            MetadataRow(label = "Provider Used", value = metadata.providerUsed)
            MetadataRow(label = "Total ms", value = metadata.totalMsDescription)
            metadata.providerId?.let { MetadataRow(label = "Provider ID", value = it) }
            metadata.retryAfterMs?.let { MetadataRow(label = "Retry After", value = "$it ms") }
        }
    }
}

@Composable
private fun MetadataRow(
    label: String,
    value: String,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.Top,
    ) {
        Text(
            text = label,
            modifier = Modifier.width(96.dp),
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        SelectionContainer {
            Text(text = value, style = MaterialTheme.typography.bodyMedium)
        }
    }
}

@Preview(showBackground = true)
@Composable
private fun DemoScreenPreview() {
    IndeRunDemoTheme {
        DemoScreen(
            uiState = DemoUiState(),
            onPromptChange = {},
            onPrivacyChange = {},
            onCloudEndpointUrlChange = {},
            onCloudModelChange = {},
            onOnnxModelSelectionChange = {},
            onRefreshClick = {},
            onRunClick = {},
        )
    }
}
