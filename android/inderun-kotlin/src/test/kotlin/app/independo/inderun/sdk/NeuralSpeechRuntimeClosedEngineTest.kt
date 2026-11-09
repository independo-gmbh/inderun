package app.independo.inderun.sdk

import app.independo.inderun.contracts.AttemptOutcome
import app.independo.inderun.contracts.Format
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.contracts.Source
import app.independo.inderun.contracts.SourceType
import app.independo.inderun.contracts.SpeechModelPackage
import app.independo.inderun.contracts.SpeechModelVoice
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ModelProfiles
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.providers.neuralspeech.FixtureNeuralSpeechRuntime
import app.independo.inderun.providers.neuralspeech.NeuralSpeechProvider
import app.independo.inderun.providers.neuralspeech.NeuralSpeechRuntime
import app.independo.inderun.providers.neuralspeech.NeuralSpeechRuntimeError
import app.independo.inderun.providers.neuralspeech.NeuralSpeechRuntimeErrorKind
import app.independo.inderun.providers.neuralspeech.NeuralSpeechSynthesisInput
import app.independo.inderun.providers.neuralspeech.PcmChunk
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * What a closed runtime does through the engine (Kotlin counterpart of Web provider.test.ts and
 * Swift NeuralSpeechProviderTests): before the provider has committed, the next provider is tried;
 * after, the run ends with a terminal `Unavailable` / `runtime_closed`.
 */
@RunWith(RobolectricTestRunner::class)
class NeuralSpeechRuntimeClosedEngineTest {
    private val modelPackage = ModelPackage(
        id = "fixture-tts",
        version = "1",
        format = Format.Onnx,
        tasks = listOf("text_to_speech"),
        source = Source(sourceType = SourceType.AppManaged),
        speech = SpeechModelPackage(
            pipeline = "fixture",
            sampleRate = 24000,
            graphs = mapOf("acoustic" to "acoustic.onnx"),
            voices = listOf(SpeechModelVoice(id = "v_de", name = "German", locales = listOf("de-AT"))),
        ),
    )

    private fun closed() = NeuralSpeechRuntimeError(NeuralSpeechRuntimeErrorKind.Unavailable, "runtime closed", code = "runtime_closed")

    /** The fixture; sentence number [closedFrom] (from 1) and every later one fail as a closed runtime does. */
    private inner class ClosingRuntime(private val closedFrom: Int) : NeuralSpeechRuntime {
        val fixture = FixtureNeuralSpeechRuntime()
        private var calls = 0

        override suspend fun availability(modelPackage: ModelPackage) = fixture.availability(modelPackage)

        override suspend fun prepare(modelPackage: ModelPackage) = fixture.prepare(modelPackage)

        override fun synthesize(input: NeuralSpeechSynthesisInput): Flow<PcmChunk> {
            calls += 1
            val number = calls
            return flow {
                if (number >= closedFrom) throw closed()
                emitAll(fixture.synthesize(input))
            }
        }
    }

    private class World(
        modelPackage: ModelPackage,
        a: NeuralSpeechRuntime,
        val b: FixtureNeuralSpeechRuntime,
    ) {
        val audio = FixtureAudioOutputService()
        val engine = IndeRun(
            ProviderRegistry().apply {
                register(NeuralSpeechProvider(modelPackage, a, id = "tts-a"))
                register(NeuralSpeechProvider(modelPackage, b, id = "tts-b"))
            },
            conformanceHostServices().copy(audioOutput = audio),
            modelProfiles = ModelProfiles(mapOf("neural" to listOf("tts-a", "tts-b"))),
        )
    }

    @Test
    fun preCommitRuntimeClosedFallsBackToTheNextProvider() = runTest {
        val world = World(modelPackage, ClosingRuntime(closedFrom = 1), FixtureNeuralSpeechRuntime())

        val spoken = world.engine.speak(SpeakOptions("Hallo Welt. Wie geht es dir?", "de-AT", model = "neural"), this).result.await()

        val attempts = spoken.provenance!!.attempts!!
        assertEquals(listOf("tts-a", "tts-b"), attempts.map { it.providerId })
        assertEquals(AttemptOutcome.Failed, attempts[0].outcome)
        assertEquals(IndeRunErrorClass.Unavailable, attempts[0].errorClass)
        assertEquals(AttemptOutcome.Succeeded, attempts[1].outcome)
        assertEquals(2, world.b.synthesized.size)
    }

    @Test
    fun committedRuntimeClosedEndsTerminalWithoutTryingTheOtherProvider() = runTest {
        val world = World(modelPackage, ClosingRuntime(closedFrom = 2), FixtureNeuralSpeechRuntime())

        try {
            world.engine.speak(SpeakOptions("Hallo Welt. Wie geht es dir?", "de-AT", model = "neural"), this).result.await()
            fail("expected a terminal failure")
        } catch (error: IndeRunException) {
            assertEquals(IndeRunErrorClass.Unavailable, error.errorClass)
            assertEquals("runtime_closed", error.details?.get("code"))
            assertEquals(listOf("tts-a"), error.provenance!!.attempts!!.map { it.providerId })
            assertTrue(error.provenance!!.attempts!!.single().committed == true)
        }
        assertEquals(0, world.b.synthesized.size)
    }
}
