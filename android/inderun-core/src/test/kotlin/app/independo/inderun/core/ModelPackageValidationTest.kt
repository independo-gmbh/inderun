package app.independo.inderun.core

import app.independo.inderun.contracts.Format
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.contracts.Source
import app.independo.inderun.contracts.SourceType
import app.independo.inderun.contracts.SpeechModelPackage
import app.independo.inderun.contracts.SpeechModelVoice
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ModelPackageValidationTest {

    @Test
    fun modelPackageValidationRejectsUrlUserinfoInSourceRef() {
        val issues = getModelPackageValidationIssues(
            modelPackage(ref = "https://user:pass@example.com/model"),
        )

        assertTrue(issues.any { it.path == "/source/ref" })
    }

    @Test
    fun modelPackageValidationAllowsPlainSourceRef() {
        val issues = getModelPackageValidationIssues(modelPackage(ref = "models/phi-3"))

        assertTrue(issues.none { it.path == "/source/ref" })
    }

    @Test
    fun modelPackageValidationRequiresSpeechForTextToSpeech() {
        val issues = getModelPackageValidationIssues(modelPackage().copy(tasks = listOf("text_to_speech")))

        assertTrue(issues.any { it.path == "/speech" })
    }

    @Test
    fun modelPackageValidationRejectsDuplicateSpeechVoiceIds() {
        val voice = SpeechModelVoice(id = "v", name = "V", locales = listOf("de-DE"), file = "v.bin")
        val speech = SpeechModelPackage(
            pipeline = "articulino",
            sampleRate = 24000,
            graphs = mapOf("acoustic" to "a.onnx"),
            voices = listOf(voice, voice),
        )

        val issues = getModelPackageValidationIssues(
            modelPackage().copy(tasks = listOf("text_to_speech"), speech = speech),
        )

        assertTrue(issues.any { it.path == "/speech/voices" })
    }

    private fun speechPackage(
        sampleRate: Long = 24000,
        graphs: Map<String, String> = mapOf("acoustic" to "a.onnx"),
        voices: List<SpeechModelVoice>,
    ) = modelPackage().copy(
        tasks = listOf("text_to_speech"),
        speech = SpeechModelPackage(
            pipeline = "articulino",
            sampleRate = sampleRate,
            graphs = graphs,
            voices = voices,
        ),
    )

    private fun speechVoice(locales: List<String>) = SpeechModelVoice(id = "v", name = "V", locales = locales, file = "v.bin")

    @Test
    fun modelPackageValidationRejectsStructurallyEmptySpeech() {
        val issues = getModelPackageValidationIssues(
            speechPackage(sampleRate = 0, graphs = emptyMap(), voices = emptyList()),
        )

        assertEquals(
            listOf("/speech/sampleRate", "/speech/graphs", "/speech/voices"),
            issues.map { it.path },
        )
        assertEquals(
            listOf("must be >= 1", "must list at least one graph", "must list at least one voice"),
            issues.map { it.message },
        )
    }

    @Test
    fun modelPackageValidationRejectsMalformedVoiceLocales() {
        val emptyLocales = getModelPackageValidationIssues(speechPackage(voices = listOf(speechVoice(emptyList()))))
        assertEquals(listOf("/speech/voices/0/locales"), emptyLocales.map { it.path })
        assertEquals(listOf("must list at least one locale"), emptyLocales.map { it.message })

        val malformed = listOf("de_DE", "-de-DE", "de-DE!", "", "de-DE\n")
        val badTags = getModelPackageValidationIssues(speechPackage(voices = listOf(speechVoice(malformed))))
        assertEquals(malformed.indices.map { "/speech/voices/0/locales/$it" }, badTags.map { it.path })
        assertEquals(malformed.map { "must be a hyphenated BCP 47 tag" }, badTags.map { it.message })
    }

    @Test
    fun modelPackageValidationAcceptsAWellFormedSpeechPackage() {
        val issues = getModelPackageValidationIssues(
            speechPackage(voices = listOf(speechVoice(listOf("de-DE", "en-US")))),
        )

        assertEquals(emptyList<ModelPackageValidationIssue>(), issues)
    }

    private fun modelPackage(
        id: String = "phi-3-mini",
        sourceType: SourceType = SourceType.Bundled,
        ref: String? = "models/phi-3",
        tasks: List<String>? = null,
    ): ModelPackage = ModelPackage(
        id = id,
        format = Format.Onnx,
        source = Source(sourceType = sourceType, ref = ref),
        tasks = tasks,
    )
}
