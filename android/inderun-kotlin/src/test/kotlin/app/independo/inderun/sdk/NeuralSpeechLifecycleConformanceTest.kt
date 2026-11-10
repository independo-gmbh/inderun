package app.independo.inderun.sdk

import app.independo.inderun.contracts.ArtifactReadRequest
import app.independo.inderun.contracts.ExecutionProvenance
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.Format
import app.independo.inderun.contracts.FrontendKind
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.contracts.Outcome
import app.independo.inderun.contracts.OutputDelivery
import app.independo.inderun.contracts.OutputDeliveryRequest
import app.independo.inderun.contracts.PlaybackOutput
import app.independo.inderun.contracts.PlaybackTiming
import app.independo.inderun.contracts.ProviderReadiness
import app.independo.inderun.contracts.ProviderVoice
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.Source
import app.independo.inderun.contracts.SourceType
import app.independo.inderun.contracts.SpeechFrontend
import app.independo.inderun.contracts.SpeechInput
import app.independo.inderun.contracts.SpeechModelPackage
import app.independo.inderun.contracts.SpeechModelVoice
import app.independo.inderun.contracts.StreamEvent
import app.independo.inderun.contracts.TaskKind
import app.independo.inderun.contracts.TaskOutput
import app.independo.inderun.contracts.TaskOutputType
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestTask
import app.independo.inderun.contracts.VoiceGender
import app.independo.inderun.core.AudioOutputFormat
import app.independo.inderun.core.AudioOutputService
import app.independo.inderun.core.AudioOutputSession
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ModelProfiles
import app.independo.inderun.core.PreparableProviderAdapter
import app.independo.inderun.core.ProviderPrepareContext
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.core.ProviderStreamContext
import app.independo.inderun.core.ProviderStreamEvent
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.StreamingProviderAdapter
import app.independo.inderun.core.createUnavailable
import app.independo.inderun.providers.neuralspeech.FixtureNeuralSpeechRuntime
import app.independo.inderun.providers.neuralspeech.FixtureNeuralSpeechRuntimeOptions
import app.independo.inderun.providers.neuralspeech.NeuralSpeechAvailability
import app.independo.inderun.providers.neuralspeech.NeuralSpeechProvider
import app.independo.inderun.providers.neuralspeech.NeuralSpeechRuntime
import app.independo.inderun.providers.neuralspeech.NeuralSpeechSynthesisInput
import app.independo.inderun.providers.neuralspeech.PcmChunk
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.abs

private const val TEXT = "Hallo Welt. Wie geht es dir?"
private const val LOCALE = "de-AT"

/**
 * The case's profile: [neural, fallback], or [neural] alone. A named profile, because `auto`
 * cannot be redefined and ranks equal targets by id, which would put "fallback" first.
 */
private const val PROFILE = "neural"

/** Counts the frames the runtime produced. */
private class CountingNeuralRuntime(val fixture: FixtureNeuralSpeechRuntime) : NeuralSpeechRuntime {
    private val produced = AtomicLong()
    val frames: Long get() = produced.get()

    override suspend fun availability(modelPackage: ModelPackage) = fixture.availability(modelPackage)

    override suspend fun prepare(modelPackage: ModelPackage) = fixture.prepare(modelPackage)

    override fun synthesize(input: NeuralSpeechSynthesisInput): Flow<PcmChunk> = fixture.synthesize(input).onEach { produced.addAndGet(it.samples.size.toLong()) }
}

/** Records what the neural provider threw and how often the engine entered its `stream`. */
private class RecordingNeuralProvider(private val inner: NeuralSpeechProvider) :
    StreamingProviderAdapter,
    PreparableProviderAdapter {
    val errors = CopyOnWriteArrayList<Throwable>()
    private val streams = AtomicInteger()
    val streamCalls: Int get() = streams.get()

    override fun describe() = inner.describe()

    override suspend fun capabilities(host: HostServices) = inner.capabilities(host)

    override fun prepare(context: ProviderPrepareContext) = inner.prepare(context)

    override suspend fun run(request: TaskRequest, context: RunContext) = try {
        inner.run(request, context)
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: Throwable) {
        errors += error
        throw error
    }

    override fun stream(request: TaskRequest, context: ProviderStreamContext): Flow<ProviderStreamEvent> = flow {
        streams.incrementAndGet()
        try {
            emitAll(inner.stream(request, context))
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            errors += error
            throw error
        }
    }
}

