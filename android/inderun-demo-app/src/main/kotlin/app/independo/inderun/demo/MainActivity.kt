package app.independo.inderun.demo

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel

class MainActivity : ComponentActivity() {
    private var activeLab: VoicesLabViewModel? = null

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

                // Only the setting going off stops the lab; the ViewModel's onCleared handles teardown.
                LaunchedEffect(uiState.voicesLabEnabled) {
                    if (!uiState.voicesLabEnabled) activeLab?.shutdown()
                }

                DemoScreen(
                    uiState = uiState,
                    onPromptChange = demoViewModel::updatePrompt,
                    onPrivacyChange = demoViewModel::updatePrivacy,
                    onCloudEndpointUrlChange = demoViewModel::updateCloudEndpointUrl,
                    onCloudModelChange = demoViewModel::updateCloudModel,
                    onOnnxModelSelectionChange = demoViewModel::updateOnnxModelSelection,
                    onRefreshClick = demoViewModel::refreshCapabilities,
                    onRunClick = demoViewModel::runPrompt,
                    onStreamClick = demoViewModel::streamPrompt,
                    onCancelStreamClick = demoViewModel::cancelStream,
                    onSpeechTextChange = demoViewModel::updateSpeechText,
                    onSpeechLocaleChange = demoViewModel::updateSpeechLocale,
                    onSpeechVoiceChange = demoViewModel::updateSpeechVoice,
                    onSpeakClick = demoViewModel::speak,
                    onStopSpeakingClick = demoViewModel::stopSpeaking,
                    onSynthesizeClick = demoViewModel::synthesizeSpeech,
                    onVoicesLabEnabledChange = demoViewModel::updateVoicesLabEnabled,
                    voicesLab = {
                        // Created only while the setting is on: off, nothing below this line exists.
                        val labViewModel = viewModel<VoicesLabViewModel>(
                            factory = VoicesLabViewModel.factory(
                                catalogSource = { assets.open("neural-model-catalog.json").bufferedReader().use { it.readText() } },
                                corpusSource = { runCatching { assets.open("utterance-corpus.json").bufferedReader().use { it.readText() } }.getOrNull() },
                                downloader = DemoNeuralModelDownloader(applicationContext.filesDir),
                                runtime = { AndroidVoicesLabRuntime(applicationContext) },
                            ),
                        )
                        // Remember it for the switch-off below. Leaving the composition is not a switch-off:
                        // a rotation recomposes this slot while the ViewModel keeps downloading.
                        SideEffect { activeLab = labViewModel }
                        VoicesLabScreen(labViewModel)
                    },
                )
            }
        }
    }
}
