package app.independo.inderun.providers.neuralspeech

import app.independo.inderun.contracts.Format
import app.independo.inderun.contracts.FrontendKind
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.contracts.Source
import app.independo.inderun.contracts.SourceType
import app.independo.inderun.contracts.SpeechFrontend
import app.independo.inderun.contracts.SpeechModelPackage
import app.independo.inderun.contracts.SpeechModelVoice
import app.independo.inderun.providers.neuralspeech.articulino.ArticulinoConfig
import app.independo.inderun.providers.neuralspeech.articulino.ArticulinoMath
import app.independo.inderun.providers.neuralspeech.articulino.ArticulinoRuntime
import app.independo.inderun.providers.neuralspeech.articulino.ArticulinoRuntimeOptions
import app.independo.inderun.providers.neuralspeech.articulino.NoiseSource
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs

/**
 * Runs `contracts/fixtures/speech/articulino-pipeline.json` against the Kotlin Articulino pipeline
 * with a scripted executor. One handler per case `kind`; the guard test fails when the handler kinds
 * and the fixture kinds differ. Mirrors the Swift and TypeScript conformance suites.
 *
 * Robolectric is required because `org.json` is stubbed in plain Android unit tests.
 */
@RunWith(RobolectricTestRunner::class)
class ArticulinoPipelineConformanceTest {
    private val fixture = loadFixture()

    @Test
    fun implementsEveryCaseKindInTheSharedFixtureAndNoOthers() {
        val kinds = fixture.cases.map { it.getString("kind") }.toSet()

        assertTrue(kinds.isNotEmpty())
        assertEquals(kinds, handlers.keys)
    }

    @Test
    fun everyFixtureCaseHasATestInThisClass() {
        val tested = setOf(
            "letters_de", "letters_en_quotes", "letters_accents_and_unknown", "durations_clamp_speed",
            "durations_rate_equalised", "frame_condition_overlap", "flow_steps", "postprocess_shelf_cut_limit_pause",
            "long_sentence_split", "end_to_end", "empty_after_letters", "cancel_between_graphs",
        )

        assertEquals(tested, fixture.cases.map { it.getString("id") }.toSet())
    }

    private fun run(id: String) = runTest {
        val entry = fixture.cases.first { it.getString("id") == id }
        val handler = handlers.getValue(entry.getString("kind"))
        handler(this@ArticulinoPipelineConformanceTest.fixture, entry)
    }

    @Test fun lettersDe() = run("letters_de")

    @Test fun lettersEnQuotes() = run("letters_en_quotes")

    @Test fun lettersAccentsAndUnknown() = run("letters_accents_and_unknown")

    @Test fun durationsClampSpeed() = run("durations_clamp_speed")

    @Test fun durationsRateEqualised() = run("durations_rate_equalised")

    @Test fun frameConditionOverlap() = run("frame_condition_overlap")

    @Test fun flowSteps() = run("flow_steps")

    @Test fun postprocessShelfCutLimitPause() = run("postprocess_shelf_cut_limit_pause")

    @Test fun longSentenceSplit() = run("long_sentence_split")

    @Test fun endToEnd() = run("end_to_end")

    @Test fun emptyAfterLetters() = run("empty_after_letters")

    @Test fun cancelBetweenGraphs() = run("cancel_between_graphs")

    // region Lifecycle

    private fun runtime(
        executor: ScriptedExecutor = ScriptedExecutor(),
        files: SpeechPackageFiles = packageFiles(fixture),
        noise: NoiseSource? = null,
    ) = ArticulinoRuntime(ArticulinoRuntimeOptions(executor, files, noise))

    @Test
    fun availabilityRequiresVoiceFiles() = runTest {
        val runtime = runtime()

        assertEquals(NeuralSpeechAvailability(true), runtime.availability(fixturePackage()))
        assertEquals(
            NeuralSpeechAvailability(false, "voice file missing: v"),
            runtime.availability(fixturePackage(voiceFile = null)),
        )
    }

    @Test
    fun refusesADifferentPipelineAMissingConfigAndAMissingGraph() = runTest {
        val runtime = runtime()

        assertEquals("unsupported pipeline 'x'", runtime.availability(fixturePackage(pipeline = "x")).reason)
        assertEquals(
            "pipeline config missing: speech.frontend.assets.config",
            runtime.availability(fixturePackage(frontendAssets = emptyMap())).reason,
        )
        assertEquals(
            "graph missing: dit_step",
            runtime.availability(fixturePackage(graphs = mapOf("text" to "t.onnx", "decoder" to "d.onnx"))).reason,
        )
    }

