package app.independo.inderun.sdk

import android.content.Context
import android.util.Log
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import app.independo.inderun.providers.neuralspeech.NeuralSpeechSynthesisInput
import app.independo.inderun.providers.onnx.OnnxNeuralSpeechRuntime
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.sqrt

/**
 * Runs a real Articulino package through ONNX Runtime on the device. Opt-in: pass
 * `-Pandroid.testInstrumentationRunnerArguments.neuralSpeechModelDir=<dir on the device>`, a
 * directory written by `tools/neural-speech/prepare_articulino_package.py` and pushed with
 * `adb push`; skipped otherwise. The package's `source` is rewritten to point at that directory.
 * The timing is logged under the `IndeRunNeuralSpeech` tag. The Android counterpart of
 * `OnnxNeuralSpeechRealModelTests.swift`.
 */
@RunWith(AndroidJUnit4::class)
class OnnxNeuralSpeechRealModelTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext()

    @Test
    fun articulinoSpeaksAGermanSentence() = runBlocking {
        val directory = InstrumentationRegistry.getArguments().getString("neuralSpeechModelDir")
        assumeTrue("pass -Pandroid.testInstrumentationRunnerArguments.neuralSpeechModelDir=/data/local/tmp/articulino", directory != null)
        val modelPackage = loadModelPackage(directory!!)

        val runtime = OnnxNeuralSpeechRuntime(context)
        val prepared = runtime.prepare(modelPackage)
        assertTrue(prepared.reason.orEmpty(), prepared.available)

        val started = System.nanoTime()
        val samples = ArrayList<Short>()
        val voiceId = modelPackage.speech!!.voices.first().id
        runtime.synthesize(NeuralSpeechSynthesisInput(modelPackage, "Ich habe Hunger.", "de-DE", voiceId)).collect { chunk ->
            chunk.samples.forEach { samples += it }
        }
        val wallMs = (System.nanoTime() - started) / 1_000_000
        val seconds = samples.size / 24000.0
        val rms = sqrt(samples.sumOf { it.toDouble() * it.toDouble() } / maxOf(1, samples.size))
        Log.i(TAG, "abi=${android.os.Build.SUPPORTED_ABIS.first()} audio=${"%.2f".format(seconds)}s wall=${wallMs}ms rms=${"%.0f".format(rms)}")

        assertTrue("audio $seconds s", seconds > 1)
        assertTrue("audio $seconds s", seconds < 6)
        assertTrue("rms $rms", rms > 300)
    }

    private companion object {
        const val TAG = "IndeRunNeuralSpeech"
    }
}
