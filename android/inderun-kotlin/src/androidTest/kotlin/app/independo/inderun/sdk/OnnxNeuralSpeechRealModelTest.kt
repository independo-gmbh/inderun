package app.independo.inderun.sdk

import android.content.Context
import android.util.Log
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import app.independo.inderun.contracts.Format
import app.independo.inderun.contracts.FrontendKind
import app.independo.inderun.contracts.Integrity
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.contracts.Source
import app.independo.inderun.contracts.SourceType
import app.independo.inderun.contracts.SpeechFrontend
import app.independo.inderun.contracts.SpeechModelPackage
import app.independo.inderun.contracts.SpeechModelVoice
import app.independo.inderun.providers.neuralspeech.NeuralSpeechSynthesisInput
import app.independo.inderun.providers.onnx.OnnxNeuralSpeechRuntime
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
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
        val modelPackage = loadPackage(directory!!)

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

    private fun loadPackage(directory: String): ModelPackage {
        val json = JSONObject(File(directory, "model-package.json").readText())
        val speech = json.getJSONObject("speech")
        val graphs = speech.getJSONObject("graphs").let { g -> g.keys().asSequence().associateWith { g.getString(it) } }
        val frontend = speech.optJSONObject("frontend")?.let { f ->
            SpeechFrontend(
                kind = FrontendKind.fromRawValue(f.getString("kind"))!!,
                assets = f.optJSONObject("assets")?.let { a -> a.keys().asSequence().associateWith { a.getString(it) } },
            )
        }
        val voices = speech.getJSONArray("voices").let { array ->
            (0 until array.length()).map { i ->
                val v = array.getJSONObject(i)
                SpeechModelVoice(
                    id = v.getString("id"),
                    name = v.getString("name"),
                    locales = v.getJSONArray("locales").let { l -> (0 until l.length()).map { l.getString(it) } },
                    file = v.optString("file").takeIf { it.isNotEmpty() },
                )
            }
        }
        val checksums = json.optJSONObject("integrity")?.getJSONObject("checksums")?.let { c ->
            c.keys().asSequence().associateWith { c.getString(it) }
        }
        assertEquals("onnx", json.getString("format"))
        return ModelPackage(
            id = json.getString("id"),
            version = json.optString("version").takeIf { it.isNotEmpty() },
            format = Format.Onnx,
            tasks = listOf("text_to_speech"),
            source = Source(sourceType = SourceType.Filesystem, ref = directory),
            integrity = checksums?.let { Integrity(checksums = it) },
            speech = SpeechModelPackage(
                pipeline = speech.getString("pipeline"),
                sampleRate = speech.getLong("sampleRate"),
                channels = speech.optLong("channels", 1),
                graphs = graphs,
                frontend = frontend,
                voices = voices,
            ),
        )
    }

    private companion object {
        const val TAG = "IndeRunNeuralSpeech"
    }
}
