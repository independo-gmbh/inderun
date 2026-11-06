package app.independo.inderun.providers.neuralspeech

import app.independo.inderun.contracts.Format
import app.independo.inderun.contracts.FrontendKind
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.contracts.Source
import app.independo.inderun.contracts.SourceType
import app.independo.inderun.contracts.SpeechFrontend
import app.independo.inderun.contracts.SpeechModelPackage
import app.independo.inderun.providers.neuralspeech.articulino.ArticulinoRuntime
import app.independo.inderun.providers.neuralspeech.articulino.ArticulinoRuntimeOptions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class ArticulinoNormalizeTextTest {
    private object NoGraphs : SpeechGraphExecutor {
        override suspend fun load(graphs: Map<String, String>) = Unit

        override suspend fun run(role: String, inputs: Map<String, SpeechTensor>): Map<String, SpeechTensor> = emptyMap()

        override fun close() = Unit
    }

    private object NoFiles : SpeechPackageFiles {
        override suspend fun read(file: String): ByteArray = ByteArray(0)
    }

    private fun packageWith(kind: FrontendKind?) = ModelPackage(
        id = "p",
        version = "1",
        format = Format.Onnx,
        tasks = listOf("text_to_speech"),
        source = Source(sourceType = SourceType.AppManaged),
        speech = SpeechModelPackage(
            pipeline = "articulino",
            sampleRate = 24000,
            graphs = emptyMap(),
            frontend = kind?.let { SpeechFrontend(kind = it) },
            voices = emptyList(),
        ),
    )

    private fun runtime(normalizer: ((String, String) -> String)? = null) = ArticulinoRuntime(
        if (normalizer == null) {
            ArticulinoRuntimeOptions(NoGraphs, NoFiles)
        } else {
            ArticulinoRuntimeOptions(NoGraphs, NoFiles, textNormalizer = normalizer)
        },
    )

    @Test
    fun aGraphemeFrontendNormalizesThroughTheRouteCore() {
        assertEquals(
            "Am dritten Mai, zum Beispiel um vierzehn Uhr dreißig.",
            runtime().normalizeText(packageWith(FrontendKind.Grapheme), "Am 3. Mai, z. B. um 14:30 Uhr.", "de-DE"),
        )
    }

    @Test
    fun aPackageWithoutAGraphemeFrontendKeepsTheText() {
        for (kind in listOf(null) + FrontendKind.entries.filter { it != FrontendKind.Grapheme }) {
            assertEquals("Am 3. Mai.", runtime().normalizeText(packageWith(kind), "Am 3. Mai.", "de-DE"))
        }
    }

    @Test
    fun aFailureReachingTheCoreIsUnavailable() {
        for (failure in listOf<Throwable>(UnsatisfiedLinkError("no inderun_speech_text"), IllegalStateException("jni"))) {
            val error = try {
                runtime { _, _ -> throw failure }.normalizeText(packageWith(FrontendKind.Grapheme), "x", "de-DE")
                fail("expected a NeuralSpeechRuntimeError")
                return
            } catch (error: NeuralSpeechRuntimeError) {
                error
            }
            assertEquals(NeuralSpeechRuntimeErrorKind.Unavailable, error.kind)
            assertEquals("speech text frontend unavailable: ${failure.message}", error.message)
            assertSame(failure, error.cause)
        }
    }

    @Test
    fun textThatIsNotGermanIsReturnedUnchangedWithoutCrossingTheFfi() {
        val lone = "Hello \uD800 World\u0000!"
        val failing = runtime { _, _ -> throw IllegalStateException("must not be called") }
        for (locale in listOf("en-US", "fr", "", "deu")) {
            assertEquals(lone, failing.normalizeText(packageWith(FrontendKind.Grapheme), lone, locale))
            assertEquals(lone, runtime().normalizeText(packageWith(FrontendKind.Grapheme), lone, locale))
        }
    }

    @Test
    fun theGermanLanguageSubtagIsMatchedCaseInsensitivelyWithEitherSeparator() {
        val seen = mutableListOf<String>()
        val recording = runtime { text, locale ->
            seen += locale
            text
        }
        for (locale in listOf("de", "de-DE", "DE_at", "De-CH")) {
            recording.normalizeText(packageWith(FrontendKind.Grapheme), "x", locale)
        }
        assertEquals(listOf("de", "de-DE", "DE_at", "De-CH"), seen)
    }
}