    @Test
    fun prepareRejectsABundleWithoutVoiceCache() = runTest {
        val runtime = runtime(files = packageFiles(fixture, voice = encodeVoice(fixture, drop = "voice_cache")))

        val result = runtime.prepare(fixturePackage())

        assertFalse(result.available)
        assertEquals("voice file malformed: v: missing tensor 'voice_cache'", result.reason)
    }

    @Test
    fun prepareRejectsABundleWithTheWrongFormat() = runTest {
        val bytes = encodeSafetensors(voiceTensors(fixture), mapOf("format" to "other/1"))
        val runtime = runtime(files = packageFiles(fixture, voice = bytes))

        assertEquals(
            "voice file malformed: v: unexpected format 'other/1'",
            runtime.prepare(fixturePackage()).reason,
        )
    }

    @Test
    fun prepareLoadsTheGraphsOfTheThreeRolesOnly() = runTest {
        val executor = ScriptedExecutor()
        val pkg = fixturePackage(graphs = defaultGraphs + ("encoder" to "encoder.onnx"))

        assertTrue(runtime(executor).prepare(pkg).available)

        assertEquals(defaultGraphs, executor.loaded)
    }

    @Test
    fun refusesAnUnsupportedLocaleAndAnUnknownVoice() = runTest {
        val runtime = runtime()

        assertFails(runtime, "fr-FR", "v", NeuralSpeechRuntimeErrorKind.Capability, "locale unsupported: fr-FR")
        assertFails(runtime, "de-DE", "nope", NeuralSpeechRuntimeErrorKind.Capability, "voice not found: nope")
    }

    @Test
    fun aFailedPrepareSurfacesFromSynthesizeAsUnavailable() = runTest {
        val runtime = runtime(files = packageFiles(fixture, voice = encodeVoice(fixture, drop = "voice_cache")))
        runtime.prepare(fixturePackage())

        assertFails(
            runtime,
            "de",
            "v",
            NeuralSpeechRuntimeErrorKind.Unavailable,
            "voice file malformed: v: missing tensor 'voice_cache'",
        )
    }

    @Test
    fun wrapsAnExecutorFailureThatIsNotARuntimeErrorAndPassesATypedOneThrough() = runTest {
        val plain = runtime(ScriptedExecutor(failure = IllegalStateException("boom")))
        assertFails(plain, "de", "v", NeuralSpeechRuntimeErrorKind.Internal, "pipeline failed: boom")

        val typed = runtime(ScriptedExecutor(failure = NeuralSpeechRuntimeError(NeuralSpeechRuntimeErrorKind.Unavailable, "gone")))
        assertFails(typed, "de", "v", NeuralSpeechRuntimeErrorKind.Unavailable, "gone")
    }

    // endregion

    // region Malformed model output

    private fun malformedOutputFailure(script: Script): NeuralSpeechRuntimeError = runTestBlocking {
        val runtime = runtime(ScriptedExecutor(script = script), noise = { FloatArray(it) })
        val input = NeuralSpeechSynthesisInput(fixturePackage(), "ab", "de", "v")
        try {
            runtime.synthesize(input).toList()
        } catch (error: NeuralSpeechRuntimeError) {
            return@runTestBlocking error
        }
        fail("the flow ended without a failure")
        throw IllegalStateException()
    }

    private fun textOutputs(logDurations: FloatArray, features: FloatArray) = mapOf(
        "text_features" to T(listOf(1, 3, 2), features),
        "log_durations" to T(listOf(1, 3), logDurations),
    )

    @Test
    fun nonFiniteLogDurationsEndTheFlowWithAnInternalFailure() {
        val script = Script(text = textOutputs(floatArrayOf(0f, Float.NaN, 0f), FloatArray(6)))

        val error = malformedOutputFailure(script)

        assertEquals(NeuralSpeechRuntimeErrorKind.Internal, error.kind)
        assertEquals("pipeline failed: text.log_durations yields non-finite durations", error.message)
    }

    @Test
    fun shortTextFeaturesEndTheFlowWithAnInternalFailure() {
        val script = Script(text = textOutputs(floatArrayOf(0f, 1f, 1f), floatArrayOf(0f, 0f)))

        val error = malformedOutputFailure(script)

        assertEquals(NeuralSpeechRuntimeErrorKind.Internal, error.kind)
        assertEquals("pipeline failed: text.text_features has 2 elements, expected 6", error.message)
    }

