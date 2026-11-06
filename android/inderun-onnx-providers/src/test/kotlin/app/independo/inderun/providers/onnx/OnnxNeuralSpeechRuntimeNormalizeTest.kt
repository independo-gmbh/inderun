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
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class OnnxNeuralSpeechRuntimeNormalizeTest {
    private val context: Context = ApplicationProvider.getApplicationContext()

    private fun speechPackage(pipeline: String) = ModelPackage(
        id = "p",
        version = "1",
        format = Format.Onnx,
        tasks = listOf("text_to_speech"),
        source = Source(sourceType = SourceType.AppManaged),
        speech = SpeechModelPackage(
            pipeline = pipeline,
            sampleRate = 24000,
            graphs = emptyMap(),
            frontend = SpeechFrontend(kind = FrontendKind.Grapheme),
            voices = emptyList(),
        ),
    )

    @Test
    fun forwardsToTheArticulinoHook() {
        assertEquals(
            "Am dritten Mai.",
            OnnxNeuralSpeechRuntime(context).normalizeText(speechPackage("articulino"), "Am 3. Mai.", "de-DE"),
        )
    }

    @Test
    fun otherPipelinesKeepTheText() {
        assertEquals("Am 3. Mai.", OnnxNeuralSpeechRuntime(context).normalizeText(speechPackage("other"), "Am 3. Mai.", "de-DE"))
    }
}
