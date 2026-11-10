package app.independo.inderun.providers.onnx

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import app.independo.inderun.contracts.Format
import app.independo.inderun.contracts.FrontendKind
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.contracts.Source
import app.independo.inderun.contracts.SourceType
import app.independo.inderun.contracts.SpeechFrontend
import app.independo.inderun.contracts.SpeechModelPackage
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File

@RunWith(RobolectricTestRunner::class)
class OnnxNeuralSpeechRuntimeBundledTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val extracted get() = File(context.filesDir, "inderun-onnx-assets")

    private val bundled = ModelPackage(
        id = "bundled-speech",
        version = "1",
        format = Format.Onnx,
        tasks = listOf("text_to_speech"),
        source = Source(sourceType = SourceType.Bundled, ref = "models/articulino"),
        speech = SpeechModelPackage(
            pipeline = "articulino",
            sampleRate = 24000,
            graphs = mapOf("text" to "text.onnx"),
            frontend = SpeechFrontend(kind = FrontendKind.Grapheme),
            voices = emptyList(),
        ),
    )

    @Test
    fun availabilityNeverExtractsABundledSource() = runTest {
        OnnxNeuralSpeechRuntime(context).availability(bundled)
        assertFalse("availability extracted the bundled assets", extracted.exists())
    }

    @Test
    fun prepareExtractsABundledSource() = runTest {
        OnnxNeuralSpeechRuntime(context).prepare(bundled)
        assertTrue("prepare did not extract the bundled assets", extracted.exists())
    }
}