    @Test
    fun shortVelocityEndsTheFlowWithAnInternalFailure() {
        val script = Script(
            text = textOutputs(floatArrayOf(0f, 1f, 1f), FloatArray(6)),
            ditStep = listOf(mapOf("velocity" to T(listOf(1, 2, 2), floatArrayOf(0f)))),
        )

        val error = malformedOutputFailure(script)

        assertEquals(NeuralSpeechRuntimeErrorKind.Internal, error.kind)
        assertEquals("pipeline failed: dit_step.velocity has 1 elements, expected 4", error.message)
    }

    @Test
    fun aShortWaveformEndsTheFlowWithAnInternalFailure() {
        val script = Script(
            text = textOutputs(floatArrayOf(0f, 1f, 1f), FloatArray(6)),
            ditStep = List(4) { mapOf("velocity" to T(listOf(1, 2, 2), FloatArray(4))) },
            decoder = mapOf("waveform" to T(listOf(1, 1), floatArrayOf(0f))),
        )

        val error = malformedOutputFailure(script)

        assertEquals(NeuralSpeechRuntimeErrorKind.Internal, error.kind)
        assertTrue(error.message!!, error.message!!.startsWith("pipeline failed: decoder.waveform has 1 elements, expected "))
    }

    // endregion

    // region Directory package files

    @Test
    fun directoryPackageFilesReadsAndRefusesUnsafeOrMissingNames() = runTest {
        val directory = Files.createTempDirectory("articulino-files").toFile()
        try {
            File(directory, "voices").mkdirs()
            File(directory, "voices/v.bin").writeBytes("hi".toByteArray())
            val files = DirectoryPackageFiles(directory)

            assertEquals("hi", String(files.read("voices/v.bin")))
            for ((name, message) in listOf(
                "../x" to "model file name invalid: ../x",
                "voices/../../x" to "model file name invalid: voices/../../x",
                "/etc/passwd" to "model file name invalid: /etc/passwd",
                "" to "model file name invalid: ",
                "nope.bin" to "model files missing: nope.bin",
            )) {
                try {
                    files.read(name)
                    fail("expected '$name' to be refused")
                } catch (error: NeuralSpeechRuntimeError) {
                    assertEquals(NeuralSpeechRuntimeErrorKind.Capability, error.kind)
                    assertEquals(message, error.message)
                }
            }
        } finally {
            directory.deleteRecursively()
        }
    }

    // endregion

    private suspend fun assertFails(
        runtime: ArticulinoRuntime,
        locale: String,
        voice: String,
        kind: NeuralSpeechRuntimeErrorKind,
        message: String,
    ) {
        try {
            runtime.synthesize(NeuralSpeechSynthesisInput(fixturePackage(), "hallo", locale, voice)).toList()
            fail("expected a failure")
        } catch (error: NeuralSpeechRuntimeError) {
            assertEquals(kind, error.kind)
            assertEquals(message, error.message)
        }
    }
}

private fun <T> runTestBlocking(block: suspend () -> T): T = kotlinx.coroutines.runBlocking { block() }

// region Fixture

/** A fixture tensor: `shape` and flat C-order `data` (absent for shape-only expectations). */
private class T(val shape: List<Int>, val data: FloatArray?)

private class Script(
    val text: Map<String, T>? = null,
    val ditStep: List<Map<String, T>>? = null,
    val decoder: Map<String, T>? = null,
)

private class Fixture(val root: JSONObject) {
    val config: JSONObject = root.getJSONObject("config")
    val voice: JSONObject = root.getJSONObject("voice")
    val cases: List<JSONObject> = root.getJSONArray("cases").objects()
}

private fun loadFixture(): Fixture {
    // The Gradle test working directory is the module directory; walk up to the repository root.
    var directory: File? = File("").absoluteFile
    while (directory != null) {
        val candidate = File(directory, "contracts/fixtures/speech/articulino-pipeline.json")
        if (candidate.isFile) return Fixture(JSONObject(candidate.readText(Charsets.UTF_8)))
        directory = directory.parentFile
    }
    error("Could not locate contracts/fixtures/speech/articulino-pipeline.json")
}

private fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }

private fun JSONArray.floats(): FloatArray = FloatArray(length()) { getDouble(it).toFloat() }

private fun JSONArray.ints(): IntArray = IntArray(length()) { getInt(it) }

private fun JSONArray.longs(): LongArray = LongArray(length()) { getLong(it) }

private fun JSONArray.strings(): List<String> = (0 until length()).map { getString(it) }

private fun JSONObject.tensor(): T = T(getJSONArray("shape").ints().toList(), optJSONArray("data")?.floats())

private fun JSONObject.tensors(): Map<String, T> = keys().asSequence().associateWith { getJSONObject(it).tensor() }

