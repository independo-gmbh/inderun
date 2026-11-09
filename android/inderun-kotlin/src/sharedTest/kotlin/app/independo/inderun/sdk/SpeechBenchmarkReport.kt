package app.independo.inderun.sdk

import android.os.Build
import app.independo.inderun.core.IndeRunException
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.Instant
import java.time.ZoneOffset
import kotlin.math.ceil

/**
 * The machine-readable result of one speech benchmark run against one target (#276), shaped by
 * `contracts/fixtures/speech/speech-benchmark-report.schema.json`. It carries utterance ids and
 * measurements, never utterance text, and a hardware model id, never a user-assigned device name.
 * The Android counterpart of `SpeechBenchmarkReport.swift`.
 */
class SpeechBenchmarkReport private constructor(
    val harness: String,
    val createdAt: Instant,
    val device: String,
    val os: String,
    val sdkVersion: String,
    val target: Target,
    /** Distinct locales in first-seen order; serialized as the top-level `requestedLocale` / `resolvedLocale`. */
    val requestedLocales: List<String>,
    val resolvedLocales: List<String>,
    val locality: String,
    val samples: List<Sample>,
    val skipped: List<Pair<String, String>>,
    val p50: List<Percentile>,
    val p95: List<Percentile>,
) {
    data class Target(
        val name: String,
        val providerId: String,
        val model: String? = null,
        val variant: String? = null,
        val checksums: Map<String, String>? = null,
        val voiceId: String? = null,
    )

    /** One measured step. [target] only labels the `INDERUN-BENCH` log lines; the report leaves it out. */
    data class Sample(
        val scenario: String,
        val step: String,
        val utteranceId: String,
        val requestedLocale: String,
        val resolvedLocale: String? = null,
        val metrics: Map<String, Double> = emptyMap(),
        val target: String = "",
    )

    data class Percentile(
        val scenario: String,
        val step: String,
        val utteranceId: String,
        val metrics: Map<String, Double>,
    )

    fun toJson(): JSONObject = JSONObject()
        .put("schema", SCHEMA)
        .put("harness", harness)
        .put("createdAt", createdAt.toString())
        .put("device", device)
        .put("os", os)
        .put("sdkVersion", sdkVersion)
        .put("target", targetJson())
        .put("requestedLocale", JSONArray(requestedLocales))
        .put("resolvedLocale", JSONArray(resolvedLocales))
        .put("locality", locality)
        .put("samples", JSONArray(samples.map(::sampleJson)))
        .put("skipped", JSONArray(skipped.map { (scenario, reason) -> JSONObject().put("scenario", scenario).put("reason", reason) }))
        .put("p50", JSONArray(p50.map(::percentileJson)))
        .put("p95", JSONArray(p95.map(::percentileJson)))

    /** Writes `<harness>-<target>-<device>-<yyyy-MM-dd>.json` into [directory], creating it first. */
    fun write(directory: File): File {
        check(directory.isDirectory || directory.mkdirs()) { "Cannot create ${directory.path}" }
        val date = createdAt.atZone(ZoneOffset.UTC).toLocalDate()
        val file = File(directory, listOf(harness, fileSafe(target.name), fileSafe(device), date.toString()).joinToString("-") + ".json")
        file.writeText(toJson().toString(2))
        return file
    }

    private fun targetJson() = JSONObject().put("name", target.name).put("providerId", target.providerId).apply {
        target.model?.let { put("model", it) }
        target.variant?.let { put("variant", it) }
        target.checksums?.let { put("checksums", JSONObject(it)) }
        target.voiceId?.let { put("voiceId", it) }
    }

    private fun sampleJson(sample: Sample) = JSONObject()
        .put("scenario", sample.scenario)
        .put("step", sample.step)
        .put("utteranceId", sample.utteranceId)
        .put("requestedLocale", sample.requestedLocale)
        .apply {
            sample.resolvedLocale?.let { put("resolvedLocale", it) }
            sample.metrics.forEach { (name, value) -> put(name, value) }
        }

    private fun percentileJson(percentile: Percentile) = JSONObject()
        .put("scenario", percentile.scenario)
        .put("step", percentile.step)
        .put("utteranceId", percentile.utteranceId)
        .put("metrics", JSONObject(percentile.metrics))

    companion object {
        const val SCHEMA = "inderun-speech-benchmark/1"

        fun build(
            harness: String,
            device: String,
            os: String,
            sdkVersion: String,
            target: Target,
            locality: String,
            samples: List<Sample>,
            skipped: List<Pair<String, String>>,
            createdAt: Instant,
        ): SpeechBenchmarkReport {
            // JSON has no infinity or NaN; a metric that is not a number is not a measurement.
            val finite = samples.map { sample -> sample.copy(metrics = sample.metrics.filterValues { it.isFinite() }) }
            return SpeechBenchmarkReport(
                harness = harness,
                createdAt = createdAt,
                device = device,
                os = os,
                sdkVersion = sdkVersion,
                target = target,
                requestedLocales = samples.map { it.requestedLocale }.distinct(),
                resolvedLocales = samples.mapNotNull { it.resolvedLocale }.distinct(),
                locality = locality,
                samples = finite,
                skipped = skipped,
                p50 = percentiles(finite, 0.5),
                p95 = percentiles(finite, 0.95),
            )
        }

        /** Render time over audio time; null when the audio has no length, so a zero-length artifact never records infinity. */
        fun realTimeFactor(renderMs: Double, audioMs: Double?): Double? = audioMs?.takeIf { it > 0 }?.let { renderMs / it }

        /**
         * Why a scenario was skipped: the error class and `details.code` only. An error message can echo the
         * request, and a report never carries utterance text.
         */
        fun skipReason(error: Throwable): String {
            if (error !is IndeRunException) return error.javaClass.simpleName
            val code = error.details?.get("code") as? String
            return if (code != null) "${error.errorClass.rawValue}: $code" else error.errorClass.rawValue
        }

        /**
         * Resolves the `speechBenchmarkOut` argument against [base] (the app's external files directory, the only
         * place the test app can write). A relative value is a sub-directory of [base]; an absolute one is kept only
         * when it already lies under [base], else read as a sub-directory name. Anything that escapes [base] fails.
         */
        fun resolveOutputDirectory(base: File, requested: String): File {
            val root = base.canonicalFile
            val asGiven = File(requested)
            val candidate = when {
                !asGiven.isAbsolute -> File(root, requested)
                asGiven.canonicalFile.toPath().startsWith(root.toPath()) -> asGiven
                else -> File(root, requested.trimStart('/'))
            }.canonicalFile
            require(candidate.toPath().startsWith(root.toPath())) { "speechBenchmarkOut must stay inside the app files directory" }
            return candidate
        }

        /** Resolves and creates the report directory before the first scenario, so a bad path fails at once. */
        fun prepareOutputDirectory(base: File, requested: String): File {
            val directory = resolveOutputDirectory(base, requested)
            check(directory.isDirectory || directory.mkdirs()) { "Cannot create ${directory.path}" }
            return directory
        }

        /** Nearest rank: index `ceil(q * n) - 1` of the ascending values. [sorted] must not be empty. */
        fun percentile(sorted: List<Double>, q: Double): Double = sorted[(ceil(q * sorted.size).toInt() - 1).coerceIn(0, sorted.size - 1)]

        /** The hardware model id, `MANUFACTURER MODEL`. Never the device's user-assigned name. */
        fun hardwareModel(): String = "${Build.MANUFACTURER} ${Build.MODEL}".trim().ifEmpty { "unknown" }

        /** Per `(scenario, step, utterance)`, so a cold call is never pooled with warm ones. */
        private fun percentiles(samples: List<Sample>, q: Double): List<Percentile> = samples.groupBy { Triple(it.scenario, it.step, it.utteranceId) }.map { (key, group) ->
            val metrics = LinkedHashMap<String, Double>()
            for (name in group.flatMap { it.metrics.keys }.distinct()) {
                val values = group.mapNotNull { it.metrics[name] }.sorted()
                if (values.isNotEmpty()) metrics[name] = percentile(values, q)
            }
            Percentile(key.first, key.second, key.third, metrics)
        }

        /** Anything outside `[A-Za-z0-9._-]` becomes `-`. */
        private fun fileSafe(value: String): String = value.map { c ->
            if (c in 'a'..'z' || c in 'A'..'Z' || c in '0'..'9' || c == '.' || c == '_' || c == '-') c else '-'
        }.joinToString("")
    }
}