/**
 * The fixture audio output, observed: whether the first session had stopped when the second
 * opened, and optionally an interruption once a session's first write is taken.
 */
private class ObservedNeuralAudioOutput(
    val fixture: FixtureAudioOutputService,
    private val interruptAfterFirstWrite: Boolean,
) : AudioOutputService {
    @Volatile
    var firstStoppedAtSecondOpen: Boolean? = null

    override suspend fun open(format: AudioOutputFormat): AudioOutputSession {
        fixture.sessions.singleOrNull()?.let { firstStoppedAtSecondOpen = it.stopped }
        val session = fixture.open(format)
        if (!interruptAfterFirstWrite) return session
        val recorded = fixture.sessions.last()
        return object : AudioOutputSession by session {
            override suspend fun write(samples: ShortArray) {
                session.write(samples)
                if (recorded.writes.size == 1) {
                    recorded.interrupt(
                        createUnavailable(
                            "Audio output was interrupted by the system.",
                            details = mapOf("code" to "audio_output_interrupted"),
                        ),
                    )
                }
            }
        }
    }
}

/** One case's provider, its fixtures, and what they recorded. */
private class NeuralWorld(
    modelPackage: ModelPackage,
    runtimeOptions: FixtureNeuralSpeechRuntimeOptions = FixtureNeuralSpeechRuntimeOptions(),
    withAudioOutput: Boolean = true,
    withFallback: Boolean = true,
    interruptAfterFirstWrite: Boolean = false,
) {
    val runtime = CountingNeuralRuntime(FixtureNeuralSpeechRuntime(runtimeOptions))
    val neural = NeuralSpeechProvider(modelPackage, runtime)
    val provider = RecordingNeuralProvider(neural)
    val audio = ObservedNeuralAudioOutput(FixtureAudioOutputService(), interruptAfterFirstWrite)
    val fallback = if (withFallback) {
        FakeStreamProvider(
            "fallback",
            script = listOf(
                Step.Emit(
                    ProviderStreamEvent.Result(
                        TaskOutput(type = TaskOutputType.PLAYBACK, playback = PlaybackOutput()),
                        FinishReason.STOP,
                    ),
                ),
            ),
            task = TaskKind.TEXT_TO_SPEECH,
        )
    } else {
        null
    }
    val hostServices: HostServices = conformanceHostServices().copy(audioOutput = audio.takeIf { withAudioOutput })
    val engine = IndeRun(
        ProviderRegistry().apply {
            register(provider)
            fallback?.let { register(it) }
        },
        hostServices,
        modelProfiles = ModelProfiles(mapOf(PROFILE to listOfNotNull(neural.id, fallback?.let { "fallback" }))),
    )

    val sessions: List<FixtureAudioOutputSession> get() = audio.fixture.sessions
}

/** What a handler observed; every field is optional and mirrors `$expectKeys`. */
private class NeuralObservation(
    val world: NeuralWorld,
    val outcome: String? = null,
    val commitCount: Int? = null,
    val commitAt: Pair<Int, Int>? = null,
    val fallbackAsked: Boolean? = null,
    val error: Pair<String, Any?>? = null,
    val timing: PlaybackTiming? = null,
    val artifact: Pair<String, ByteArray>? = null,
    val readiness: Pair<ProviderReadiness?, ProviderReadiness?>? = null,
    val secondOpensAfterFirstStops: Boolean? = null,
)

/**
 * The Android run of the neural speech lifecycle catalog
 * (`contracts/fixtures/speech/neural-speech-lifecycle.json`): one handler per case, driving
 * [IndeRun] (or, for the two direct cases, the provider) with the fixture runtime, the fixture
 * audio output, and a recording fallback. It lives in this module because the engine and the
 * fixture audio output do. Every wait is bounded by the case's `timeoutMs` (virtual time under
 * `runTest`, which also drives the fixture runtime's delays).
 *
 * Robolectric is required because `org.json` is stubbed in plain Android unit tests.
 */