private fun JSONObject.script(): Script = Script(
    text = optJSONObject("text")?.tensors(),
    ditStep = optJSONArray("dit_step")?.objects()?.map { it.tensors() },
    decoder = optJSONObject("decoder")?.tensors(),
)

private fun fixtureConfig(fixture: Fixture) = ArticulinoConfig.parse(fixture.config.toString().toByteArray(Charsets.UTF_8))

// endregion

// region Package, files and executor

private val defaultGraphs = mapOf("text" to "text.onnx", "dit_step" to "dit_step.onnx", "decoder" to "decoder.onnx")

private fun fixturePackage(
    pipeline: String = "articulino",
    graphs: Map<String, String> = defaultGraphs,
    frontendAssets: Map<String, String> = mapOf("config" to "config.json"),
    voiceFile: String? = "voices/v.safetensors",
) = ModelPackage(
    id = "articulino-fixture",
    version = "1",
    format = Format.Onnx,
    tasks = listOf("text_to_speech"),
    source = Source(sourceType = SourceType.AppManaged),
    speech = SpeechModelPackage(
        pipeline = pipeline,
        sampleRate = 24000,
        graphs = graphs,
        frontend = SpeechFrontend(kind = FrontendKind.Grapheme, assets = frontendAssets),
        voices = listOf(SpeechModelVoice(id = "v", name = "V", locales = listOf("de-DE", "en-US"), file = voiceFile)),
    ),
)

private class MemoryPackageFiles(private val files: Map<String, ByteArray>) : SpeechPackageFiles {
    override suspend fun read(file: String): ByteArray = files[file]
        ?: throw NeuralSpeechRuntimeError(NeuralSpeechRuntimeErrorKind.Capability, "model files missing: $file")
}

private fun voiceTensors(fixture: Fixture): List<Pair<String, SpeechTensor>> = fixture.voice.keys().asSequence().sorted().map { name ->
    val tensor = fixture.voice.getJSONObject(name).tensor()
    name to SpeechTensor(tensor.shape, SpeechTensorData.F32(tensor.data ?: FloatArray(0)))
}.toList()

private fun encodeVoice(fixture: Fixture, drop: String? = null): ByteArray = encodeSafetensors(voiceTensors(fixture).filter { it.first != drop }, mapOf("format" to "inderun.articulino.voice/1"))

private fun packageFiles(fixture: Fixture, voice: ByteArray? = null): SpeechPackageFiles = MemoryPackageFiles(
    mapOf(
        "config.json" to fixture.config.toString().toByteArray(Charsets.UTF_8),
        "voices/v.safetensors" to (voice ?: encodeVoice(fixture)),
    ),
)

private class RecordedCall(val role: String, val inputs: Map<String, SpeechTensor>)

/** Answers each role from the fixture's script (`dit_step` entries in order) and records every call. */
private class ScriptedExecutor(
    private val script: Script? = null,
    private val failure: Throwable? = null,
    private val afterCall: ((Int) -> Unit)? = null,
) : SpeechGraphExecutor {
    private val steps = ArrayDeque(script?.ditStep.orEmpty())
    private val recorded = mutableListOf<RecordedCall>()
    var loaded: Map<String, String> = emptyMap()

    val calls: List<RecordedCall> @Synchronized get() = recorded.toList()

    override suspend fun load(graphs: Map<String, String>) {
        loaded = graphs
    }

    override suspend fun run(role: String, inputs: Map<String, SpeechTensor>): Map<String, SpeechTensor> {
        val count = synchronized(this) {
            recorded += RecordedCall(role, inputs)
            recorded.size
        }
        afterCall?.invoke(count)
        failure?.let { throw it }
        val outputs = synchronized(this) {
            when (role) {
                "text" -> script?.text
                "decoder" -> script?.decoder
                else -> steps.removeFirstOrNull()
            }
        } ?: throw NeuralSpeechRuntimeError(NeuralSpeechRuntimeErrorKind.Internal, "no scripted output for $role")
        return outputs.mapValues { SpeechTensor(it.value.shape, SpeechTensorData.F32(it.value.data ?: FloatArray(0))) }
    }

    override fun close() = Unit
}

/** Hands out the fixture's noise tensors in order. */
private fun fixtureNoise(tensors: List<T>): NoiseSource {
    var next = 0
    return { _ -> tensors.getOrNull(next++)?.data ?: FloatArray(0) }
}

// endregion

// region Assertions

private const val FLOAT_TOLERANCE = 1e-4f

private fun assertClose(actual: FloatArray, expected: FloatArray, what: String = "") {
    assertEquals("$what length", expected.size, actual.size)
    for (index in actual.indices) assertEquals("$what[$index]", expected[index], actual[index], FLOAT_TOLERANCE)
}

