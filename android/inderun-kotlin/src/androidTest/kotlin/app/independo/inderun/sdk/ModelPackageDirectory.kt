package app.independo.inderun.sdk

import app.independo.inderun.contracts.Format
import app.independo.inderun.contracts.FrontendKind
import app.independo.inderun.contracts.Integrity
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.contracts.Source
import app.independo.inderun.contracts.SourceType
import app.independo.inderun.contracts.SpeechFrontend
import app.independo.inderun.contracts.SpeechModelPackage
import app.independo.inderun.contracts.SpeechModelVoice
import org.json.JSONObject
import org.junit.Assert.assertEquals
import java.io.File

/**
 * The ONNX speech model package in [directory] (a `model-package.json` written by
 * `tools/neural-speech/prepare_articulino_package.py`), with its `source` pointed at that directory.
 */
fun loadModelPackage(directory: String): ModelPackage {
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