@RunWith(RobolectricTestRunner::class)
class NeuralSpeechLifecycleConformanceTest {
    private val catalog: JSONObject by lazy {
        // The Gradle test working directory is the module directory; walk up to the
        // repository root rather than hard-coding the depth.
        var directory: File? = File("").absoluteFile
        while (directory != null) {
            val candidate = File(directory, "contracts/fixtures/speech/neural-speech-lifecycle.json")
            if (candidate.isFile) return@lazy JSONObject(candidate.readText(Charsets.UTF_8))
            directory = directory.parentFile
        }
        error("Could not locate contracts/fixtures/speech/neural-speech-lifecycle.json")
    }

    private val cases: List<JSONObject> by lazy {
        val cases = catalog.getJSONArray("cases")
        (0 until cases.length()).map { cases.getJSONObject(it) }
    }

    private val modelPackage: ModelPackage by lazy { modelPackageFrom(catalog.getJSONObject("package")) }

    private val sampleRate: Int get() = modelPackage.speech!!.sampleRate.toInt()

    @Test
    fun implementsEveryCaseInTheSharedCatalogAndNoOthers() {
        val ids = cases.map { it.getString("id") }.sorted()
        assertTrue(ids.isNotEmpty())
        assertEquals(ids.toSet().size, ids.size)
        assertEquals(ids, handlers.keys.sorted())

        // Every expectation a case states is one this runner checks.
        val known = catalog.getJSONObject("\$expectKeys").keys().asSequence().toSet() - "timeoutMs"
        for (case in cases) {
            val keys = case.getJSONObject("expect").keys().asSequence().toSet()
            assertTrue("${case.getString("id")}: unknown keys ${keys - known}", known.containsAll(keys))
        }
    }

    @Test
    fun matchesEveryCaseInTheSharedCatalog() = runTest {
        val failures = mutableListOf<String>()
        for (case in cases) {
            val id = case.getString("id")
            val observation = handlers.getValue(id)(this, case.getLong("timeoutMs"))
            failures += check(case.getJSONObject("expect"), observation).map { "$id: $it" }
        }
        assertTrue("Conformance failures:\n${failures.joinToString("\n")}", failures.isEmpty())
    }

    /** Not a catalog case: a runtime whose availability check throws must not hide the engine's other providers. */
    @Test
    fun listsTheOtherProvidersWhenTheRuntimeAvailabilityCheckThrows() = runTest {
        val throwing = object : NeuralSpeechRuntime {
            private val fixture = FixtureNeuralSpeechRuntime()

            override suspend fun availability(modelPackage: ModelPackage): NeuralSpeechAvailability = throw IllegalStateException("onnxruntime is missing")

            override suspend fun prepare(modelPackage: ModelPackage) = fixture.prepare(modelPackage)

            override fun synthesize(input: NeuralSpeechSynthesisInput): Flow<PcmChunk> = fixture.synthesize(input)
        }
        val neural = NeuralSpeechProvider(modelPackage, throwing)
        val other = FakeStreamProvider("other", script = emptyList(), task = TaskKind.TEXT_TO_SPEECH)
        val engine = IndeRun(
            ProviderRegistry().apply {
                register(neural)
                register(other)
            },
            conformanceHostServices(),
        )

        val snapshots = engine.checkCapabilities()

        assertEquals(listOf(neural.id to false, "other" to true), snapshots.map { it.providerId to it.capabilities.available })
        assertEquals("runtime availability failed: onnxruntime is missing", snapshots.first().capabilities.reason)
    }

    // --- handlers ----------------------------------------------------------------------------

