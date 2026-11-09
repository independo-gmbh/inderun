package app.independo.inderun.sdk

import android.content.Context
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.contracts.PrepareRequest
import app.independo.inderun.contracts.Privacy
import app.independo.inderun.contracts.SpeechVoice
import app.independo.inderun.contracts.TaskKind
import app.independo.inderun.core.HostServicesFactory
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderAdapter
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.providers.neuralspeech.NeuralSpeechProvider
import app.independo.inderun.providers.onnx.OnnxNeuralSpeechRuntime
import app.independo.inderun.providers.systemspeech.AndroidSystemSpeechProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.time.Instant
import kotlin.math.roundToLong

/**
 * The latency scenarios of the shared corpus (`benchmark` in
 * `contracts/fixtures/speech/utterance-corpus.json`, #251), run through the public speech API
 * against every entry of [targets]. The Android counterpart of `SpeechBenchmarkTests.swift`.
 *
 * Opt-in, because the scenarios play audio for minutes:
 * `./gradlew :inderun-kotlin:connectedAndroidTest -Pandroid.testInstrumentationRunnerArguments.speechBenchmark=true`.
 * Each sample logs one `INDERUN-BENCH` line and each scenario one `INDERUN-BENCH-SUMMARY` line
 * under the `IndeRunBenchmark` tag, with ids and measurements but never utterance text.
 *
 * Instrumentation arguments (all optional, besides `speechBenchmark`):
 * - `speechBenchmarkModelDir`: a model package directory on the device; adds a neural ONNX target.
 * - `speechBenchmarkModelId`: the model catalog entry id to record for the neural target (for example
 *   `articulino-de-en-int8`); default is the package id.
 * - `speechBenchmarkOut`: a directory name under the app's external files directory
 *   (`Context.getExternalFilesDir(null)`, the only place the test app can write; an absolute path is kept
 *   only when it already lies under it). It is created before the first scenario, and each target writes
 *   one [SpeechBenchmarkReport] there. The log prints the absolute path of every file; fetch them with
 *   `adb pull /sdcard/Android/data/<test app package>/files/<name>`, before the test app is uninstalled.
 * - `speechBenchmarkSdkVersion`: the SDK version to record, default `dev`.
 */
@RunWith(AndroidJUnit4::class)
class SpeechBenchmarkTest {
    /**
     * What a benchmark runs against: a provider, optionally pinned to one voice. Any provider that
     * declares `text_to_speech` fits, for example a neural ONNX provider or a second installed TTS
     * engine. Add an entry here to compare it; the scenarios stay the same.
     */
    private data class Target(
        val name: String,
        val makeProvider: (Context) -> Built,
        val voice: SpeechVoice? = null,
        val execution: SpeechExecutionOptions = SpeechExecutionOptions(privacy = Privacy.LocalRequired),
        val model: String? = null,
        val variant: String? = null,
        val checksums: Map<String, String>? = null,
        val locality: String = "on_device",
        /** Also renders the corpus's `extendedUtterances` once in `render_speed`. */
        val rendersExtended: Boolean = false,
    )

    /**
     * A provider and what was created for it alone, such as the runtime it runs on. The provider
     * does not close that, so whoever made the [Built] closes it ([close]).
     */
    private class Built(val provider: ProviderAdapter, private val owned: List<AutoCloseable> = emptyList()) {
        fun close() {
            (provider as? AutoCloseable)?.close()
            owned.forEach { it.close() }
        }
    }

    private fun targets(arguments: Bundle): List<Target> {
        val targets = mutableListOf(
            Target("android_system_speech", { context -> Built(AndroidSystemSpeechProvider(context)) }),
        )
        arguments.getString("speechBenchmarkModelDir")?.let {
            targets += neuralTarget(loadModelPackage(it), arguments.getString("speechBenchmarkModelId"))
        }
        return targets
    }

    /** The package, run through the neural speech provider on the ONNX runtime. */
    private fun neuralTarget(modelPackage: ModelPackage, modelId: String?) = Target(
        name = "articulino_${modelPackage.variant ?: "default"}",
        // Each trial gets a runtime of its own, so no trial inherits another's loaded sessions; the
        // trial closes it (Built.close).
        makeProvider = { context ->
            val runtime = OnnxNeuralSpeechRuntime(context)
            Built(NeuralSpeechProvider(modelPackage, runtime), listOf(runtime))
        },
        model = modelId ?: modelPackage.id,
        variant = modelPackage.variant,
        checksums = modelPackage.integrity?.checksums,
        rendersExtended = true,
    )

