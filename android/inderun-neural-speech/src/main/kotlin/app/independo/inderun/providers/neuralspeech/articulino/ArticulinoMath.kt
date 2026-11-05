// Adapted from eigenhand/articulino-onnx, Apache License 2.0
// (https://huggingface.co/eigenhand/Articulino-DE-EN-Realtime-Stream-TTS-ONNX).
//
// The Articulino host math between the ONNX graphs: pure functions, no I/O, no model package. The
// behaviour is pinned by contracts/fixtures/speech/articulino-pipeline.json, generated from
// tools/neural-speech/articulino_math.py; Float (float32) rounding follows that reference, and
// only the biquad runs in Double.

package app.independo.inderun.providers.neuralspeech.articulino

import app.independo.inderun.providers.neuralspeech.SpeechTextFrontend
import java.text.Normalizer
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/** Returns `count` standard-normal values. */
typealias NoiseSource = (Int) -> FloatArray

/** Letter ids (1 + charset index; 0 is the prompt placeholder) and the language id per letter. */
internal class EncodedLetters(val ids: IntArray, val languages: IntArray)

/** Normalized biquad coefficients (`a0` divided out). */
internal data class BiquadCoefficients(val b0: Double, val b1: Double, val b2: Double, val a1: Double, val a2: Double)

/** The result of one flow step; [next] is the following input, absent after the last step. */
internal class FlowStep(val x1: FloatArray, val next: FloatArray?)

internal object ArticulinoMath {
    /** Box-Muller over the platform random number generator; the default when a caller injects no noise. */
    val gaussianNoise: NoiseSource = { count ->
        val out = FloatArray(count)
        val random = java.util.Random()
        var i = 0
        while (i < count) {
            val u = 1.0 - random.nextDouble()
            val v = random.nextDouble()
            val radius = sqrt(-2.0 * ln(u))
            out[i] = (radius * cos(2.0 * PI * v)).toFloat()
            if (i + 1 < count) out[i + 1] = (radius * sin(2.0 * PI * v)).toFloat()
            i += 2
        }
        out
    }

    // Written as code points so no editor or formatter can rewrite them.
    private val replacements: Map<Int, String> = mapOf(
        0x2019 to "'", 0x2018 to "'", 0x60 to "'", 0xB4 to "'",
        0x201C to "\"", 0x201D to "\"", 0x201E to "\"", 0xAB to "\"", 0xBB to "\"",
        0x2013 to "-", 0x2014 to "-", 0x2026 to ".",
        0xF8 to "ö", 0xE6 to "ä", 0xF0 to "d", 0xFE to "th",
    )

    /** `ä ö ü ß`: kept without decomposition even when a charset lacks them. */
    private val kept: Set<Int> = setOf(0xE4, 0xF6, 0xFC, 0xDF)
    private val splitCharacters: Set<Int> = setOf(','.code, ';'.code, ':'.code, '-'.code, ' '.code)

    private fun codePoints(text: String): IntArray {
        val out = IntArray(text.codePointCount(0, text.length))
        var index = 0
        var i = 0
        while (i < text.length) {
            val cp = text.codePointAt(i)
            out[index++] = cp
            i += Character.charCount(cp)
        }
        return out
    }

    private fun isWhitespace(cp: Int): Boolean = cp <= 0xFFFF && SpeechTextFrontend.isWhitespace(cp.toChar())

    private fun string(codePoints: IntArray, from: Int = 0, to: Int = codePoints.size): String = String(codePoints, from, to - from)

    /**
     * Lowercases, applies the replacement map, NFKD-decomposes code points outside the charset
     * (dropping combining marks), drops what is still outside it, and collapses whitespace.
     */
    fun normalizeLetters(text: String, charset: String): String {
        val allowed = codePoints(charset).toSet()
        val out = StringBuilder()
        var pendingSpace = false

        fun append(cp: Int) {
            if (isWhitespace(cp)) {
                pendingSpace = out.isNotEmpty()
            } else if (cp in allowed) {
                if (pendingSpace) out.append(' ')
                pendingSpace = false
                out.appendCodePoint(cp)
            }
        }

        for (original in codePoints(text.lowercase())) {
            val mapped = replacements[original] ?: String(Character.toChars(original))
            val scalars = codePoints(mapped)
            if (scalars.size == 1 && scalars[0] !in allowed && scalars[0] !in kept) {
                for (decomposed in codePoints(Normalizer.normalize(mapped, Normalizer.Form.NFKD))) {
                    if (Character.getType(decomposed) != Character.NON_SPACING_MARK.toInt()) append(decomposed)
                }
            } else {
                scalars.forEach(::append)
            }
        }
        return out.toString()
    }

