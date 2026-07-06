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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
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
    onExecutionModeChange: (DemoExecutionMode) -> Unit,
    onCloudEndpointUrlChange: (String) -> Unit,
    onCloudModelChange: (String) -> Unit,
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
            Text(
                text = "Run the same text request through either Android ML Kit GenAI on-device or a cloud endpoint exposed through the demo proxy.",
                style = MaterialTheme.typography.bodyLarge,
            )
            Text(
                text = "Routing is explicit in this demo. It does not automatically fall back between providers.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            Section(title = "Execution Mode") {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    DemoExecutionMode.entries.forEach { mode ->
                        FilterChip(
                            selected = uiState.executionMode == mode,
                            onClick = { onExecutionModeChange(mode) },
                            label = { Text(mode.title) },
                        )
                    }
                }
                Spacer(modifier = Modifier.height(8.dp))
                Text(
                    text = uiState.executionModeDescription,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            Section(title = "Availability") {
                AvailabilityCard(
                    title = DemoExecutionMode.OnDevice.title,
                    state = uiState.onDeviceStatus,
                )
                Spacer(modifier = Modifier.height(12.dp))
                AvailabilityCard(
                    title = DemoExecutionMode.Cloud.title,
                    state = uiState.cloudStatus,
                )
            }

            Section(title = "Cloud Settings") {
                OutlinedTextField(
                    value = uiState.cloudEndpointUrl,
                    onValueChange = onCloudEndpointUrlChange,
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text("Endpoint URL") },
                    minLines = 2,
                )
                Spacer(modifier = Modifier.height(12.dp))
                OutlinedTextField(
                    value = uiState.cloudModel,
                    onValueChange = onCloudModelChange,
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text("Model") },
                )
                Spacer(modifier = Modifier.height(8.dp))
                Text(
                    text = uiState.cloudSettingsHint,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            Section(title = "Prompt") {
                OutlinedTextField(
                    value = uiState.prompt,
                    onValueChange = onPromptChange,
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text("Prompt") },
                    minLines = 6,
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                TextButton(
                    onClick = onRefreshClick,
                    enabled = !uiState.isRunning,
                ) {
                    Text("Refresh Status")
                }

                Button(
                    onClick = onRunClick,
                    enabled = uiState.canRun,
                    modifier = Modifier.weight(1f),
                ) {
                    if (uiState.isRunning) {
                        CircularProgressIndicator(
                            modifier = Modifier.height(18.dp),
                            strokeWidth = 2.dp,
                        )
                    } else {
                        Text(uiState.runButtonTitle)
                    }
                }
            }

            Section(title = "Result") {
                when {
                    uiState.result != null -> {
                        ResultPanel(
                            title = "Output",
                            body = uiState.result.outputText,
                            accentColor = Color(0xFF1B5E20),
                        )
                        Spacer(modifier = Modifier.height(12.dp))
                        MetadataPanel(uiState.result.metadata)
                    }

                    uiState.error != null -> {
                        ResultPanel(
                            title = uiState.error.title,
                            body = uiState.error.body,
                            accentColor = MaterialTheme.colorScheme.error,
                        )
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
        }
    }
}

@Composable
private fun Section(
    title: String,
    content: @Composable () -> Unit,
) {
    Column {
        Text(
            text = title,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(modifier = Modifier.height(12.dp))
        content()
    }
}

@Composable
private fun AvailabilityCard(
    title: String,
    state: DemoAvailabilityState,
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
        ),
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
            )
            Box(
                modifier = Modifier
                    .background(
                        color = availabilityColor(state.kind).copy(alpha = 0.12f),
                        shape = RoundedCornerShape(999.dp),
                    )
                    .padding(horizontal = 10.dp, vertical = 5.dp),
            ) {
                Text(
                    text = state.badgeTitle,
                    color = availabilityColor(state.kind),
                    style = MaterialTheme.typography.labelLarge,
                )
            }
            Text(
                text = state.message,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
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
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
        ),
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = title,
                color = accentColor,
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
            )
            SelectionContainer {
                Text(
                    text = body,
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        }
    }
}

@Composable
private fun MetadataPanel(metadata: AttemptMetadata) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
        ),
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = "Attempt Metadata",
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
            )
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
            modifier = Modifier.weight(0.36f),
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        SelectionContainer(
            modifier = Modifier.weight(0.64f),
        ) {
            Text(
                text = value,
                style = MaterialTheme.typography.bodyMedium,
            )
        }
    }
}

@Composable
private fun availabilityColor(kind: DemoAvailabilityKind): Color = when (kind) {
    DemoAvailabilityKind.Checking -> MaterialTheme.colorScheme.secondary
    DemoAvailabilityKind.Available -> Color(0xFF1B5E20)
    DemoAvailabilityKind.Downloadable -> Color(0xFF9A6700)
    DemoAvailabilityKind.Downloading -> Color(0xFF0B57D0)
    DemoAvailabilityKind.Unavailable -> MaterialTheme.colorScheme.error
}

@Preview(showBackground = true)
@Composable
private fun DemoScreenPreview() {
    IndeRunDemoTheme {
        DemoScreen(
            uiState = DemoUiState(),
            onPromptChange = {},
            onExecutionModeChange = {},
            onCloudEndpointUrlChange = {},
            onCloudModelChange = {},
            onRefreshClick = {},
            onRunClick = {},
        )
    }
}