private fun assertSamples(actual: ShortArray, expected: IntArray) {
    assertEquals(expected.size, actual.size)
    for (index in actual.indices) assertTrue("sample $index", abs(actual[index] - expected[index]) <= 1)
}

private fun floats(tensor: SpeechTensor?): FloatArray = when (val data = tensor?.data) {
    is SpeechTensorData.F32 -> data.values
    is SpeechTensorData.I64 -> FloatArray(data.values.size) { data.values[it].toFloat() }
    null -> FloatArray(0)
}

private fun assertCalls(actual: List<RecordedCall>, expected: List<JSONObject>) {
    assertEquals(expected.map { it.getString("role") }, actual.map { it.role })
    for ((call, want) in actual.zip(expected)) {
        val inputs = want.getJSONObject("inputs")
        for (name in inputs.keys()) {
            val tensor = inputs.getJSONObject(name).tensor()
            val got = call.inputs[name]
            assertNotNull("${call.role}.$name", got)
            assertEquals("${call.role}.$name shape", tensor.shape, got!!.shape)
            tensor.data?.let { assertClose(floats(got), it, "${call.role}.$name") }
        }
    }
}

// endregion

// region Handlers

private typealias Handler = suspend (Fixture, JSONObject) -> Unit

/** The voice's prompt frames P, read from `voice_cache`'s shape like the runtime does (never the config's `prefix_frames`). */
private fun promptFrames(fixture: Fixture): Int = fixture.voice.getJSONObject("voice_cache").getJSONArray("shape").getInt(4)

private fun synthesisInput(entry: JSONObject) = NeuralSpeechSynthesisInput(fixturePackage(), entry.getString("text"), entry.getString("language"), "v")

private fun noiseOf(entry: JSONObject): List<T> = entry.getJSONArray("noise").objects().map { it.tensor() }