    private data class Utterance(val id: String, val locale: String, val text: String)

    private data class Scenario(
        val id: String,
        val delivery: String,
        val utteranceIds: List<String>,
        val trials: Int,
        val cancelAfterMs: Long?,
    )

    private val context: Context = ApplicationProvider.getApplicationContext()
    private val scope = CoroutineScope(Dispatchers.Default)
    private val corpus = JSONObject(context.assets.open("utterance-corpus.json").bufferedReader().use { it.readText() })
    private val utterances = corpus.getJSONArray("utterances").objects().map {
        Utterance(it.getString("id"), it.getString("locale"), it.getString("text"))
    }
    private val extendedUtterances = corpus.optJSONArray("extendedUtterances")?.objects().orEmpty().map {
        Utterance(it.getString("id"), it.getString("locale"), it.getString("text"))
    }
    private val scenarios = corpus.getJSONObject("benchmark").getJSONArray("scenarios").objects().map {
        Scenario(
            id = it.getString("id"),
            delivery = it.getString("delivery"),
            utteranceIds = it.getJSONArray("utteranceIds").let { ids -> (0 until ids.length()).map(ids::getString) },
            trials = it.getInt("trials"),
            cancelAfterMs = if (it.has("cancelAfterMs")) it.getLong("cancelAfterMs") else null,
        )
    }

    private class Run(
        val scenario: Scenario,
        val target: Target,
        val utterances: List<Utterance>,
        val extendedUtterances: List<Utterance>,
        val context: Context,
    ) {
        val samples = mutableListOf<SpeechBenchmarkReport.Sample>()

        /** Every engine this run built that is still open, with the provider made for it. */
        private val open = mutableListOf<Pair<IndeRun, Built>>()

        fun utterance(index: Int) = utterances.single { it.id == scenario.utteranceIds[index] }

        fun engine(): IndeRun {
            val made = target.makeProvider(context)
            return IndeRun(ProviderRegistry().apply { register(made.provider) }, HostServicesFactory.create(context))
                .also { open += it to made }
        }

        /**
         * Runs one trial on an engine of its own and closes it, with its provider and runtime, when
         * the trial ends, so a later trial does not run beside an earlier one's loaded sessions.
         */
        suspend fun trial(body: suspend (IndeRun) -> Unit) {
            val engine = engine()
            try {
                body(engine)
            } finally {
                close(engine)
            }
        }

        private suspend fun close(engine: IndeRun) {
            val entry = open.firstOrNull { it.first === engine } ?: return
            open.remove(entry)
            entry.first.close()
            entry.second.close()
        }

        fun options(utterance: Utterance) = SpeakOptions(utterance.text, locale = utterance.locale, voice = target.voice, execution = target.execution)

        fun record(
            step: String,
            utterance: Utterance,
            metrics: Map<String, Double?>,
            resolvedLocale: String? = null,
            peakRssDeltaBytes: Long? = null,
        ) {
            val values = metrics.mapNotNull { (name, value) -> value?.let { name to it } }.toMap().toMutableMap()
            peakRssDeltaBytes?.let { values["peakRssDeltaBytes"] = it.toDouble() }
            samples += SpeechBenchmarkReport.Sample(
                scenario = scenario.id,
                step = step,
                utteranceId = utterance.id,
                requestedLocale = utterance.locale,
                resolvedLocale = resolvedLocale,
                metrics = values,
                target = target.name,
            )
        }

        /** Runs [body] while sampling the process's resident set size, and returns the rise above its start. */
        suspend fun <T> measuringPeak(body: suspend () -> T): Pair<T, Long> {
            val sampler = PeakRssSampler()
            sampler.start()
            try {
                val value = body()
                return value to sampler.stop()
            } catch (error: Throwable) {
                sampler.stop()
                throw error
            }
        }

        /** Speaks to the end and records what the call took. */
        suspend fun speak(engine: IndeRun, index: Int, step: String, scope: CoroutineScope) {
            val utterance = utterance(index)
            val started = System.nanoTime()
            val (ending, peak) = measuringPeak { engine.speak(options(utterance), scope).result.await() }
            record(
                step,
                utterance,
                mapOf(
                    "firstChunkMs" to ending.timing?.firstChunkMs,
                    "firstAudioMs" to ending.timing?.firstAudioMs,
                    "wallMs" to elapsedMs(started),
                    "durationMs" to ending.timing?.durationMs,
                ),
                resolvedLocale = ending.speech?.locale,
                peakRssDeltaBytes = peak,
            )
        }

        /** Renders to an artifact once and records what the render took. */
        suspend fun render(engine: IndeRun, utterance: Utterance, step: String) {
            val started = System.nanoTime()
            val (speech, peak) = measuringPeak { engine.generateSpeech(GenerateSpeechOptions(options(utterance))) }
            val renderMs = elapsedMs(started)
            engine.disposeArtifact(speech.artifact)
            val audioMs = speech.artifact.durationMs
            record(
                step,
                utterance,
                mapOf(
                    "renderMs" to renderMs,
                    "audioMs" to audioMs,
                    "realTimeFactor" to SpeechBenchmarkReport.realTimeFactor(renderMs, audioMs),
                    "bytes" to speech.artifact.byteLength?.toDouble(),
                ),
                resolvedLocale = speech.speech?.locale,
                peakRssDeltaBytes = peak,
            )
        }

        /** Closes every engine this run built that is still open, each with its provider and runtime. */
        suspend fun close() {
            open.toList().forEach { (engine, _) -> close(engine) }
        }
    }

