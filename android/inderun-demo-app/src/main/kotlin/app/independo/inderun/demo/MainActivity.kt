package app.independo.inderun.demo

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        setContent {
            IndeRunDemoTheme {
                val onnxDownloader = remember { AndroidDemoOnnxModelDownloader(applicationContext) }
                val demoViewModel = viewModel<DemoViewModel>(
                    factory = DemoViewModel.factory(
                        settingsStore = SharedPreferencesDemoSettingsStore(applicationContext),
                        runtime = AndroidDemoRuntime(applicationContext, onnxDownloader),
                        onnxDownloader = onnxDownloader,
                    ),
                )
                val uiState by demoViewModel.uiState.collectAsStateWithLifecycle()

                DemoScreen(
                    uiState = uiState,
                    onPromptChange = demoViewModel::updatePrompt,
                    onPrivacyChange = demoViewModel::updatePrivacy,
                    onCloudEndpointUrlChange = demoViewModel::updateCloudEndpointUrl,
                    onCloudModelChange = demoViewModel::updateCloudModel,
                    onOnnxModelSelectionChange = demoViewModel::updateOnnxModelSelection,
                    onRefreshClick = demoViewModel::refreshCapabilities,
                    onRunClick = demoViewModel::runPrompt,
                )
            }
        }
    }
}
