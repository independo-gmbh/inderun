package app.independo.inderun.providers.neuralspeech.articulino

import app.independo.inderun.providers.neuralspeech.NeuralSpeechRuntimeError
import app.independo.inderun.providers.neuralspeech.NeuralSpeechRuntimeErrorKind
import org.json.JSONException
import org.json.JSONObject

/** The constants of the upstream Articulino `config.json` the pipeline needs. */
data class ArticulinoConfig(
    val sampleRate: Int,
    val latentDim: Int,
    val samplesPerFrame: Int,
    val durationUnitsPerFrame: Int,
    val prefixFrames: Int,
    val decoderLeadInFrames: Int,
    val maxDurationUnits: Float,
    val times: List<Float>,
    val charset: String,
    val languages: Map<String, Int>,
    val lowShelfDb: Double,
    val lowShelfHz: Double,
    val shelfSlope: Double,
    val peak: Double,
) {
    companion object {
        /**
         * Upper bound of `max_duration_units`. With the voice's `letter_rate` held to 1-100 and `speed` to
         * at least 0.7, it bounds every duration and so the frame count of a sentence.
         */
        internal const val MAX_DURATION_UNITS_CAP = 100_000.0

        private fun failure(why: String) = NeuralSpeechRuntimeError(NeuralSpeechRuntimeErrorKind.Capability, "pipeline config malformed: $why")

        private fun missing(key: String) = failure("missing '$key'")

        private fun number(source: JSONObject, key: String, path: String = key): Double {
            val value = (source.opt(key) as? Number)?.toDouble()
            if (value == null || !value.isFinite()) throw missing(path)
            return value
        }

        /** [value] as an exact integer within [range], or a malformed-config error naming [key]. */
        private fun integer(value: Double, key: String, range: IntRange): Int {
            if (value != Math.rint(value) || value < range.first || value > range.last) {
                throw failure("$key must be an integer from ${range.first} to ${range.last}")
            }
            return value.toInt()
        }

        private fun integer(source: JSONObject, key: String, range: IntRange): Int = integer(number(source, key), key, range)

        /**
         * Parses the package's `config.json` (snake_case keys, as upstream ships it) and range-checks every
         * value the pipeline computes with, so a malformed config refuses at `prepare` instead of allocating
         * absurd buffers later.
         */
        fun parse(bytes: ByteArray): ArticulinoConfig {
            val root = try {
                JSONObject(String(bytes, Charsets.UTF_8))
            } catch (error: JSONException) {
                throw failure("not valid JSON")
            }
            val post = root.optJSONObject("postprocess") ?: throw missing("postprocess")
            val rawLanguages = root.optJSONObject("languages") ?: throw missing("languages")
            val languages = rawLanguages.keys().asSequence().associateWith { language ->
                val id = (rawLanguages.opt(language) as? Number)?.toDouble()
                if (id == null || !id.isFinite()) throw missing("languages.$language")
                integer(id, "languages.$language", 0..65535)
            }
            val rawTimes = root.optJSONArray("times")
            val times = rawTimes?.let { array ->
                (0 until array.length()).map { (array.opt(it) as? Number)?.toFloat() ?: throw missing("times") }
            }
            if (times.isNullOrEmpty()) throw missing("times")
            times.forEachIndexed { k, t -> if (!(t >= 0f && t < 1f)) throw failure("times[$k] must be in [0, 1)") }
            val charset = root.opt("charset") as? String
            if (charset.isNullOrEmpty()) throw missing("charset")
            val sampleRate = integer(root, "sample_rate", 8000..192_000)
            val latentDim = integer(root, "latent_dim", 1..4096)
            val samplesPerFrame = integer(root, "samples_per_frame", 1..65536)
            val durationUnitsPerFrame = integer(root, "duration_units_per_frame", 1..1000)
            val prefixFrames = integer(root, "prefix_frames", 0..100_000)
            val decoderLeadInFrames = integer(root, "decoder_lead_in_frames", 0..100_000)
            val maxDurationUnits = number(root, "max_duration_units")
            if (!(maxDurationUnits > 0 && maxDurationUnits <= MAX_DURATION_UNITS_CAP)) {
                throw failure("max_duration_units must be greater than 0 and at most ${MAX_DURATION_UNITS_CAP.toInt()}")
            }
            val lowShelfDb = number(post, "low_shelf_db", "postprocess.low_shelf_db")
            val lowShelfHz = number(post, "low_shelf_hz", "postprocess.low_shelf_hz")
            val shelfSlope = number(post, "shelf_slope", "postprocess.shelf_slope")
            val peak = number(post, "peak", "postprocess.peak")
            if (!(peak > 0 && peak <= 1)) throw failure("postprocess.peak must be in (0, 1]")
            if (!(shelfSlope > 0)) throw failure("postprocess.shelf_slope must be greater than 0")
            return ArticulinoConfig(
                sampleRate = sampleRate,
                latentDim = latentDim,
                samplesPerFrame = samplesPerFrame,
                durationUnitsPerFrame = durationUnitsPerFrame,
                prefixFrames = prefixFrames,
                decoderLeadInFrames = decoderLeadInFrames,
                maxDurationUnits = maxDurationUnits.toFloat(),
                times = times,
                charset = charset,
                languages = languages,
                lowShelfDb = lowShelfDb,
                lowShelfHz = lowShelfHz,
                shelfSlope = shelfSlope,
                peak = peak,
            )
        }
    }
}