    private val handlers: Map<String, suspend TestScope.(timeoutMs: Long) -> NeuralObservation> = mapOf(
        "playback_commits_before_first_write" to { timeoutMs -> directPlayback(timeoutMs) },
        "playback_reports_timing" to { timeoutMs -> directPlayback(timeoutMs) },

        "cancel_while_waiting_plays_nothing" to { timeoutMs ->
            // A plays 30 chunks with 20 ms each before them: B is cancelled long before A ends.
            val world = NeuralWorld(modelPackage, FixtureNeuralSpeechRuntimeOptions(delayMs = 20))
            val textA = "Heute scheint die Sonne über den Bergen, und wir gehen raus."
            assertEquals(60, textA.length)

            val a = world.engine.speak(SpeakOptions(textA, LOCALE, model = PROFILE), this)
            until(timeoutMs, "A's first write") { world.sessions.firstOrNull()?.writes?.isNotEmpty() == true }
            val b = world.engine.speak(SpeakOptions(TEXT, LOCALE, model = PROFILE), this)
            until(timeoutMs, "B reaching the provider") { world.provider.streamCalls == 2 }
            assertEquals("A still playing when B is cancelled", false, world.sessions.first().stopped)
            b.cancel()

            val endA = ending(a, timeoutMs)
            val endB = ending(b, timeoutMs)
            assertEquals("A's outcome", "completed", endA.outcome)
            NeuralObservation(world, outcome = endB.outcome, commitCount = neuralCommits(world, endB.provenance))
        },

        "cancel_mid_stream_stops_audio_once" to { timeoutMs ->
            val world = NeuralWorld(modelPackage, FixtureNeuralSpeechRuntimeOptions(delayMs = 5))
            val text = "Der Wind weht leise über die Wiesen am Rand des alten Dorfes, wo die Kinder spielen und lachen. " +
                "Am Abend kehren alle müde nach Hause zurück und erzählen einander von den kleinen Abenteuern des Tages!!"
            assertEquals(200, text.length)

            // Driven through stream() rather than speak(), which stops reading at the first terminal.
            val run = world.engine.stream(SpeakOptions(text, LOCALE, model = PROFILE).toTaskRequest())
            val terminals = CopyOnWriteArrayList<StreamEvent>()
            val consumed = launch { run.events.collect { if (it.type == "terminal") terminals += it } }
            until(timeoutMs, "the first write") { world.sessions.firstOrNull()?.writes?.isNotEmpty() == true }
            run.cancel()
            bounded(timeoutMs, "the stream") { consumed.join() }

            assertEquals("terminal events", 1, terminals.size)
            val payload = terminals.single().payload!!
            NeuralObservation(world, outcome = payload.outcome?.rawValue, commitCount = neuralCommits(world, payload.provenance))
        },

        "missing_audio_output_refuses_before_commit" to { timeoutMs ->
            val world = NeuralWorld(modelPackage, withAudioOutput = false)
            val end = ending(world.engine.speak(SpeakOptions(TEXT, LOCALE, model = PROFILE), this), timeoutMs)
            val attempt = end.provenance?.attempts?.firstOrNull { it.providerId == world.neural.id }
            val error = observedError(world.provider.errors.firstOrNull())
            // The provenance records the refusal's class; the provider's own error carries its code.
            assertEquals("provenance error class", error?.first, attempt?.errorClass?.rawValue)
            NeuralObservation(
                world,
                outcome = end.outcome,
                fallbackAsked = world.fallback!!.callCount > 0,
                commitCount = neuralCommits(world, end.provenance),
                error = error,
            )
        },

        "unknown_voice_refused_before_commit" to { timeoutMs ->
            val world = NeuralWorld(modelPackage)
            val direct = DirectContext(world, ProviderVoice(id = "ghost", locale = LOCALE))
            val error = try {
                bounded(timeoutMs, "the direct run") { world.neural.run(speechRequest(), direct.context) }
                null
            } catch (thrown: IndeRunException) {
                observedError(thrown)
            }
            NeuralObservation(world, commitCount = direct.commitCount, error = error)
        },

        "artifact_is_wav_of_the_samples" to { timeoutMs ->
            val world = NeuralWorld(modelPackage)
            val generated = bounded(timeoutMs, "generateSpeech") {
                world.engine.generateSpeech(GenerateSpeechOptions(SpeakOptions(TEXT, LOCALE, model = PROFILE)))
            }
            NeuralObservation(
                world,
                outcome = if (generated.finishReason == FinishReason.STOP) "completed" else generated.finishReason.rawValue,
                commitCount = neuralCommits(world, generated.provenance),
                artifact = generated.artifact.mediaType to readAll(world, generated.artifact.id, timeoutMs),
            )
        },

        "artifact_over_cap_fails_before_commit" to { timeoutMs ->
            val world = NeuralWorld(modelPackage, FixtureNeuralSpeechRuntimeOptions(msPerCharacter = 50_000), withFallback = false)
            val text = "Servus!"
            assertEquals(7, text.length)
            try {
                bounded(timeoutMs, "generateSpeech") {
                    world.engine.generateSpeech(GenerateSpeechOptions(SpeakOptions(text, LOCALE, model = PROFILE)))
                }
                NeuralObservation(world, outcome = "completed")
            } catch (error: IndeRunException) {
                NeuralObservation(world, outcome = "error", commitCount = neuralCommits(world, error.provenance), error = observedError(error))
            }
        },

        "interruption_after_commit_fails_without_fallback" to { timeoutMs ->
            val world = NeuralWorld(modelPackage, interruptAfterFirstWrite = true)
            val end = ending(world.engine.speak(SpeakOptions(TEXT, LOCALE, model = PROFILE), this), timeoutMs)
            NeuralObservation(
                world,
                outcome = end.outcome,
                commitCount = neuralCommits(world, end.provenance),
                fallbackAsked = world.fallback!!.callCount > 0,
                error = end.error?.let { observedError(it) },
            )
        },

        "utterances_play_one_at_a_time" to { timeoutMs ->
            val world = NeuralWorld(modelPackage, FixtureNeuralSpeechRuntimeOptions(delayMs = 2))
            val first = world.engine.speak(SpeakOptions(TEXT, LOCALE, model = PROFILE), this)
            val second = world.engine.speak(SpeakOptions(TEXT, LOCALE, model = PROFILE), this)
            val endings = listOf(ending(first, timeoutMs), ending(second, timeoutMs))
            NeuralObservation(
                world,
                outcome = endings.firstOrNull { it.outcome != "completed" }?.outcome ?: "completed",
                secondOpensAfterFirstStops = world.audio.firstStoppedAtSecondOpen,
            )
        },

        "capabilities_never_load" to { timeoutMs ->
            val world = NeuralWorld(modelPackage)
            bounded(timeoutMs, "checkCapabilities") { world.engine.checkCapabilities() }
            val before = bounded(timeoutMs, "checkCapabilities") { readiness(world) }
            assertEquals("prepare calls before prepare", 0, world.runtime.fixture.prepareCalls)

            val preparation = world.engine.prepare(this)
            bounded(timeoutMs, "prepare") { preparation.result.await() }
            val after = bounded(timeoutMs, "checkCapabilities") { readiness(world) }
            NeuralObservation(world, readiness = before to after)
        },
    )