private val handlers: Map<String, Handler> = mapOf(
    "letters" to { fixture, entry ->
        val config = fixtureConfig(fixture)
        val expect = entry.getJSONObject("expect")
        val language = config.languages.getValue(entry.getString("language"))
        val encoded = ArticulinoMath.encodeLetters(entry.getString("text"), language, config)
        assertEquals(expect.getJSONArray("textIds").ints().toList(), listOf(0) + encoded.ids.toList())
        assertEquals(
            expect.getJSONArray("language").ints().toList(),
            listOf(encoded.languages.firstOrNull() ?: 0) + encoded.languages.toList(),
        )
        assertEquals(expect.getJSONArray("textMask").ints().toList(), listOf(0) + encoded.ids.map { 1 })
    },
    "durations" to { fixture, entry ->
        val config = fixtureConfig(fixture)
        val input = entry.getJSONObject("input")
        val speed = input.getDouble("speed").toFloat()
        val d = ArticulinoMath.clampDurations(
            input.getJSONArray("logDurations").floats(),
            input.getJSONArray("textMask").longs(),
            speed,
            config.maxDurationUnits,
        )
        val letterRate = input.getDouble("letterRate").toFloat()
        if (letterRate > 0) {
            ArticulinoMath.equalizeLetterRate(d, input.getJSONArray("textIds").ints(), config.charset, 1, letterRate * speed)
        }
        d[0] = (config.durationUnitsPerFrame * promptFrames(fixture)).toFloat()
        val expect = entry.getJSONObject("expect")
        assertClose(d, expect.getJSONArray("durations").floats())
        assertEquals(expect.getInt("frames"), ArticulinoMath.frameCount(d, config.durationUnitsPerFrame))
    },
    "frameCondition" to { fixture, entry ->
        val config = fixtureConfig(fixture)
        val input = entry.getJSONObject("input")
        val features = input.getJSONObject("features").tensor()
        val condition = ArticulinoMath.frameCondition(
            features.data!!,
            features.shape[1],
            input.getJSONArray("durations").floats(),
            input.getInt("first"),
            input.getInt("frames"),
            config.durationUnitsPerFrame,
        )
        assertClose(condition, entry.getJSONObject("expect").getJSONObject("condition").tensor().data!!)
    },
    "flowSteps" to { fixture, entry ->
        val config = fixtureConfig(fixture)
        val input = entry.getJSONObject("input")
        val noise = input.getJSONArray("noise").objects().map { it.tensor().data!! }
        val velocities = input.getJSONArray("velocities").objects().map { it.tensor().data!! }
        var x = noise[0]
        var x1 = x
        config.times.forEachIndexed { k, t ->
            val hasNext = k + 1 < config.times.size
            val step = ArticulinoMath.flowStep(
                x,
                t,
                velocities[k],
                if (hasNext) config.times[k + 1] else null,
                if (hasNext) noise[k + 1] else null,
            )
            x1 = step.x1
            step.next?.let { x = it }
        }
        assertClose(x1, entry.getJSONObject("expect").getJSONObject("latents").tensor().data!!)
    },
    "postprocess" to { fixture, entry ->
        val config = fixtureConfig(fixture)
        val input = entry.getJSONObject("input")
        val shaped = ArticulinoMath.shapeWaveform(
            input.getJSONArray("waveform").floats(),
            input.getInt("leadInFrames") * config.samplesPerFrame,
            config,
        )
        val padded = ArticulinoMath.padSilence(shaped, input.getInt("pauseMs"), config.sampleRate)
        assertSamples(ArticulinoMath.toInt16(padded), entry.getJSONObject("expect").getJSONArray("samples").ints())
    },
    "split" to { _, entry ->
        assertEquals(
            entry.getJSONObject("expect").getJSONArray("pieces").strings(),
            ArticulinoMath.splitLongSentence(entry.getString("text")),
        )
    },
    "endToEnd" to { fixture, entry ->
        val executor = ScriptedExecutor(entry.getJSONObject("executor").script())
        val runtime = ArticulinoRuntime(
            ArticulinoRuntimeOptions(
                executor,
                packageFiles(fixture),
                fixtureNoise(noiseOf(entry)),
                speed = if (entry.has("speed")) entry.getDouble("speed").toFloat() else 1f,
                pauseMs = entry.getInt("pauseMs"),
            ),
        )
        val chunks = runtime.synthesize(synthesisInput(entry)).toList()
        val expect = entry.getJSONObject("expect")
        assertEquals(1, chunks.size)
        assertTrue(chunks[0].isLast)
        assertEquals(expect.getInt("sampleRate"), chunks[0].sampleRate)
        assertSamples(chunks[0].samples, expect.getJSONArray("samples").ints())
        assertCalls(executor.calls, expect.getJSONArray("calls").objects())
    },
    "cancel" to { fixture, entry ->
        val limit = entry.getInt("cancelAfterCalls")
        // The callback runs on the runtime's dispatcher. The job is launched LAZILY and published to
        // `handle` before it starts, so the callback always finds it and cancels deterministically.
        val handle = AtomicReference<Job?>(null)
        val executor = ScriptedExecutor(entry.getJSONObject("executor").script()) { count ->
            if (count >= limit) handle.get()!!.cancel()
        }
        val runtime = ArticulinoRuntime(
            ArticulinoRuntimeOptions(executor, packageFiles(fixture), fixtureNoise(noiseOf(entry)), pauseMs = entry.getInt("pauseMs")),
        )
        val chunks = mutableListOf<PcmChunk>()
        val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Unconfined)
        val job = scope.launch(start = kotlinx.coroutines.CoroutineStart.LAZY) {
            runtime.synthesize(synthesisInput(entry)).toList(chunks)
        }
        handle.set(job)
        job.start()
        job.join()
        assertTrue(job.isCancelled)
        assertEquals(0, chunks.size)
        assertTrue(executor.calls.size <= entry.getJSONObject("expect").getInt("callsAtMost"))
    },
)

// endregion

// region Validation, long sentences and prepare (mirrors the web and Swift suites)

/**
 * Answers every graph call with outputs shaped by its inputs: `text` gives two feature channels and
 * a duration of 6 units per letter, `dit_step` a velocity pulling `x` towards 0.5, `decoder` a sine
 * of [samplesPerFrame] samples per latent frame. The first [loadFailures] loads fail.
 */
