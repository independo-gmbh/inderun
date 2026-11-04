package app.independo.inderun.sdk

import android.content.Context
import android.util.Log
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.PrepareRequest
import app.independo.inderun.contracts.Privacy
import app.independo.inderun.contracts.SpeechVoice
import app.independo.inderun.contracts.TaskKind
import app.independo.inderun.core.HostServicesFactory
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderAdapter
import app.independo.inderun.core.ProviderRegistry
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
        val makeProvider: (Context) -> ProviderAdapter,
        val voice: SpeechVoice? = null,
        val execution: SpeechExecutionOptions = SpeechExecutionOptions(privacy = Privacy.LocalRequired),
    )

    private val targets = listOf(
        Target("android_system_speech", { context -> AndroidSystemSpeechProvider(context) }),
    )

    private data class Utterance(val id: String, val locale: String, val text: String)

    private data class Scenario(
        val id: String,
        val delivery: String,
        val utteranceIds: List<String>,
        val trials: Int,
        val cancelAfterMs: Long?,
    )

    private data class Sample(val step: String, val utteranceId: String, val metrics: Map<String, Double>)

    private val context: Context = ApplicationProvider.getApplicationContext()
    private val scope = CoroutineScope(Dispatchers.Default)
    private val corpus = JSONObject(context.assets.open("utterance-corpus.json").bufferedReader().use { it.readText() })
    private val utterances = corpus.getJSONArray("utterances").objects().map {
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

    private class Run(val scenario: Scenario, val target: Target, val utterances: List<Utterance>, val context: Context) {
        val samples = mutableListOf<Sample>()
        private val providers = mutableListOf<ProviderAdapter>()

        fun utterance(index: Int) = utterances.single { it.id == scenario.utteranceIds[index] }

        fun engine(): IndeRun {
            val provider = target.makeProvider(context).also { providers += it }
            return IndeRun(ProviderRegistry().apply { register(provider) }, HostServicesFactory.create(context))
        }

        fun options(utterance: Utterance) = SpeakOptions(utterance.text, locale = utterance.locale, voice = target.voice, execution = target.execution)

        fun record(step: String, utterance: Utterance, metrics: Map<String, Double?>) {
            @Suppress("UNCHECKED_CAST")
            samples += Sample(step, utterance.id, metrics.filterValues { it != null } as Map<String, Double>)
        }

        /** Speaks to the end and records what the call took. */
        suspend fun speak(engine: IndeRun, index: Int, step: String, scope: CoroutineScope) {
            val utterance = utterance(index)
            val started = System.nanoTime()
            val ending = engine.speak(options(utterance), scope).result.await()
            record(
                step,
                utterance,
                mapOf(
                    "firstAudioMs" to ending.timing?.firstAudioMs,
                    "wallMs" to elapsedMs(started),
                    "durationMs" to ending.timing?.durationMs,
                ),
            )
        }

        fun close() = providers.forEach { (it as? AutoCloseable)?.close() }
    }

    /** One handler per scenario id. The `setup` text in the fixture is what each one does. */
    private val handlers: Map<String, suspend (Run) -> Unit> = mapOf(
        "first_call_cold" to { run ->
            repeat(run.scenario.trials) { trial ->
                run.speak(run.engine(), 0, if (trial == 0) "first in process" else "new instance", scope)
            }
        },
        "first_call_after_prepare" to { run ->
            repeat(run.scenario.trials) { trial ->
                val engine = run.engine()
                val utterance = run.utterance(0)
                val started = System.nanoTime()
                engine.prepare(
                    scope,
                    PrepareRequest(tasks = listOf(TaskKind.TEXT_TO_SPEECH.rawValue), locale = utterance.locale),
                ).result.await()
                val label = if (trial == 0) "first in process" else "new instance"
                run.record("prepare, $label", utterance, mapOf("prepareMs" to elapsedMs(started)))
                run.speak(engine, 0, label, scope)
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
                assertEquals(FinishReason.CANCELLED, playback.result.await().finishReason)
                run.record("stop", long, mapOf("stopLatencyMs" to elapsedMs(stopIssued)))
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
                for (trial in 0..run.scenario.trials) {
                    val started = System.nanoTime()
                    val speech = engine.generateSpeech(GenerateSpeechOptions(run.options(utterance)))
                    val renderMs = elapsedMs(started)
                    engine.disposeArtifact(speech.artifact)
                    val audioMs = speech.artifact.durationMs
                    run.record(
                        if (trial == 0) "cold" else "warm",
                        utterance,
                        mapOf(
                            "renderMs" to renderMs,
                            "audioMs" to audioMs,
                            "realTimeFactor" to audioMs?.let { renderMs / it },
                            "bytes" to speech.artifact.byteLength?.toDouble(),
                        ),
                    )
                }
            }
        },
    )

    @Test
    fun implementsEveryBenchmarkScenarioAndNoOthers() {
        assertEquals(scenarios.map { it.id }.sorted(), handlers.keys.sorted())
    }

    @Test
    fun runsEveryScenarioAgainstEveryTarget() = runBlocking {
        val enabled = InstrumentationRegistry.getArguments().getString("speechBenchmark") == "true"
        assumeTrue("Opt-in: pass -Pandroid.testInstrumentationRunnerArguments.speechBenchmark=true.", enabled)
        for (target in targets) {
            val declared = target.makeProvider(context).let { provider ->
                provider.describe().taskCapabilities.orEmpty()
                    .filter { it.kind == TaskKind.TEXT_TO_SPEECH.rawValue }
                    .flatMap { it.outputs }
                    .map { it.delivery.rawValue }
                    .toSet()
                    .also { (provider as? AutoCloseable)?.close() }
            }
            for (scenario in scenarios) {
                if (scenario.delivery !in declared) {
                    Log.i(TAG, "INDERUN-BENCH-SUMMARY android ${target.name} ${scenario.id} unsupported: no ${scenario.delivery} delivery")
                    continue
                }
                val run = Run(scenario, target, utterances, context)
                try {
                    handlers.getValue(scenario.id)(run)
                    report(run)
                } catch (error: IndeRunException) {
                    if (error.errorClass != IndeRunErrorClass.CapabilityMismatch) throw error
                    Log.i(TAG, "INDERUN-BENCH-SUMMARY android ${target.name} ${scenario.id} unavailable: ${error.message}")
                } finally {
                    run.close()
                }
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