    /** The run `playback_commits_before_first_write` and `playback_reports_timing` share. */
    private suspend fun directPlayback(timeoutMs: Long): NeuralObservation {
        val world = NeuralWorld(modelPackage)
        val direct = DirectContext(world)
        val result = bounded(timeoutMs, "the direct run") { world.neural.run(speechRequest(), direct.context) }
        return NeuralObservation(world, commitCount = direct.commitCount, commitAt = direct.commitAt, timing = result.output.playback?.timing)
    }

    /** A `RunContext` for a direct provider call, whose `commit()` records the fixture's state. */
    private class DirectContext(world: NeuralWorld, voice: ProviderVoice? = null) {
        var commitCount = 0
            private set
        var commitAt: Pair<Int, Int>? = null
            private set
        val context = RunContext(
            runId = "direct-run",
            hostServices = world.hostServices,
            voice = voice,
            commitHandler = {
                if (commitCount == 0) commitAt = world.sessions.size to (world.sessions.firstOrNull()?.writes?.size ?: 0)
                commitCount = 1
                true
            },
        )
    }

    private fun speechRequest() = TaskRequest(
        schemaVersion = SchemaVersion.V1_0,
        task = TaskRequestTask(kind = TaskKind.TEXT_TO_SPEECH),
        speech = SpeechInput(text = TEXT, locale = LOCALE),
        delivery = OutputDeliveryRequest(mode = OutputDelivery.Playback),
    )

    /** What a speak run ended with, from the facade's result or failure. */
    private class Ending(val outcome: String, val provenance: ExecutionProvenance?, val error: IndeRunException? = null)

    private suspend fun ending(playback: SpeechPlayback, timeoutMs: Long): Ending = try {
        val spoken = bounded(timeoutMs, "speak") { playback.result.await() }
        Ending(if (spoken.finishReason == FinishReason.CANCELLED) Outcome.Cancelled.rawValue else Outcome.Completed.rawValue, spoken.provenance)
    } catch (error: IndeRunException) {
        Ending(Outcome.Error.rawValue, error.provenance, error)
    }

