package app.independo.inderun.providers.neuralspeech

import app.independo.inderun.contracts.Format
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.contracts.SpeechModelPackage
import app.independo.inderun.contracts.SpeechModelVoice
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import kotlin.math.PI
import kotlin.math.sin

class FixtureNeuralSpeechRuntimeTest {
    private val pkg = ModelPackage(
        format = Format.Onnx,
        id = "fixture-voice",
        tasks = listOf("text_to_speech"),
        speech = SpeechModelPackage(
            pipeline = "fixture",
            sampleRate = 24000,
            graphs = mapOf("acoustic" to "acoustic.onnx"),
            voices = listOf(SpeechModelVoice(id = "v1", name = "V1", locales = listOf("de-DE"))),
        ),
    )

    // 28 characters: 1400 ms at the default 50 ms per character.
    private val text = "abcdefghijklmnopqrstuvwxyz12"

    private fun input(text: String = this.text, locale: String = "de-DE", voiceId: String = "v1") = NeuralSpeechSynthesisInput(modelPackage = pkg, text = text, locale = locale, voiceId = voiceId)

    private fun sineAt(n: Int): Short = Math.round(0.2 * 32767 * sin(2 * PI * 440 * n / 24000)).toShort()

    @Test
    fun usesA28CharacterSentence() {
        assertEquals(28, text.length)
    }

    @Test
    fun yields14ChunksOf2400FramesWithIsLastOnlyOnTheLast() = runTest {
        val chunks = FixtureNeuralSpeechRuntime().synthesize(input()).toList()

        assertEquals(14, chunks.size)
        assertTrue(chunks.all { it.samples.size == 2400 && it.sampleRate == 24000 })
        assertEquals(33600, chunks.sumOf { it.samples.size })
        assertEquals(List(13) { false } + true, chunks.map { it.isLast })
    }

    @Test
    fun emitsAPartialLastChunkWhenTheDurationIsNotAMultipleOfChunkMs() = runTest {
        val chunks = FixtureNeuralSpeechRuntime(FixtureNeuralSpeechRuntimeOptions(chunkMs = 1000)).synthesize(input()).toList()

        assertEquals(listOf(24000, 9600), chunks.map { it.samples.size })
    }

    @Test
    fun keepsThe440HzSinePhaseContinuousAcrossChunks() = runTest {
        val chunks = FixtureNeuralSpeechRuntime().synthesize(input()).toList()

        assertEquals(sineAt(1), chunks[0].samples[1])
        assertEquals(sineAt(2400), chunks[1].samples[0])
        assertEquals(sineAt(2405), chunks[1].samples[5])
        // -14 dBFS: the peak never exceeds 0.2 of full scale.
        assertTrue(chunks.all { chunk -> chunk.samples.all { it in -6553..6553 } })
    }

    @Test
    fun stopsBetweenChunksWhenTheCollectorIsCancelled() = runTest {
        val runtime = FixtureNeuralSpeechRuntime(FixtureNeuralSpeechRuntimeOptions(delayMs = 10))
        val chunks = mutableListOf<PcmChunk>()

        val job = launch {
            runtime.synthesize(input()).collect {
                chunks += it
                if (chunks.size == 2) currentCoroutineContext().cancel()
            }
        }
        job.join()

        assertEquals(2, chunks.size)
        assertTrue(job.isCancelled)
    }

    @Test
    fun throwsAnInternalErrorAfterFailAfterChunksChunks() = runTest {
        val chunks = mutableListOf<PcmChunk>()
        try {
            FixtureNeuralSpeechRuntime(FixtureNeuralSpeechRuntimeOptions(failAfterChunks = 1))
                .synthesize(input())
                .collect { chunks += it }
            fail("expected a failure")
        } catch (error: NeuralSpeechRuntimeError) {
            assertEquals(NeuralSpeechRuntimeErrorKind.Internal, error.kind)
        }
        assertEquals(1, chunks.size)
    }

