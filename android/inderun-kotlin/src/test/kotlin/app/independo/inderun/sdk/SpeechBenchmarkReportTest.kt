package app.independo.inderun.sdk

import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.core.IndeRunException
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File
import java.nio.file.Files
import java.time.Instant

/** The report builder behind `SpeechBenchmarkTest` (#276). Not gated: it measures nothing. */
@RunWith(RobolectricTestRunner::class)
class SpeechBenchmarkReportTest {
    private val target = SpeechBenchmarkReport.Target(name = "system", providerId = "android_system_speech")

    // 2027-01-15T08:00:00Z
    private val createdAt = Instant.ofEpochSecond(1_800_000_000)

    private fun sample(
        scenario: String,
        step: String,
        metrics: Map<String, Double> = emptyMap(),
        utterance: String = "u1",
        requested: String = "de-DE",
        resolved: String? = null,
    ) = SpeechBenchmarkReport.Sample(scenario, step, utterance, requested, resolved, metrics)

    private fun build(
        samples: List<SpeechBenchmarkReport.Sample>,
        skipped: List<Pair<String, String>> = emptyList(),
        device: String = "Google Pixel 9",
        target: SpeechBenchmarkReport.Target = this.target,
    ) = SpeechBenchmarkReport.build(
        harness = "sdk_tests",
        device = device,
        os = "Android 16",
        sdkVersion = "dev",
        target = target,
        locality = "on_device",
        samples = samples,
        skipped = skipped,
        createdAt = createdAt,
    )

    private fun JSONArray.objects() = (0 until length()).map { getJSONObject(it) }

    private fun JSONArray.strings() = (0 until length()).map { getString(it) }

    @Test
    fun percentileNearestRank() {
        val ten = (1..10).map { it.toDouble() }
        assertEquals(5.0, SpeechBenchmarkReport.percentile(ten, 0.5), 0.0)
        assertEquals(10.0, SpeechBenchmarkReport.percentile(ten, 0.95), 0.0)
        assertEquals(7.0, SpeechBenchmarkReport.percentile(listOf(7.0), 0.5), 0.0)
        assertEquals(7.0, SpeechBenchmarkReport.percentile(listOf(7.0), 0.95), 0.0)
    }

    @Test
    fun groupsByScenarioStepUtterance() {
        val report = build(
            listOf(
                sample("repeat", "cold", mapOf("wallMs" to 900.0)),
                sample("repeat", "cold", mapOf("wallMs" to 1100.0)),
                sample("repeat", "warm", mapOf("wallMs" to 100.0)),
                sample("repeat", "warm", mapOf("wallMs" to 120.0)),
                sample("repeat", "warm", mapOf("wallMs" to 110.0)),
            ),
        )
        assertEquals(2, report.p50.size)
        assertEquals(900.0, report.p50.single { it.step == "cold" }.metrics["wallMs"]!!, 0.0)
        assertEquals(110.0, report.p50.single { it.step == "warm" }.metrics["wallMs"]!!, 0.0)
        assertEquals(1100.0, report.p95.single { it.step == "cold" }.metrics["wallMs"]!!, 0.0)
        assertEquals(120.0, report.p95.single { it.step == "warm" }.metrics["wallMs"]!!, 0.0)
    }

    @Test
    fun singleSampleGivesEqualPercentiles() {
        val report = build(listOf(sample("s", "warm", mapOf("wallMs" to 42.0))))
        assertEquals(42.0, report.p50.single().metrics["wallMs"]!!, 0.0)
        assertEquals(42.0, report.p95.single().metrics["wallMs"]!!, 0.0)
    }

    @Test
    fun emptySamplesGiveEmptyPercentiles() {
        val report = build(emptyList())
        assertTrue(report.p50.isEmpty())
        assertTrue(report.p95.isEmpty())
        val json = report.toJson()
        assertEquals(0, json.getJSONArray("p50").length())
        assertEquals(0, json.getJSONArray("samples").length())
    }

    @Test
    fun skippedScenarioIsListedAndAbsentFromPercentiles() {
        val report = build(
            listOf(sample("repeat", "warm", mapOf("wallMs" to 100.0))),
            skipped = listOf("speak_after_stop" to "no streaming delivery"),
        )
        val skipped = report.toJson().getJSONArray("skipped").objects()
        assertEquals(1, skipped.size)
        assertEquals("speak_after_stop", skipped.single().getString("scenario"))
        assertEquals("no streaming delivery", skipped.single().getString("reason"))
        assertFalse(report.p50.any { it.scenario == "speak_after_stop" })
        assertFalse(report.p95.any { it.scenario == "speak_after_stop" })
    }