    /** Whether the engine's provenance reports the neural attempt committed. */
    private fun neuralCommits(world: NeuralWorld, provenance: ExecutionProvenance?): Int {
        val attempt = provenance?.attempts?.firstOrNull { it.providerId == world.neural.id }
        return if (attempt?.committed == true) 1 else 0
    }

    private fun observedError(error: Throwable?): Pair<String, Any?>? = (error as? IndeRunException)?.let { it.errorClass.rawValue to it.details?.get("code") }

    private suspend fun readAll(world: NeuralWorld, artifactId: String, timeoutMs: Long): ByteArray {
        var bytes = ByteArray(0)
        while (true) {
            val chunk = bounded(timeoutMs, "readArtifact") {
                world.engine.readArtifact(ArtifactReadRequest(artifactId = artifactId, offset = bytes.size.toLong()))
            }
            bytes += chunk.bytes
            if (chunk.done) return bytes
        }
    }

    private suspend fun readiness(world: NeuralWorld): ProviderReadiness? = world.engine.checkCapabilities()
        .firstOrNull { it.providerId == world.neural.id }
        ?.capabilities?.taskCapabilities?.firstOrNull()?.readiness

    private suspend fun <T> bounded(timeoutMs: Long, label: String, block: suspend () -> T): T {
        var value: Result<T>? = null
        withTimeoutOrNull(timeoutMs) { value = runCatching { block() } }
        return (value ?: throw AssertionError("$label did not settle within $timeoutMs ms")).getOrThrow()
    }

    private suspend fun until(timeoutMs: Long, label: String, condition: () -> Boolean) {
        withTimeoutOrNull(timeoutMs) { while (!condition()) delay(1) }
            ?: throw AssertionError("$label did not happen within $timeoutMs ms")
    }

    // --- expectations ------------------------------------------------------------------------