    @Test
    fun recordsCallsAndScriptedResults() = runTest {
        val runtime = FixtureNeuralSpeechRuntime(
            FixtureNeuralSpeechRuntimeOptions(
                availability = NeuralSpeechAvailability(available = false, reason = "no gpu"),
                prepareResult = NeuralSpeechAvailability(available = false, reason = "download refused"),
            ),
        )

        runtime.synthesize(input(text = "Hi", locale = "en-US", voiceId = "v2")).toList()

        assertEquals(listOf(Triple("Hi", "en-US", "v2")), runtime.synthesized.map { Triple(it.text, it.locale, it.voiceId) })
        assertEquals(NeuralSpeechAvailability(available = false, reason = "no gpu"), runtime.availability(pkg))
        assertEquals(NeuralSpeechAvailability(available = false, reason = "download refused"), runtime.prepare(pkg))
        assertEquals(1, runtime.availabilityCalls)
        assertEquals(1, runtime.prepareCalls)
    }

    @Test
    fun comparesChunksByContent() {
        assertEquals(PcmChunk(shortArrayOf(1, 2), 24000, true), PcmChunk(shortArrayOf(1, 2), 24000, true))
        assertEquals(PcmChunk(shortArrayOf(1, 2), 24000, true).hashCode(), PcmChunk(shortArrayOf(1, 2), 24000, true).hashCode())
        assertTrue(PcmChunk(shortArrayOf(1, 2), 24000, true) != PcmChunk(shortArrayOf(1, 3), 24000, true))
    }

    // --- close() -----------------------------------------------------------------------------

    private fun assertRuntimeClosed(error: Throwable) {
        assertTrue(error.toString(), error is NeuralSpeechRuntimeError)
        error as NeuralSpeechRuntimeError
        assertEquals(NeuralSpeechRuntimeErrorKind.Unavailable, error.kind)
        assertEquals("runtime closed", error.message)
        assertEquals("runtime_closed", error.code)
    }

    @Test
    fun closeIsIdempotentAndAvailabilityAndPrepareReportRuntimeClosed() = runTest {
        val runtime = FixtureNeuralSpeechRuntime()
        runtime.close()
        runtime.close()

        assertEquals(NeuralSpeechAvailability(false, "runtime closed"), runtime.availability(pkg))
        try {
            runtime.prepare(pkg)
            fail("expected runtime_closed")
        } catch (error: NeuralSpeechRuntimeError) {
            assertRuntimeClosed(error)
        }
    }

    @Test
    fun synthesizeAfterCloseFailsWithRuntimeClosedAndRecordsNothing() = runTest {
        val runtime = FixtureNeuralSpeechRuntime()
        runtime.close()
        try {
            runtime.synthesize(input()).toList()
            fail("expected runtime_closed")
        } catch (error: NeuralSpeechRuntimeError) {
            assertRuntimeClosed(error)
        }
        assertEquals(0, runtime.synthesized.size)
    }

    @Test
    fun aSentenceInProgressFailsAtItsNextChunk() = runTest {
        val runtime = FixtureNeuralSpeechRuntime()
        val delivered = mutableListOf<PcmChunk>()
        try {
            runtime.synthesize(input()).collect {
                delivered += it
                runtime.close()
            }
            fail("expected runtime_closed")
        } catch (error: NeuralSpeechRuntimeError) {
            assertRuntimeClosed(error)
        }
        assertEquals(1, delivered.size)
    }

    @Test
    fun cancellationWinsOverClose() = runTest {
        val runtime = FixtureNeuralSpeechRuntime()
        var failure: Throwable? = null
        val job = launch {
            try {
                runtime.synthesize(input()).collect {
                    runtime.close()
                    currentCoroutineContext().cancel()
                }
            } catch (error: Throwable) {
                failure = error
                throw error
            }
        }
        job.join()

        assertTrue(failure.toString(), failure is kotlinx.coroutines.CancellationException)
    }

    @Test
    fun aSentenceWhoseLastChunkWasDeliveredCompletes() = runTest {
        val runtime = FixtureNeuralSpeechRuntime(FixtureNeuralSpeechRuntimeOptions(chunkMs = 2000))
        val delivered = mutableListOf<PcmChunk>()
        runtime.synthesize(input()).collect {
            delivered += it
            if (it.isLast) runtime.close()
        }

        assertTrue(delivered.last().isLast)
    }
}