/**
 * Samples the process's resident set size every [intervalMs] between [start] and [stop], and reports
 * how far the peak rose above the size at [start].
 */
class PeakRssSampler(
    private val read: () -> Long = ::vmRssBytes,
    private val intervalMs: Long = 20,
) {
    private val lock = Any()
    private var baseline = 0L
    private var peak = 0L
    private var polling: Thread? = null

    fun start() {
        check(polling == null) { "PeakRssSampler is already started" }
        val first = read()
        synchronized(lock) {
            baseline = first
            peak = first
        }
        polling = Thread {
            try {
                while (!Thread.currentThread().isInterrupted) {
                    Thread.sleep(intervalMs)
                    sample()
                }
            } catch (_: InterruptedException) {
                // stop() ends the loop this way.
            }
        }.apply {
            isDaemon = true
            start()
        }
    }

    /** Reads once more and folds the reading into the peak. The polling thread calls this every [intervalMs]. */
    fun sample() {
        val value = read()
        synchronized(lock) { peak = maxOf(peak, value) }
    }

    /** Stops polling and returns the peak minus the size at [start], at least 0. */
    fun stop(): Long {
        polling?.interrupt()
        polling = null
        sample()
        return synchronized(lock) { maxOf(0L, peak - baseline) }
    }
}

/** The process's resident set size in bytes, from the `VmRSS:` line of `/proc/self/status`; 0 when unreadable. */
fun vmRssBytes(): Long = try {
    parseVmRssBytes(File("/proc/self/status").readText())
} catch (_: java.io.IOException) {
    0L
}

/** The `VmRSS:` line of a `/proc/<pid>/status` text (`VmRSS:  12345 kB`) in bytes; 0 when absent. */
fun parseVmRssBytes(status: String): Long {
    val line = status.lineSequence().firstOrNull { it.startsWith("VmRSS:") } ?: return 0L
    val kilobytes = line.split(' ', '\t').filter { it.isNotEmpty() }.getOrNull(1)?.toLongOrNull() ?: return 0L
    return kilobytes * 1024
}
