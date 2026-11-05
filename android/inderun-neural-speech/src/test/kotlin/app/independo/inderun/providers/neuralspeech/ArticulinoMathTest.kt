package app.independo.inderun.providers.neuralspeech

import app.independo.inderun.providers.neuralspeech.articulino.ArticulinoConfig
import app.independo.inderun.providers.neuralspeech.articulino.ArticulinoMath
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import kotlin.math.ln

@RunWith(RobolectricTestRunner::class)
class ArticulinoMathTest {
    private val charset = " abcdefghijklmnopqrstuvwxyzäöüß.,?!-'\":;()0123456789"

    private fun config(charset: String = this.charset): ArticulinoConfig = ArticulinoConfig.parse(
        JSONObject(
            """
            {"sample_rate":24000,"latent_dim":2,"samples_per_frame":4,"duration_units_per_frame":4,
             "prefix_frames":2,"decoder_lead_in_frames":1,"max_duration_units":400.0,
             "times":[0.0,0.25,0.5,0.75],"languages":{"de":0,"en":1},
             "postprocess":{"low_shelf_db":2.0,"low_shelf_hz":180.0,"shelf_slope":0.7,"peak":0.95}}
            """.trimIndent(),
        ).put("charset", charset).toString().toByteArray(Charsets.UTF_8),
    )

    @Test
    fun normalizeFoldsAccentsMapsTypographyAndDropsUnknownCodePoints() {
        val text = "Café – „Zitat“ … ø 😀"

        assertEquals(
            "cafe - \"zitat\" . ö",
            ArticulinoMath.normalizeLetters(text, charset),
        )
    }

    @Test
    fun normalizeCollapsesWhitespaceAndTrims() {
        assertEquals("a b", ArticulinoMath.normalizeLetters("  a \t\n b  ", charset))
    }

    @Test
    fun encodeLettersMapsToOnePlusCharsetIndexWithOneLanguagePerLetter() {
        val cfg = config()
        val de = ArticulinoMath.encodeLetters("Ich habe Hunger.", 0, cfg)

        assertArrayEquals(intArrayOf(10, 4, 9, 1), de.ids.copyOfRange(0, 4))
        assertArrayEquals(IntArray(de.ids.size), de.languages)
        assertArrayEquals(intArrayOf(1, 1), ArticulinoMath.encodeLetters("Hi", 1, cfg).languages)
        assertEquals(0, ArticulinoMath.encodeLetters("123 😀", 0, config(" abc")).ids.size)
    }

    @Test
    fun isLetterCountsLettersAndDigitsNotPlaceholderSpaceOrPunctuation() {
        val ids = ArticulinoMath.encodeLetters("a 1.", 0, config()).ids

        assertEquals(
            listOf(false, true, false, true, false),
            (listOf(0) + ids.toList()).map { ArticulinoMath.isLetter(it, charset) },
        )
    }

    @Test
    fun clampDurationsClampsMasksAndDividesBySpeed() {
        val log = floatArrayOf(5f, 1000f, 2f).map { ln(it.toDouble()).toFloat() }.toFloatArray()

        val d = ArticulinoMath.clampDurations(log, longArrayOf(0, 1, 1), 2f, 400f)

        assertArrayEquals(floatArrayOf(0f, 200f, 1f), d, 1e-4f)
    }

    @Test
    fun equalizeLetterRateRescalesOnlyTheLettersToTheTargetRate() {
        val d = floatArrayOf(0f, 10f, 7f, 10f, 10f)

        ArticulinoMath.equalizeLetterRate(d, intArrayOf(0, 2, 1, 3, 4), charset, 1, 20f)

        assertEquals(0f, d[0], 0f)
        assertEquals(7f, d[2], 0f)
        assertEquals(20f, 3 / ((d[1] + d[3] + d[4]) / 100), 1e-3f)
    }

    @Test
    fun equalizeLetterRateLeavesDurationsAloneWithoutLetters() {
        val d = floatArrayOf(1f)

        ArticulinoMath.equalizeLetterRate(d, intArrayOf(1), charset, 0, 20f)

        assertArrayEquals(floatArrayOf(1f), d, 0f)
    }

    @Test
    fun toInt16RoundsHalvesUpAndClips() {
        assertArrayEquals(
            shortArrayOf(0, 16384, 32767, -32767, -32767),
            ArticulinoMath.toInt16(floatArrayOf(0f, 0.5f, 1.5f, -2f, -1f)),
        )
    }

    @Test
    fun splitsAfterTheLastCommaBetweenTheLimits() {
        val text = "a".repeat(119) + ", " + "b".repeat(79)

        assertEquals(listOf("a".repeat(119) + ",", "b".repeat(79)), ArticulinoMath.splitLongSentence(text))
    }

    @Test
    fun keepsShortTextWholeAndFallsBackToASpace() {
        assertEquals(listOf("kurz."), ArticulinoMath.splitLongSentence("kurz."))
        assertEquals(
            listOf("a".repeat(100), "b".repeat(99)),
            ArticulinoMath.splitLongSentence("a".repeat(100) + " " + "b".repeat(99)),
        )
    }

    @Test
    fun keepsARunWithoutAnySeparatorWhole() {
        val run = "x".repeat(300)

        assertEquals(listOf(run), ArticulinoMath.splitLongSentence(run))
    }

    @Test
    fun lowShelfIsUnityAtDcForZeroGainAndLimitPeakScalesDown() {
        val c = ArticulinoMath.lowShelfCoefficients(180.0, 0.0, 24000.0, 0.7)
        assertEquals(1.0, c.b0, 1e-12)

        val loud = floatArrayOf(2f, -2f)
        ArticulinoMath.limitPeak(loud, 0.95f)
        assertEquals(0.95f, loud[0], 1e-6f)
    }

    @Test
    fun configNamesAMissingKey() {
        val error = runCatching { ArticulinoConfig.parse("""{"sample_rate":1}""".toByteArray()) }.exceptionOrNull()

        assertEquals(
            "pipeline config malformed: missing 'postprocess'",
            (error as NeuralSpeechRuntimeError).message,
        )
    }
}