private class ShapeFollowingExecutor(
    private val samplesPerFrame: Int = 4,
    private val text: ((Map<String, SpeechTensor>) -> Map<String, SpeechTensor>)? = null,
    private val ditStep: ((Map<String, SpeechTensor>) -> Map<String, SpeechTensor>)? = null,
    private val loadFailures: Int = 0,
) : SpeechGraphExecutor {
    private val recorded = mutableListOf<String>()
    private var loadCount = 0

    val roles: List<String> @Synchronized get() = recorded.toList()
    val loads: Int @Synchronized get() = loadCount

    override suspend fun load(graphs: Map<String, String>) {
        val attempt = synchronized(this) { ++loadCount }
        if (attempt <= loadFailures) throw NeuralSpeechRuntimeError(NeuralSpeechRuntimeErrorKind.Unavailable, "not yet")
    }

    override suspend fun run(role: String, inputs: Map<String, SpeechTensor>): Map<String, SpeechTensor> {
        synchronized(this) { recorded += role }
        return when (role) {
            "text" -> {
                val n = inputs.getValue("text_ids").shape[1]
                val outputs = mapOf(
                    "text_features" to SpeechTensor(listOf(1, n, 2), SpeechTensorData.F32(FloatArray(n * 2) { ((it % 7) - 3) / 10f })),
                    "log_durations" to SpeechTensor(listOf(1, n), SpeechTensorData.F32(FloatArray(n) { kotlin.math.ln(6f) })),
                )
                text?.invoke(outputs) ?: outputs
            }
            "dit_step" -> {
                val x = inputs.getValue("x")
                val values = (x.data as SpeechTensorData.F32).values
                val outputs = mapOf("velocity" to SpeechTensor(x.shape, SpeechTensorData.F32(FloatArray(values.size) { 0.5f - values[it] })))
                ditStep?.invoke(outputs) ?: outputs
            }
            else -> {
                val count = inputs.getValue("latents").shape[1].toLong() * samplesPerFrame
                if (count > 10_000_000) {
                    throw NeuralSpeechRuntimeError(NeuralSpeechRuntimeErrorKind.Internal, "scripted decoder asked for $count samples")
                }
                val samples = FloatArray(count.toInt()) { (kotlin.math.sin(it / 3.0) * 0.3).toFloat() }
                mapOf("waveform" to SpeechTensor(listOf(1, count.toInt()), SpeechTensorData.F32(samples)))
            }
        }
    }

    override fun close() = Unit
}

private fun patchedFiles(fixture: Fixture, patch: Map<String, Any> = emptyMap(), voice: ByteArray? = null): SpeechPackageFiles {
    val config = JSONObject(fixture.config.toString())
    for ((key, value) in patch) config.put(key, value)
    return MemoryPackageFiles(
        mapOf(
            "config.json" to config.toString().toByteArray(Charsets.UTF_8),
            "voices/v.safetensors" to (voice ?: encodeVoice(fixture)),
        ),
    )
}

private fun voiceWithLetterRate(fixture: Fixture, rate: Float): ByteArray = encodeSafetensors(
    voiceTensors(fixture).map { if (it.first == "letter_rate") it.first to SpeechTensor(listOf(1), SpeechTensorData.F32(floatArrayOf(rate))) else it },
    mapOf("format" to "inderun.articulino.voice/1"),
)

private val constantNoise: NoiseSource = { FloatArray(it) { 0.1f } }

private fun sentence(text: String) = NeuralSpeechSynthesisInput(fixturePackage(), text, "de-DE", "v")

@RunWith(RobolectricTestRunner::class)
class ArticulinoRuntimeValidationTest {
    private val fixture = loadFixture()

    private fun runtime(executor: SpeechGraphExecutor, files: SpeechPackageFiles = patchedFiles(fixture), pauseMs: Int = 150) = ArticulinoRuntime(ArticulinoRuntimeOptions(executor, files, constantNoise, pauseMs = pauseMs))

    @Test
    fun readsPFromTheVoiceNotFromTheConfigPrefixFrames() {
        assertEquals(2, promptFrames(fixture))
        assertTrue(fixtureConfig(fixture).prefixFrames != promptFrames(fixture))
    }

    @Test
    fun refusesAConfigValueOutOfRangeAtPrepare() = runTest {
        val post = fixture.config.getJSONObject("postprocess")
        fun postWith(key: String, value: Any) = JSONObject(post.toString()).put(key, value)
        val cases = listOf<Pair<Map<String, Any>, String>>(
            mapOf("sample_rate" to 1e20) to "sample_rate must be an integer from 8000 to 192000",
            mapOf("latent_dim" to 0) to "latent_dim must be an integer from 1 to 4096",
            mapOf("samples_per_frame" to 2.5) to "samples_per_frame must be an integer from 1 to 65536",
            mapOf("duration_units_per_frame" to 0) to "duration_units_per_frame must be an integer from 1 to 1000",
            mapOf("prefix_frames" to -1) to "prefix_frames must be an integer from 0 to 100000",
            mapOf("decoder_lead_in_frames" to -1) to "decoder_lead_in_frames must be an integer from 0 to 100000",
            mapOf("max_duration_units" to 0) to "max_duration_units must be greater than 0 and at most 100000",
            mapOf("times" to JSONArray(listOf(0, 1))) to "times[1] must be in [0, 1)",
            mapOf("languages" to JSONObject().put("de", 0.5)) to "languages.de must be an integer from 0 to 65535",
            mapOf("postprocess" to postWith("peak", 1.5)) to "postprocess.peak must be in (0, 1]",
            mapOf("postprocess" to postWith("shelf_slope", 0)) to "postprocess.shelf_slope must be greater than 0",
        )
        for ((patch, why) in cases) {
            val result = runtime(ShapeFollowingExecutor(), patchedFiles(fixture, patch)).prepare(fixturePackage())
            assertEquals(why, "pipeline config malformed: $why", result.reason)
        }
    }