    @Test
    fun reportNeverContainsUtteranceText() {
        val corpus = JSONObject(corpusFile().readText())
        val entries = corpus.getJSONArray("utterances").objects() +
            (corpus.optJSONArray("extendedUtterances")?.objects() ?: emptyList())
        assertTrue(entries.isNotEmpty())
        val samples = entries.map {
            sample("render_speed", "warm", mapOf("wallMs" to 1.0), utterance = it.getString("id"), requested = it.getString("locale"))
        }
        val text = build(samples).toJson().toString(2)
        for (entry in entries) {
            assertFalse("report leaked text of ${entry.getString("id")}", text.contains(entry.getString("text")))
        }
    }

    @Test
    fun requestedAndResolvedLocalesAreDistinctFirstSeen() {
        val report = build(
            listOf(
                sample("s", "a", requested = "de-DE", resolved = "de-DE"),
                sample("s", "b", requested = "en-US", resolved = "en-US"),
                sample("s", "c", requested = "de-DE", resolved = "de-DE"),
            ),
        )
        assertEquals(listOf("de-DE", "en-US"), report.requestedLocales)
        assertEquals(listOf("de-DE", "en-US"), report.resolvedLocales)
    }

    @Test
    fun encodedReportUsesSchemaShape() {
        val json = build(listOf(sample("s", "warm", mapOf("wallMs" to 5.0), resolved = "de-DE"))).toJson()
        assertEquals("inderun-speech-benchmark/1", json.getString("schema"))
        assertEquals("sdk_tests", json.getString("harness"))
        assertEquals("on_device", json.getString("locality"))
        assertEquals("2027-01-15T08:00:00Z", json.getString("createdAt"))
        assertEquals(listOf("de-DE"), json.getJSONArray("requestedLocale").strings())
        assertEquals(listOf("de-DE"), json.getJSONArray("resolvedLocale").strings())
        val first = json.getJSONArray("samples").getJSONObject(0)
        assertEquals(5.0, first.getDouble("wallMs"), 0.0)
        assertFalse(first.has("target"))
        assertFalse(first.has("firstAudioMs"))
    }

    @Test
    fun targetOptionalFieldsAreOmittedUnlessSet() {
        val plain = build(emptyList()).toJson().getJSONObject("target")
        assertEquals(setOf("name", "providerId"), plain.keys().asSequence().toSet())
        val full = SpeechBenchmarkReport.Target(
            "articulino_int8",
            "neural",
            model = "articulino",
            variant = "int8",
            checksums = mapOf("text.onnx" to "sha256:" + "a".repeat(64)),
        )
        val json = build(emptyList(), target = full).toJson().getJSONObject("target")
        assertEquals("int8", json.getString("variant"))
        assertEquals("sha256:" + "a".repeat(64), json.getJSONObject("checksums").getString("text.onnx"))
    }