    private fun check(expect: JSONObject, observed: NeuralObservation): List<String> {
        val failures = mutableListOf<String>()
        fun expectEqual(label: String, expected: Any?, actual: Any?) {
            if (expected != actual) failures += "$label: expected $expected, got $actual"
        }
        val world = observed.world
        val frames = world.runtime.frames

        expect.optString("outcome").takeIf { it.isNotEmpty() }?.let { expectEqual("outcome", it, observed.outcome) }
        if (expect.has("commitCount")) expectEqual("commitCount", expect.getInt("commitCount"), observed.commitCount)
        expect.optJSONObject("commitAt")?.let {
            expectEqual("commitAt", it.getInt("sessionsOpened") to it.getInt("firstSessionWrites"), observed.commitAt)
        }
        expect.optJSONObject("sessions")?.let { sessions ->
            expectEqual("sessions.count", sessions.getInt("count"), world.sessions.size)
            sessions.optJSONObject("first")?.let { first ->
                val session = world.sessions.firstOrNull()
                if (session == null) {
                    failures += "sessions.first: no session opened"
                } else {
                    if (first.has("writes") && session.writes.size < first.getInt("writes")) {
                        failures += "sessions.first.writes: expected at least ${first.getInt("writes")}, got ${session.writes.size}"
                    }
                    if (first.has("stopped")) expectEqual("sessions.first.stopped", first.getBoolean("stopped"), session.stopped)
                    when (first.optString("discardedFrames")) {
                        "some" -> if (session.discardedFrames <= 0) failures += "sessions.first.discardedFrames: expected some, got none"
                        "none" -> expectEqual("sessions.first.discardedFrames", 0L, session.discardedFrames)
                    }
                    if (first.optString("playedFrames") == "all") {
                        if (session.writtenFrames <= 0) failures += "sessions.first.writtenFrames: expected some"
                        expectEqual("sessions.first.playedFrames", session.writtenFrames, session.playedFrames)
                    }
                }
            }
        }
        if (expect.has("fallbackAsked")) expectEqual("fallbackAsked", expect.getBoolean("fallbackAsked"), observed.fallbackAsked)
        expect.optJSONObject("error")?.let {
            expectEqual("error", it.getString("errorClass") to it.getString("code"), observed.error)
        }
        expect.optJSONObject("timing")?.let { timing ->
            val actual = observed.timing
            if (timing.optString("durationMsEquals") == "synthesized") {
                val expected = frames * 1000.0 / sampleRate
                val duration = actual?.durationMs
                if (duration == null || abs(duration - expected) > 1e-6) failures += "timing.durationMs: expected $expected, got $duration"
            }
            if (timing.has("firstChunkDefined")) expectEqual("timing.firstChunkDefined", timing.getBoolean("firstChunkDefined"), actual?.firstChunkMs != null)
            if (timing.has("firstAudioDefined")) expectEqual("timing.firstAudioDefined", timing.getBoolean("firstAudioDefined"), actual?.firstAudioMs != null)
        }
        expect.optJSONObject("artifact")?.let { artifact ->
            val (mediaType, bytes) = observed.artifact ?: ("" to ByteArray(0))
            expectEqual("artifact.mediaType", artifact.getString("mediaType"), mediaType)
            if (artifact.optString("byteLengthEquals") == "wav") expectEqual("artifact.byteLength", 44 + 2 * frames, bytes.size.toLong())
            artifact.optJSONObject("header")?.let { header ->
                if (bytes.size < 44) {
                    failures += "artifact.header: only ${bytes.size} bytes"
                } else {
                    val view = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
                    expectEqual("artifact.header.sampleRate", header.getInt("sampleRate"), view.getInt(24))
                    expectEqual("artifact.header.channels", header.getInt("channels"), view.getShort(22).toInt())
                    expectEqual("artifact.header.bitsPerSample", header.getInt("bitsPerSample"), view.getShort(34).toInt())
                    expectEqual("artifact.header.dataBytes", 2 * frames, view.getInt(40).toLong())
                }
            }
        }
        expect.optJSONObject("runtime")?.let { runtime ->
            val calls = world.runtime.fixture.synthesized.size
            if (runtime.has("synthesizeCalls")) expectEqual("runtime.synthesizeCalls", runtime.getInt("synthesizeCalls"), calls)
            if (runtime.has("synthesizeCallsAtMost") && calls > runtime.getInt("synthesizeCallsAtMost")) {
                failures += "runtime.synthesizeCalls: expected at most ${runtime.getInt("synthesizeCallsAtMost")}, got $calls"
            }
            if (runtime.has("prepareCalls")) expectEqual("runtime.prepareCalls", runtime.getInt("prepareCalls"), world.runtime.fixture.prepareCalls)
        }
        expect.optJSONObject("order")?.let {
            expectEqual("order.secondOpensAfterFirstStops", it.getBoolean("secondOpensAfterFirstStops"), observed.secondOpensAfterFirstStops)
        }
        expect.optJSONObject("readiness")?.let {
            fun readiness(key: String) = if (it.isNull(key)) null else ProviderReadiness.fromRawValue(it.getString(key))
            expectEqual("readiness", readiness("before") to readiness("after"), observed.readiness)
        }
        return failures
    }
}

/** The catalog's model package, decoded by hand: the generated contracts carry no JSON codec. */
private fun modelPackageFrom(json: JSONObject): ModelPackage {
    val speech = json.getJSONObject("speech")
    val graphs = speech.getJSONObject("graphs")
    val voices = speech.getJSONArray("voices")
    return ModelPackage(
        id = json.getString("id"),
        version = json.optString("version").takeIf { it.isNotEmpty() },
        format = Format.fromRawValue(json.getString("format"))!!,
        tasks = json.getJSONArray("tasks").strings(),
        source = json.optJSONObject("source")?.let { Source(sourceType = SourceType.fromRawValue(it.getString("sourceType"))!!) },
        speech = SpeechModelPackage(
            pipeline = speech.getString("pipeline"),
            sampleRate = speech.getLong("sampleRate"),
            graphs = graphs.keys().asSequence().associateWith { graphs.getString(it) },
            frontend = speech.optJSONObject("frontend")?.let { SpeechFrontend(kind = FrontendKind.fromRawValue(it.getString("kind"))!!) },
            voices = (0 until voices.length()).map { index ->
                val voice = voices.getJSONObject(index)
                SpeechModelVoice(
                    id = voice.getString("id"),
                    name = voice.getString("name"),
                    locales = voice.getJSONArray("locales").strings(),
                    gender = voice.optString("gender").takeIf { it.isNotEmpty() }?.let { VoiceGender.fromRawValue(it) },
                )
            },
        ),
    )
}

private fun JSONArray.strings(): List<String> = (0 until length()).map { getString(it) }
