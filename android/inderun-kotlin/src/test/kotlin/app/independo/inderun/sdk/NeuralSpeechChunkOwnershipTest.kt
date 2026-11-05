package app.independo.inderun.sdk

import app.independo.inderun.contracts.Format
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.contracts.OutputDelivery
import app.independo.inderun.contracts.OutputDeliveryRequest
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.Source
import app.independo.inderun.contracts.SourceType
import app.independo.inderun.contracts.SpeechInput
import app.independo.inderun.contracts.SpeechModelPackage
import app.independo.inderun.contracts.SpeechModelVoice
import app.independo.inderun.contracts.TaskKind
import app.independo.inderun.contracts.TaskOutputType
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestTask
import app.independo.inderun.core.RunContext
import app.independo.inderun.providers.neuralspeech.NeuralSpeechAvailability
import app.independo.inderun.providers.neuralspeech.NeuralSpeechProvider
import app.independo.inderun.providers.neuralspeech.NeuralSpeechRuntime
import app.independo.inderun.providers.neuralspeech.NeuralSpeechSynthesisInput
import app.independo.inderun.providers.neuralspeech.PcmChunk
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

/** Yields three chunks from one buffer it refills with 1, 2 and 3, as a runtime reusing scratch memory does. */
private class ScratchBufferRuntime : NeuralSpeechRuntime {
    override suspend fun availability(modelPackage: ModelPackage) = NeuralSpeechAvailability(true)

    override suspend fun prepare(modelPackage: ModelPackage) = NeuralSpeechAvailability(true)

    override fun synthesize(input: NeuralSpeechSynthesisInput): Flow<PcmChunk> = flow {
        val scratch = ShortArray(4)
        for (fill in 1..3) {
            scratch.fill(fill.toShort())
            emit(PcmChunk(scratch, sampleRate = 24000, isLast = fill == 3))
        }
    }
}

/**
 * The runtime seam's ownership rule on playback: the provider hands a chunk's samples to the host
 * before the runtime's `emit` returns, so a runtime may reuse its buffer. The artifact half lives in
 * `NeuralSpeechProviderTest`.
 */
class NeuralSpeechChunkOwnershipTest {
    private val pkg = ModelPackage(
        id = "fixture-tts",
        version = "1",
        format = Format.Onnx,
        tasks = listOf("text_to_speech"),
        source = Source(sourceType = SourceType.AppManaged),
        speech = SpeechModelPackage(
            pipeline = "fixture",
            sampleRate = 24000,
            graphs = mapOf("acoustic" to "acoustic.onnx"),
            voices = listOf(SpeechModelVoice(id = "v_de", name = "Fixture German", locales = listOf("de-AT"))),
        ),
    )

    @Test
    fun playsEachChunkOfARuntimeThatReusesItsBuffer() = runTest {
        val provider = NeuralSpeechProvider(pkg, ScratchBufferRuntime())
        val audio = FixtureAudioOutputService()
        val request = TaskRequest(
            schemaVersion = SchemaVersion.V1_0,
            task = TaskRequestTask(kind = TaskKind.TEXT_TO_SPEECH),
            speech = SpeechInput(locale = "de-AT", text = "Hallo Welt."),
            delivery = OutputDeliveryRequest(mode = OutputDelivery.Playback),
        )

        val result = provider.run(request, RunContext("run_1", conformanceHostServices().copy(audioOutput = audio)))

        assertEquals(TaskOutputType.PLAYBACK, result.output.type)
        // The fixture keeps the arrays it was handed: copies of the fills, not the one buffer thrice.
        assertEquals(
            listOf(listOf(1, 1, 1, 1), listOf(2, 2, 2, 2), listOf(3, 3, 3, 3)),
            audio.sessions.single().writes.map { samples -> samples.map { it.toInt() } },
        )
    }
}