    fun encodeLetters(text: String, language: Int, config: ArticulinoConfig): EncodedLetters {
        val index = HashMap<Int, Int>()
        codePoints(config.charset).forEachIndexed { i, cp -> index.putIfAbsent(cp, i) }
        val ids = codePoints(normalizeLetters(text, config.charset)).toList().mapNotNull { index[it]?.plus(1) }.toIntArray()
        return EncodedLetters(ids, IntArray(ids.size) { language })
    }

    /** Letters and digits count for the speaking rate; the placeholder, spaces and punctuation do not. */
    fun isLetter(id: Int, charset: String): Boolean = isLetter(id, codePoints(charset))

    private fun isLetter(id: Int, characters: IntArray): Boolean = id > 0 && id <= characters.size && Character.isLetterOrDigit(characters[id - 1])

    /**
     * Durations in 10 ms units: `min(exp(logDurations) * mask, maxUnits) / speed`. [mask] is the
     * model's int64 text mask (0/1).
     */
    fun clampDurations(logDurations: FloatArray, mask: LongArray, speed: Float, maxUnits: Float): FloatArray = FloatArray(logDurations.size) { i ->
        val scaled = exp(logDurations[i].toDouble()).toFloat() * mask[i].toFloat()
        Math.min(scaled, maxUnits) / speed
    }

    private fun median(values: FloatArray): Float {
        val sorted = values.sortedArray()
        val mid = sorted.size / 2
        return if (sorted.size % 2 == 1) sorted[mid] else (sorted[mid - 1] + sorted[mid]) / 2
    }

    /**
     * Rescales, in place, the durations of the letters at index [start] onward ([ids] are the
     * model's text ids, placeholder included) so they speak at exactly [target] letters per second.
     * Single overlong letters count at most three times the median; nothing changes without letters.
     */
    fun equalizeLetterRate(d: FloatArray, ids: IntArray, charset: String, start: Int, target: Float) {
        val characters = codePoints(charset)
        val letters = ids.indices.filter { it >= start && isLetter(ids[it], characters) }
        if (letters.isEmpty() || target <= 0f) return
        val floored = FloatArray(letters.size) { maxOf(d[letters[it]], 0.5f) }
        val cap = 3 * median(floored)
        val x = FloatArray(floored.size) { minOf(floored[it], cap) }
        var total = 0.0
        for (value in x) total += value.toDouble()
        val rate = letters.size.toFloat() / (total.toFloat() / 100f)
        val scale = rate / target
        letters.forEachIndexed { k, index -> d[index] = x[k] * scale }
    }

    /** Number of audio frames the durations span: `ceil(sum(d) / units)`, summed in float32. */
    fun frameCount(d: FloatArray, units: Int): Int {
        var sum = 0f
        for (value in d) sum += value
        return Math.ceil(sum.toDouble() / units).toInt()
    }

    /**
     * Per new frame `j = first until frames`, the overlap-weighted sum of the letter features
     * (flat, [stride] values per letter) over the frame's [units]-wide window.
     */
    fun frameCondition(features: FloatArray, stride: Int, d: FloatArray, first: Int, frames: Int, units: Int): FloatArray {
        val end = FloatArray(d.size)
        var running = 0f
        for (l in d.indices) {
            running += d[l]
            end[l] = running
        }
        val width = units.toFloat()
        val out = FloatArray(maxOf(0, frames - first) * stride)
        for (j in first until maxOf(first, frames)) {
            val lo = j.toFloat() * width
            val hi = lo + width
            val row = (j - first) * stride
            for (l in d.indices) {
                val stop = end[l]
                val begin = stop - d[l]
                val w = maxOf(minOf(stop, hi) - maxOf(begin, lo), 0f) / width
                if (w == 0f) continue
                for (c in 0 until stride) out[row + c] += w * features[l * stride + c]
            }
        }
        return out
    }

    /**
     * One flow step: `x1 = x + (1 - t) * velocity`. With [nextT] and [nextNoise] it also returns
     * the next input `(1 - nextT) * nextNoise + nextT * x1`.
     */
    fun flowStep(x: FloatArray, t: Float, velocity: FloatArray, nextT: Float? = null, nextNoise: FloatArray? = null): FlowStep {
        val scale = 1 - t
        val x1 = FloatArray(x.size) { x[it] + scale * velocity[it] }
        if (nextT == null || nextNoise == null) return FlowStep(x1, null)
        val keep = 1 - nextT
        return FlowStep(x1, FloatArray(x1.size) { keep * nextNoise[it] + nextT * x1[it] })
    }