    @Test
    fun writeCreatesMissingDirectoryAndOneFilePerTarget() {
        val root = Files.createTempDirectory("speech-bench").toFile()
        val directory = File(File(root, "missing"), "nested")
        try {
            assertFalse(directory.exists())
            val other = SpeechBenchmarkReport.Target("articulino_onnx-int8", "neural")
            val first = build(emptyList(), device = "Google Pixel 9 (Bob's)").write(directory)
            val second = build(emptyList(), device = "Pixel9", target = other).write(directory)
            assertNotEquals(first, second)
            assertEquals("sdk_tests-system-Google-Pixel-9--Bob-s--2027-01-15.json", first.name)
            assertEquals("sdk_tests-articulino_onnx-int8-Pixel9-2027-01-15.json", second.name)
            assertEquals(2, directory.listFiles()!!.size)
            assertEquals("inderun-speech-benchmark/1", JSONObject(first.readText()).getString("schema"))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun skipReasonKeepsTheClassAndCodeNeverTheMessage() {
        val withCode = IndeRunException(IndeRunErrorClass.CapabilityMismatch, "could not say: private words", details = mapOf("code" to "no_delivery"))
        assertEquals("CapabilityMismatch: no_delivery", SpeechBenchmarkReport.skipReason(withCode))
        val bare = IndeRunException(IndeRunErrorClass.CapabilityMismatch, "private words")
        assertEquals("CapabilityMismatch", SpeechBenchmarkReport.skipReason(bare))
        assertEquals("IllegalStateException", SpeechBenchmarkReport.skipReason(IllegalStateException("private words")))
    }

    @Test
    fun realTimeFactorNeedsPositiveAudio() {
        assertEquals(0.05, SpeechBenchmarkReport.realTimeFactor(100.0, 2000.0)!!, 1e-9)
        assertEquals(null, SpeechBenchmarkReport.realTimeFactor(100.0, 0.0))
        assertEquals(null, SpeechBenchmarkReport.realTimeFactor(100.0, null))
    }

    @Test
    fun nonFiniteMetricsAreDroppedFromSamples() {
        val report = build(listOf(sample("s", "a", mapOf("wallMs" to 5.0, "realTimeFactor" to Double.POSITIVE_INFINITY, "renderMs" to Double.NaN))))
        assertEquals(mapOf("wallMs" to 5.0), report.samples[0].metrics)
        assertEquals(5.0, report.toJson().getJSONArray("samples").getJSONObject(0).getDouble("wallMs"), 0.0)
    }

    @Test
    fun outputDirectoryIsRelativeToTheAppFilesDirectory() {
        val base = Files.createTempDirectory("speech-ext").toFile()
        try {
            val canonical = base.canonicalFile
            assertEquals(File(canonical, "bench"), SpeechBenchmarkReport.resolveOutputDirectory(base, "bench"))
            assertEquals(File(canonical, "a/b"), SpeechBenchmarkReport.resolveOutputDirectory(base, "a/b"))
            // An absolute path under the base is kept; one outside it is read as a sub-directory name.
            assertEquals(File(canonical, "x"), SpeechBenchmarkReport.resolveOutputDirectory(base, File(canonical, "x").path))
            assertEquals(File(canonical, "sdcard/out"), SpeechBenchmarkReport.resolveOutputDirectory(base, "/sdcard/out"))
            assertTrue(runCatching { SpeechBenchmarkReport.resolveOutputDirectory(base, "../escape") }.isFailure)
        } finally {
            base.deleteRecursively()
        }
    }

    @Test
    fun prepareOutputDirectoryCreatesItAndRejectsAFile() {
        val base = Files.createTempDirectory("speech-ext").toFile()
        try {
            val made = SpeechBenchmarkReport.prepareOutputDirectory(base, "a/b")
            assertTrue(made.isDirectory)
            File(base, "plain").writeText("x")
            assertTrue(runCatching { SpeechBenchmarkReport.prepareOutputDirectory(base, "plain") }.isFailure)
        } finally {
            base.deleteRecursively()
        }
    }

    @Test
    fun peakRssSamplerReportsPeakMinusStart() {
        val values = ReadingSequence(100, 180, 150)
        // An hour-long interval keeps the polling thread out of the way, so the readings are exact.
        val sampler = PeakRssSampler(read = { values.next() }, intervalMs = 3_600_000)
        sampler.start()
        sampler.sample()
        sampler.sample()
        assertEquals(80L, sampler.stop())
    }

    @Test
    fun peakRssSamplerClampsAtZero() {
        val values = ReadingSequence(100, 60)
        val sampler = PeakRssSampler(read = { values.next() }, intervalMs = 3_600_000)
        sampler.start()
        assertEquals(0L, sampler.stop())
    }

    @Test
    fun parsesVmRssFromProcStatus() {
        val status = "Name:\tapp\nVmPeak:\t  999 kB\nVmRSS:\t  12345 kB\nThreads:\t4\n"
        assertEquals(12345L * 1024, parseVmRssBytes(status))
        assertEquals(0L, parseVmRssBytes("Name:\tapp\n"))
    }

    @Test
    fun hardwareModelIsNotEmpty() {
        assertTrue(SpeechBenchmarkReport.hardwareModel().isNotBlank())
    }

    /** The shared corpus, found by walking up from the module directory. */
    private fun corpusFile(): File {
        var directory: File? = File("").absoluteFile
        while (directory != null) {
            val candidate = File(directory, "contracts/fixtures/speech/utterance-corpus.json")
            if (candidate.exists()) return candidate
            directory = directory.parentFile
        }
        error("Could not locate contracts/fixtures/speech/utterance-corpus.json")
    }
}

/** Hands out the given readings in order, then repeats the last. */
private class ReadingSequence(vararg values: Long) {
    private val remaining = values.toMutableList()

    @Synchronized
    fun next(): Long = if (remaining.size > 1) remaining.removeAt(0) else remaining[0]
}