    @Test
    fun acceptsALetterRateOfZeroAndRefusesOneOutside1To100() = runTest {
        for (rate in listOf(0f, 100f)) {
            val files = patchedFiles(fixture, voice = voiceWithLetterRate(fixture, rate))
            assertEquals("$rate", NeuralSpeechAvailability(true), runtime(ShapeFollowingExecutor(), files).prepare(fixturePackage()))
        }
        for (rate in listOf(1e-6f, 0.5f, 101f, -1f, Float.NaN, Float.POSITIVE_INFINITY)) {
            val files = patchedFiles(fixture, voice = voiceWithLetterRate(fixture, rate))
            assertEquals(
                "$rate",
                NeuralSpeechAvailability(false, "voice file malformed: v: letter_rate out of range"),
                runtime(ShapeFollowingExecutor(), files).prepare(fixturePackage()),
            )
        }
    }

    @Test
    fun boundsTheFrameCountBeforeAllocating() = runTest {
        val executor = ShapeFollowingExecutor(samplesPerFrame = 65536, text = { outputs ->
            val n = outputs.getValue("log_durations").shape[1]
            outputs + ("log_durations" to SpeechTensor(listOf(1, n), SpeechTensorData.F32(FloatArray(n) { kotlin.math.ln(1e5f) })))
        })
        val files = patchedFiles(fixture, mapOf("samples_per_frame" to 65536, "duration_units_per_frame" to 1, "max_duration_units" to 100000))
        try {
            runtime(executor, files).synthesize(sentence("a.")).toList()
            fail("expected a failure")
        } catch (error: NeuralSpeechRuntimeError) {
            assertEquals(NeuralSpeechRuntimeErrorKind.Internal, error.kind)
            val pattern = Regex("""pipeline failed: text\.log_durations yields \d+ frames, more than \d+""")
            assertTrue(error.message.orEmpty(), pattern.matches(error.message.orEmpty()))
        }
    }

    @Test
    fun aLongSentenceSynthesizesEachPieceAndReturnsOneChunkWithOnePause() = runTest {
        val config = fixtureConfig(fixture)
        val split = fixture.cases.first { it.getString("id") == "long_sentence_split" }
        val pieces = split.getJSONObject("expect").getJSONArray("pieces").strings()
        assertEquals(2, pieces.size)
        val pauseMs = 1
        val pause = Math.round(pauseMs / 1000.0 * config.sampleRate).toInt()

        val executor = ShapeFollowingExecutor()
        val chunks = runtime(executor, pauseMs = pauseMs).synthesize(sentence(split.getString("text"))).toList()
        assertEquals(2, executor.roles.count { it == "text" })
        assertEquals(2 * config.times.size, executor.roles.count { it == "dit_step" })
        assertEquals(2, executor.roles.count { it == "decoder" })
        assertEquals(1, chunks.size)
        assertTrue(chunks[0].isLast)

        val expected = mutableListOf<Short>()
        for (piece in pieces) {
            val alone = runtime(ShapeFollowingExecutor(), pauseMs = pauseMs).synthesize(sentence(piece)).toList().single().samples
            assertTrue(alone.size > pause)
            expected += alone.toList().dropLast(pause)
        }
        expected += List(pause) { 0.toShort() }
        assertEquals(expected, chunks[0].samples.toList())
    }

    @Test
    fun prepareReturnsTheRememberedOutcomeWithoutLoadingAgain() = runTest {
        val executor = ShapeFollowingExecutor()
        val runtime = runtime(executor)
        repeat(2) { assertEquals(NeuralSpeechAvailability(true), runtime.prepare(fixturePackage())) }
        assertEquals(1, executor.loads)
        assertEquals(NeuralSpeechAvailability(true), runtime.prepare(fixturePackage().copy(version = "2")))
        assertEquals(2, executor.loads)
    }

    @Test
    fun prepareLoadsAgainAfterAFailure() = runTest {
        val executor = ShapeFollowingExecutor(loadFailures = 1)
        val runtime = runtime(executor)
        assertEquals(NeuralSpeechAvailability(false, "not yet"), runtime.prepare(fixturePackage()))
        repeat(2) { assertEquals(NeuralSpeechAvailability(true), runtime.prepare(fixturePackage())) }
        assertEquals(2, executor.loads)
    }
}

// endregion