    /** RBJ cookbook low shelf (z = -1), normalized by a0. */
    fun lowShelfCoefficients(f0: Double, db: Double, sampleRate: Double, slope: Double): BiquadCoefficients {
        val a = 10.0.pow(db / 40)
        val w = 2 * PI * f0 / sampleRate
        val c = cos(w)
        val q = 2 * sqrt(a) * (sin(w) / 2) * sqrt((a + 1 / a) * (1 / slope - 1) + 2)
        val z = -1.0
        val b0 = a * (a + 1 + z * (a - 1) * c + q)
        val b1 = -2 * z * a * (a - 1 + z * (a + 1) * c)
        val b2 = a * (a + 1 + z * (a - 1) * c - q)
        val a0 = a + 1 - z * (a - 1) * c + q
        val a1 = 2 * z * (a - 1 - z * (a + 1) * c)
        val a2 = a + 1 - z * (a - 1) * c - q
        return BiquadCoefficients(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
    }

    /** Direct form II transposed in Double over the whole signal. */
    fun applyBiquad(samples: FloatArray, c: BiquadCoefficients): FloatArray {
        var z1 = 0.0
        var z2 = 0.0
        return FloatArray(samples.size) { i ->
            val v = samples[i].toDouble()
            val o = c.b0 * v + z1
            z1 = c.b1 * v - c.a1 * o + z2
            z2 = c.b2 * v - c.a2 * o
            o.toFloat()
        }
    }

    /** Scales [samples] in place so that no value exceeds [peak] in magnitude. */
    fun limitPeak(samples: FloatArray, peak: Float) {
        var maximum = 0f
        for (value in samples) maximum = maxOf(maximum, abs(value))
        if (maximum <= peak) return
        val scale = peak / maximum
        for (i in samples.indices) samples[i] *= scale
    }

    /** Decoder waveform to speech: low shelf over the whole waveform (lead-in included), cut the lead-in, limit to the peak. */
    fun shapeWaveform(waveform: FloatArray, leadSamples: Int, config: ArticulinoConfig): FloatArray {
        val shelf = lowShelfCoefficients(config.lowShelfHz, config.lowShelfDb, config.sampleRate.toDouble(), config.shelfSlope)
        val out = applyBiquad(waveform, shelf).let { it.copyOfRange(minOf(leadSamples, it.size), it.size) }
        limitPeak(out, config.peak.toFloat())
        return out
    }

    /** [samples] followed by [pauseMs] of silence. */
    fun padSilence(samples: FloatArray, pauseMs: Int, sampleRate: Int): FloatArray {
        val silence = maxOf(0L, Math.round(pauseMs / 1000.0 * sampleRate)).toInt()
        return samples + FloatArray(silence)
    }

    /** `round(clamp(x, -1, 1) * 32767)`, halves rounding up as `Math.round` does. */
    fun toInt16(samples: FloatArray): ShortArray = ShortArray(samples.size) {
        Math.floor(samples[it].coerceIn(-1f, 1f).toDouble() * 32767 + 0.5).toInt().toShort()
    }

    /**
     * Pieces of at most [maxLetters] code points where possible: cut at the last `, ; : -` (after
     * the separator) or space between index [minSplit] and [maxLetters]. A run without any of them
     * stays whole. Expects normalized text.
     */
    fun splitLongSentence(text: String, maxLetters: Int = 180, minSplit: Int = 60): List<String> {
        val pieces = mutableListOf<String>()
        var rest = codePoints(text)
        while (rest.size > maxLetters) {
            val at = (minOf(maxLetters, rest.size) - 1 downTo minSplit).firstOrNull { rest[it] in splitCharacters } ?: break
            val cut = if (rest[at] == ' '.code) at else at + 1
            pieces += trimmed(rest, 0, cut)
            rest = codePoints(trimmed(rest, cut, rest.size))
        }
        pieces += string(rest)
        return pieces
    }

    private fun trimmed(codePoints: IntArray, from: Int, to: Int): String {
        var start = from
        var stop = to
        while (start < stop && isWhitespace(codePoints[start])) start += 1
        while (stop > start && isWhitespace(codePoints[stop - 1])) stop -= 1
        return string(codePoints, start, stop)
    }
}