    /** One handler per scenario id. The `setup` text in the fixture is what each one does. */
    private val handlers: Map<String, suspend (Run) -> Unit> = mapOf(
        "first_call_cold" to { run ->
            repeat(run.scenario.trials) { trial ->
                run.trial { engine -> run.speak(engine, 0, if (trial == 0) "first in process" else "new instance", scope) }
            }
        },
        "first_call_after_prepare" to { run ->
            repeat(run.scenario.trials) { trial ->
                run.trial { engine ->
                    val utterance = run.utterance(0)
                    val started = System.nanoTime()
                    val (_, peak) = run.measuringPeak {
                        engine.prepare(
                            scope,
                            PrepareRequest(tasks = listOf(TaskKind.TEXT_TO_SPEECH.rawValue), locale = utterance.locale),
                        ).result.await()
                    }
                    val label = if (trial == 0) "first in process" else "new instance"
                    run.record("prepare, $label", utterance, mapOf("prepareMs" to elapsedMs(started)), peakRssDeltaBytes = peak)
                    run.speak(engine, 0, label, scope)
                }
            }
        },
        "repeat_same_voice" to { run ->
            val engine = run.engine()
            for (call in 1..run.scenario.trials) run.speak(engine, 0, "call $call", scope)
        },
        "switch_language" to { run ->
            val engine = run.engine()
            run.scenario.utteranceIds.indices.forEach { index ->
                run.speak(engine, index, "call ${index + 1} (${run.utterance(index).locale})", scope)
            }
        },
        "speak_after_stop" to { run ->
            val engine = run.engine()
            run.speak(engine, 1, "warm-up", scope)
            repeat(run.scenario.trials) {
                val long = run.utterance(0)
                val playback = engine.speak(run.options(long), scope)
                delay(run.scenario.cancelAfterMs ?: 1500)
                val stopIssued = System.nanoTime()
                playback.cancel("benchmark stop")
                val stopped = playback.result.await()
                // Playback that ended before the stop has no stop latency to report, and is not a failure.
                if (stopped.finishReason == FinishReason.CANCELLED) {
                    run.record("stop", long, mapOf("stopLatencyMs" to elapsedMs(stopIssued)), resolvedLocale = stopped.speech?.locale)
                }
                run.speak(engine, 1, "next after stop", scope)
            }
        },
        "text_length" to { run ->
            val engine = run.engine()
            run.speak(engine, 0, "warm-up", scope)
            run.scenario.utteranceIds.indices.forEach { index ->
                run.speak(engine, index, if (index == 0) "short" else "long", scope)
            }
        },
        "render_speed" to { run ->
            val engine = run.engine()
            run.scenario.utteranceIds.indices.forEach { index ->
                val utterance = run.utterance(index)
                for (trial in 0..run.scenario.trials) run.render(engine, utterance, if (trial == 0) "cold" else "warm")
            }
            // The neural target renders its extended sentences once each, on the warmed engine.
            if (run.target.rendersExtended) run.extendedUtterances.forEach { run.render(engine, it, "extended") }
        },
    )

    @Test
    fun implementsEveryBenchmarkScenarioAndNoOthers() {
        assertEquals(scenarios.map { it.id }.sorted(), handlers.keys.sorted())
    }

