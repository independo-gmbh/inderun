package app.independo.inderun.demo

import android.content.Context

internal interface DemoSettingsStore {
    fun load(): DemoSettings
    fun save(settings: DemoSettings)
}

internal class SharedPreferencesDemoSettingsStore(
    context: Context,
) : DemoSettingsStore {
    private val preferences = context.applicationContext.getSharedPreferences(
        "inderun_demo_settings",
        Context.MODE_PRIVATE,
    )

    override fun load(): DemoSettings {
        val endpointUrl = preferences.getString(KEY_ENDPOINT_URL, null)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: DemoDefaults.DEFAULT_CLOUD_ENDPOINT_URL
        val model = preferences.getString(KEY_MODEL, null)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: DemoDefaults.DEFAULT_CLOUD_MODEL
        val onnxModelSelection = preferences.getString(KEY_ONNX_MODEL_SELECTION, null)
            ?.let { name -> DemoOnnxModelSelection.entries.firstOrNull { it.name == name } }
            ?: DemoDefaults.DEFAULT_ONNX_MODEL_SELECTION
        return DemoSettings(
            endpointUrl = endpointUrl,
            model = model,
            onnxModelSelection = onnxModelSelection,
            voicesLabEnabled = preferences.getBoolean(KEY_VOICES_LAB, false),
        )
    }

    override fun save(settings: DemoSettings) {
        preferences.edit()
            .putString(KEY_ENDPOINT_URL, settings.endpointUrl.trim())
            .putString(KEY_MODEL, settings.model.trim())
            .putString(KEY_ONNX_MODEL_SELECTION, settings.onnxModelSelection.name)
            .putBoolean(KEY_VOICES_LAB, settings.voicesLabEnabled)
            .apply()
    }

    private companion object {
        const val KEY_ENDPOINT_URL = "cloud_endpoint_url"
        const val KEY_MODEL = "cloud_model"
        const val KEY_ONNX_MODEL_SELECTION = "onnx_model_selection"
        const val KEY_VOICES_LAB = "voices_lab_enabled"
    }
}
