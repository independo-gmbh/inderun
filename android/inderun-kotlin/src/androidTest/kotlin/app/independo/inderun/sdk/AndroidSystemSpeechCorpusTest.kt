package app.independo.inderun.sdk

import android.content.Context
import android.util.Log
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import app.independo.inderun.contracts.ArtifactReadRequest
import app.independo.inderun.contracts.CancelSemantics
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.Locality
import app.independo.inderun.contracts.MediaArtifact
import app.independo.inderun.contracts.OutputDelivery
import app.independo.inderun.contracts.PlaybackOutput
import app.independo.inderun.contracts.Privacy
import app.independo.inderun.contracts.ProviderDescriptor
import app.independo.inderun.contracts.ProviderDynamicCapabilities
import app.independo.inderun.contracts.ProviderSupports
import app.independo.inderun.contracts.ProviderTaskCapability
import app.independo.inderun.contracts.ProviderTaskInteraction
import app.independo.inderun.contracts.ProviderTaskOutput
import app.independo.inderun.contracts.ProviderTransport
import app.independo.inderun.contracts.ProviderType
import app.independo.inderun.contracts.TaskInputKind
import app.independo.inderun.contracts.TaskKind
import app.independo.inderun.contracts.TaskOutput
import app.independo.inderun.contracts.TaskOutputType
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.HostServicesFactory
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.core.ProviderStreamContext
import app.independo.inderun.core.ProviderStreamEvent
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.StreamingProviderAdapter
import app.independo.inderun.providers.systemspeech.AndroidSystemSpeechProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * The shared real-audio corpus (`contracts/fixtures/speech/utterance-corpus.json`, #251) through
 * the shipping provider, the real engine and the device's real `TextToSpeech`. An utterance whose
 * locale has no on-device voice is skipped by id; a refusal the corpus expects must happen on
 * every device. Each run logs one `INDERUN-TRACE` line under the `IndeRunCorpus` tag, with ids and
 * measurements but never text, for `docs/verification/system-speech.md`.
 *
 * Run with `./gradlew :inderun-kotlin:connectedAndroidTest` against an emulator or device.
 */
@RunWith(AndroidJUnit4::class)
class AndroidSystemSpeechCorpusTest {
    private data class Utterance(
        val id: String,
        val locale: String,
        val category: String,
        val text: String,
        val expect: String,
        val errorClass: String?,
    )

    private val context: Context = ApplicationProvider.getApplicationContext()
    private val scope = CoroutineScope(Dispatchers.Default)
    private lateinit var provider: AndroidSystemSpeechProvider
    private lateinit var corpus: JSONObject
    private lateinit var utterances: List<Utterance>

    @Before
    fun setUp() {
        provider = AndroidSystemSpeechProvider(context)
        corpus = JSONObject(
            context.assets.open("utterance-corpus.json").bufferedReader().use { it.readText() },
        )
        val list = corpus.getJSONArray("utterances")
        utterances = (0 until list.length()).map { index ->
            val entry = list.getJSONObject(index)
            Utterance(
                id = entry.getString("id"),
                locale = entry.getString("locale"),
                category = entry.getString("category"),
                text = entry.getString("text"),
                expect = entry.getString("expect"),
                errorClass = entry.optString("errorClass").takeIf { it.isNotEmpty() },
            )
        }
    }

    @After
    fun tearDown() {
        provider.close()
    }

    private fun utterance(id: String) = utterances.single { it.id == id }

    /**
     * No on-device voice for the locale, or one the engine has not downloaded yet: a fresh
     * emulator image lists German voices as not installed. Either way nothing could play.
     */
    private fun IndeRunException.isMissingVoice() = errorClass == IndeRunErrorClass.CapabilityMismatch || details?.get("code") == "not_ready"

    private fun inderun(vararg others: StreamingProviderAdapter): IndeRun {
        val registry = ProviderRegistry().apply {
            register(provider)
            others.forEach { register(it) }
        }
        return IndeRun(registry, HostServicesFactory.create(context))
    }

    private fun local(utterance: Utterance) = SpeakOptions(
        utterance.text,
        locale = utterance.locale,
        execution = SpeechExecutionOptions(privacy = Privacy.LocalRequired),
    )

    private fun trace(fields: Map<String, Any?>) {
        Log.i(TAG, "INDERUN-TRACE android ${JSONObject(fields.filterValues { it != null })}")
    }

    private fun speechFiles() = File(context.cacheDir, "inderun-speech")

    // --- artifacts ------------------------------------------------------------------------------

    @Test
    fun everyCorpusUtteranceRendersARetrievableWavOrIsSkippedByLocale() = runBlocking {
        val engine = inderun()
        val rendered = mutableListOf<String>()
        val skipped = mutableListOf<String>()
        val durations = mutableMapOf<String, Double>()

        for (utterance in utterances.filter { it.expect == "speak" }) {
            val started = System.nanoTime()
            val speech = try {
                engine.generateSpeech(GenerateSpeechOptions(local(utterance), mediaTypes = listOf("audio/wav")))
            } catch (error: IndeRunException) {
                if (!error.isMissingVoice()) throw error
                skipped += utterance.id
                continue
            }
            val synthesisMs = (System.nanoTime() - started) / 1_000_000
            val wav = readAll(engine, speech.artifact.id)
            assertWav(wav, speech.artifact, utterance.id)
            assertEquals(utterance.id, Locality.OnDevice, speech.provenance?.locality)
            assertEquals(utterance.id, "android_system_speech", speech.provenance?.providerId)
            // The engine wrote a temporary file; the provider read it and deleted it.
            assertTrue(utterance.id, speechFiles().listFiles().isNullOrEmpty())

            engine.disposeArtifact(speech.artifact)
            assertGone(engine, speech.artifact.id)
            rendered += utterance.id
            speech.artifact.durationMs?.let { durations[utterance.id] = it }
            trace(
                mapOf(
                    "id" to utterance.id,
                    "delivery" to "artifact",
                    "resolvedLocale" to speech.speech?.locale,
                    "voice" to speech.speech?.voice?.id,
                    "locality" to speech.provenance?.locality?.rawValue,
                    "bytes" to wav.size,
                    "sampleRate" to uint32(wav, 24),
                    "durationMs" to speech.artifact.durationMs,
                    "synthesisMs" to synthesisMs,
                ),
            )
        }

        Log.i(TAG, "INDERUN-TRACE android corpus rendered=$rendered skipped=$skipped")
        assertLongTextIsNotCutOff(durations)
        assumeTrue("No corpus locale has an on-device voice here: $skipped", rendered.isNotEmpty())
    }

    @Test
    fun refusedUtterancesNeverReachTheEngine() = runBlocking {
        val engine = inderun()

        for (utterance in utterances.filter { it.expect == "refuse" }) {
            for (call in listOf("speak", "generateSpeech")) {
                try {
                    if (call == "speak") {
                        engine.speak(local(utterance), scope).result.await()
                    } else {
                        engine.generateSpeech(GenerateSpeechOptions(local(utterance)))
                    }
                    fail("${utterance.id}: $call should have been refused")
                } catch (error: IndeRunException) {
                    assertEquals("${utterance.id} $call", utterance.errorClass, error.errorClass.rawValue)
                    // Refused by routing: no provider was entered, so nothing could be audible.
                    assertTrue("${utterance.id} $call", error.provenance?.attempts.isNullOrEmpty())
                    trace(mapOf("id" to utterance.id, "call" to call, "errorClass" to error.errorClass.rawValue))
                }
            }
        }
    }

    @Test
    fun repeatedRendersAreIndependentArtifacts() = runBlocking {
        val engine = inderun()
        val repeat = corpus.getJSONObject("scenarios").getJSONObject("repeat")
        val ids = repeat.getJSONArray("utteranceIds")
        var covered = 0

        for (index in 0 until ids.length()) {
            val utterance = utterance(ids.getString(index))
            val artifacts = try {
                List(repeat.getInt("count")) {
                    engine.generateSpeech(GenerateSpeechOptions(local(utterance))).artifact
                }
            } catch (error: IndeRunException) {
                if (!error.isMissingVoice()) throw error
                continue
            }
            assertEquals("${utterance.id}: ids must differ", artifacts.size, artifacts.map { it.id }.toSet().size)
            // Disposing one leaves the others readable.
            artifacts.forEachIndexed { position, artifact ->
                for (later in artifacts.drop(position)) {
                    engine.readArtifact(ArtifactReadRequest(artifactId = later.id, maxBytes = 64L, offset = 0L))
                }
                engine.disposeArtifact(artifact)
                assertGone(engine, artifact.id)
            }
            covered += 1
            trace(mapOf("id" to utterance.id, "scenario" to "repeat", "bytes" to artifacts.map { it.byteLength }))
        }
        assumeTrue("No repeat utterance has an on-device voice here.", covered > 0)
    }

    // --- playback lifecycle ---------------------------------------------------------------------

    /**
     * A real stop mid-utterance ends with one cancelled outcome, a fallback provider is never asked
     * to say the text again, and the engine speaks the next utterance.
     */
    @Test
    fun cancelMidUtteranceEndsOnceAndTheNextUtterancePlays() = runBlocking {
        val scenario = corpus.getJSONObject("scenarios").getJSONObject("cancelMidUtterance")
        val fallback = FallbackSpeechProvider()
        val engine = inderun(fallback)
        val long = utterance(scenario.getString("utteranceId"))

        val playback = try {
            engine.speak(local(long), scope)
        } catch (error: IndeRunException) {
            assumeTrue("No on-device ${long.locale} voice here.", !error.isMissingVoice())
            throw error
        }
        delay(scenario.getLong("cancelAfterMs"))
        val stopIssued = System.nanoTime()
        playback.cancel("corpus cancel")
        val stopped = playback.result.await()
        val stopLatencyMs = (System.nanoTime() - stopIssued) / 1_000_000

        assertEquals(FinishReason.CANCELLED, stopped.finishReason)
        assertEquals(FinishReason.CANCELLED, playback.result.await().finishReason)
        assertEquals("a committed playback is never repeated by a fallback", 0, fallback.calls)
        assertEquals(listOf("android_system_speech"), stopped.provenance?.attempts?.map { it.providerId })
        assertEquals(true, stopped.provenance?.attempts?.single()?.committed)
        trace(
            mapOf(
                "id" to long.id,
                "scenario" to "cancelMidUtterance",
                "finishReason" to "cancelled",
                "stopLatencyMs" to stopLatencyMs,
                "fallbackCalls" to fallback.calls,
            ),
        )

        val followUp = utterance(scenario.getString("followUpUtteranceId"))
        val next = withTimeoutOrNull(30_000) { engine.speak(local(followUp), scope).result.await() }
        assumeTrue("The engine did not finish ${followUp.id} within 30 s.", next != null)
        assertEquals(FinishReason.STOP, next!!.finishReason)
        assertEquals(Locality.OnDevice, next.provenance?.locality)
        assertEquals(0, fallback.calls)
        trace(
            mapOf(
                "id" to followUp.id,
                "scenario" to "followUp",
                "finishReason" to next.finishReason?.rawValue,
                "durationMs" to next.durationMs,
                "firstAudioMs" to next.firstAudioMs,
                "voice" to next.speech?.voice?.id,
            ),
        )
    }

    // --- helpers --------------------------------------------------------------------------------

    /**
     * Audio grows with text: a long utterance must last at least half as many times longer than the
     * short one of its locale as its text is. Apple's synthesizer once ended a render at its first
     * internal chunk, which passed every per-file check; this holds Android to the same bar.
     */
    private fun assertLongTextIsNotCutOff(durations: Map<String, Double>) {
        for (long in utterances.filter { it.category == "long" }) {
            val short = utterances.firstOrNull { it.category == "short" && it.locale == long.locale } ?: continue
            val longMs = durations[long.id] ?: continue
            val shortMs = durations[short.id] ?: continue
            val textRatio = long.text.length.toDouble() / short.text.length
            assertTrue("${long.id} looks cut off", longMs / shortMs >= textRatio / 2)
        }
    }

    private suspend fun readAll(engine: IndeRun, artifactId: String): ByteArray {
        val bytes = java.io.ByteArrayOutputStream()
        var offset = 0
        while (true) {
            val chunk = engine.readArtifact(ArtifactReadRequest(artifactId = artifactId, maxBytes = 64L * 1024, offset = offset.toLong()))
            bytes.write(chunk.bytes)
            offset += chunk.bytes.size
            if (chunk.done) return bytes.toByteArray()
        }
    }

    private fun assertWav(wav: ByteArray, artifact: MediaArtifact, id: String) {
        assertEquals(id, "audio/wav", artifact.mediaType)
        assertEquals(id, artifact.byteLength?.toInt(), wav.size)
        assertTrue(id, wav.size > 44)
        assertTrue(id, wav.size <= 16 * 1024 * 1024)
        assertEquals(id, "RIFF", wav.copyOfRange(0, 4).decodeToString())
        assertEquals(id, "WAVE", wav.copyOfRange(8, 12).decodeToString())
        assertEquals("$id: RIFF size", wav.size - 8L, uint32(wav, 4))
        // The engine writes the file, so walk its chunks rather than assume a 44-byte header.
        var offset = 12
        var format: Int? = null
        while (offset + 8 <= wav.size) {
            val chunk = wav.copyOfRange(offset, offset + 4).decodeToString()
            val size = uint32(wav, offset + 4)
            if (chunk == "fmt ") format = offset + 8
            if (chunk == "data") break
            offset += 8 + size.toInt() + (size.toInt() and 1)
        }
        val fmt = checkNotNull(format) { "$id: no fmt chunk" }
        assertEquals("$id: data chunk", "data", wav.copyOfRange(offset, offset + 4).decodeToString())
        val channels = uint16(wav, fmt + 2)
        val sampleRate = uint32(wav, fmt + 4)
        val byteRate = uint32(wav, fmt + 8)
        val blockAlign = uint16(wav, fmt + 12)
        assertEquals("$id: PCM", 1, uint16(wav, fmt))
        assertTrue("$id: channels", channels > 0)
        assertEquals("$id: 16-bit", 16, uint16(wav, fmt + 14))
        assertTrue("$id: sample rate", sampleRate > 0)
        assertEquals("$id: block align", channels * 2, blockAlign)
        assertEquals("$id: byte rate", sampleRate * blockAlign, byteRate)
        // A truncated file declares more data than it holds.
        val dataBytes = uint32(wav, offset + 4)
        assertEquals("$id: data size", wav.size - offset - 8L, dataBytes)
        val durationMs = checkNotNull(artifact.durationMs) { "$id: no duration" }
        assertTrue("$id: duration", durationMs > 0.0)
        assertEquals("$id: duration", dataBytes.toDouble() / byteRate * 1000, durationMs, 1.0)
    }

    private suspend fun assertGone(engine: IndeRun, artifactId: String) {
        try {
            engine.readArtifact(ArtifactReadRequest(artifactId = artifactId))
            fail("expected a disposed artifact to be gone")
        } catch (error: IndeRunException) {
            assertEquals("artifact_not_found", error.details?.get("code"))
        }
    }

    private fun uint16(data: ByteArray, at: Int) = (data[at].toInt() and 0xff) or ((data[at + 1].toInt() and 0xff) shl 8)

    private fun uint32(data: ByteArray, at: Int): Long = (0 until 4).fold(0L) { value, index ->
        value or ((data[at + index].toLong() and 0xff) shl (8 * index))
    }

    /** A second on-device speech target that records whether the engine fell back to it. */
    private class FallbackSpeechProvider : StreamingProviderAdapter {
        @Volatile
        var calls = 0
            private set

        override fun describe() = ProviderDescriptor(
            id = "z_fallback",
            type = ProviderType.Local,
            transport = ProviderTransport.InProcess,
            supports = ProviderSupports(
                run = true,
                streaming = true,
                realtime = false,
                tools = false,
                reasoningEvents = false,
                structuredOutput = false,
                multimodal = false,
            ),
            cancel = CancelSemantics.Soft,
            tasks = listOf(TaskKind.TEXT_TO_SPEECH.rawValue),
            taskCapabilities = listOf(
                ProviderTaskCapability(
                    kind = TaskKind.TEXT_TO_SPEECH.rawValue,
                    inputs = listOf(TaskInputKind.Text),
                    interaction = ProviderTaskInteraction(run = true, stream = true),
                    cancel = CancelSemantics.Soft,
                    outputs = listOf(ProviderTaskOutput(delivery = OutputDelivery.Playback)),
                    locales = listOf("de-AT", "de-DE", "en-US"),
                ),
            ),
        )

        override suspend fun capabilities(host: HostServices) = ProviderDynamicCapabilities(available = true)

        override suspend fun run(request: TaskRequest, context: RunContext): TaskResult = error("not used")

        override fun stream(request: TaskRequest, context: ProviderStreamContext): Flow<ProviderStreamEvent> {
            calls += 1
            return flowOf(
                ProviderStreamEvent.Result(
                    TaskOutput(type = TaskOutputType.PLAYBACK, playback = PlaybackOutput(durationMs = 1.0)),
                    FinishReason.STOP,
                ),
            )
        }
    }

    private companion object {
        const val TAG = "IndeRunCorpus"
    }
}