    @Test
    fun runsEveryScenarioAgainstEveryTarget() = runBlocking {
        val arguments = InstrumentationRegistry.getArguments()
        assumeTrue("Opt-in: pass -Pandroid.testInstrumentationRunnerArguments.speechBenchmark=true.", arguments.getString("speechBenchmark") == "true")
        val outDirectory = arguments.getString("speechBenchmarkOut")?.let { requested ->
            val base = checkNotNull(context.getExternalFilesDir(null)) { "The app has no external files directory" }
            SpeechBenchmarkReport.prepareOutputDirectory(base, requested).also { Log.i(TAG, "INDERUN-BENCH-OUT android ${it.absolutePath}") }
        }
        for (target in targets(arguments)) {
            val samples = mutableListOf<SpeechBenchmarkReport.Sample>()
            val skipped = mutableListOf<Pair<String, String>>()
            val (providerId, declared) = target.makeProvider(context).let { made ->
                val descriptor = made.provider.describe()
                val delivery = descriptor.taskCapabilities.orEmpty()
                    .filter { it.kind == TaskKind.TEXT_TO_SPEECH.rawValue }
                    .flatMap { it.outputs }
                    .map { it.delivery.rawValue }
                    .toSet()
                made.close()
                descriptor.id to delivery
            }
            for (scenario in scenarios) {
                if (scenario.delivery !in declared) {
                    val reason = "no ${scenario.delivery} delivery"
                    Log.i(TAG, "INDERUN-BENCH-SUMMARY android ${target.name} ${scenario.id} unsupported: $reason")
                    skipped += scenario.id to reason
                    continue
                }
                val run = Run(scenario, target, utterances, extendedUtterances, context)
                try {
                    handlers.getValue(scenario.id)(run)
                    report(run)
                    samples += run.samples
                } catch (error: IndeRunException) {
                    if (error.errorClass != IndeRunErrorClass.CapabilityMismatch) throw error
                    val reason = SpeechBenchmarkReport.skipReason(error)
                    Log.i(TAG, "INDERUN-BENCH-SUMMARY android ${target.name} ${scenario.id} unavailable: $reason")
                    skipped += scenario.id to reason
                } finally {
                    run.close()
                }
            }
            outDirectory?.let { directory ->
                val written = SpeechBenchmarkReport.build(
                    harness = "sdk_tests",
                    device = SpeechBenchmarkReport.hardwareModel(),
                    os = "Android ${Build.VERSION.RELEASE}",
                    sdkVersion = arguments.getString("speechBenchmarkSdkVersion") ?: "dev",
                    target = SpeechBenchmarkReport.Target(
                        name = target.name,
                        providerId = providerId,
                        model = target.model,
                        variant = target.variant,
                        checksums = target.checksums,
                        voiceId = target.voice?.id,
                    ),
                    locality = target.locality,
                    samples = samples,
                    skipped = skipped,
                    createdAt = Instant.now(),
                ).write(directory)
                Log.i(TAG, "INDERUN-BENCH-REPORT android ${target.name} ${written.absolutePath}")
            }
        }
    }

    private fun report(run: Run) {
        for (sample in run.samples) {
            val fields = JSONObject()
                .put("scenario", run.scenario.id)
                .put("target", run.target.name)
                .put("step", sample.step)
                .put("utteranceId", sample.utteranceId)
            sample.metrics.forEach { (name, value) -> fields.put(name, (value * 10).roundToLong() / 10.0) }
            Log.i(TAG, "INDERUN-BENCH android $fields")
        }
        // Grouped by step, so a cold call is never averaged with warm ones.
        run.samples.groupBy { "${it.step} · ${it.utteranceId}" }.forEach { (key, group) ->
            val summary = group.flatMap { it.metrics.keys }.toSortedSet().joinToString("; ") { name ->
                val values = group.mapNotNull { it.metrics[name] }.sorted()
                "$name median ${format(values[values.size / 2])} max ${format(values.last())} n ${values.size}"
            }
            Log.i(TAG, "INDERUN-BENCH-SUMMARY android ${run.target.name} ${run.scenario.id} [$key] $summary")
        }
    }

    private fun format(value: Double) = if (value < 10) "%.2f".format(value) else value.roundToLong().toString()

    private companion object {
        const val TAG = "IndeRunBenchmark"

        fun elapsedMs(startedNanos: Long) = (System.nanoTime() - startedNanos) / 1_000_000.0

        fun JSONArray.objects() = (0 until length()).map(::getJSONObject)
    }
}
