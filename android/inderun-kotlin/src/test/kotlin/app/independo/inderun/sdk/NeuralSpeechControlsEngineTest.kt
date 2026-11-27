package app.independo.inderun.sdk

import app.independo.inderun.contracts.Format
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.contracts.RequestedNumber
import app.independo.inderun.contracts.RequirementLevel
import app.independo.inderun.contracts.SharedSynthesisControls
import app.independo.inderun.contracts.Source
import app.independo.inderun.contracts.SourceType
import app.independo.inderun.contracts.SpeechControlId
import app.independo.inderun.contracts.SpeechControlOutcomeReason
import app.independo.inderun.contracts.SpeechControlStatus
import app.independo.inderun.contracts.SpeechModelPackage
import app.independo.inderun.contracts.SpeechModelVoice
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.providers.neuralspeech.FixtureNeuralSpeechRuntime
import app.independo.inderun.providers.neuralspeech.NeuralSpeechProvider
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The neural speech family declares no speech controls (ADR 025), so it never claims one: a
 * preferred control is recorded `not_applied`, a required one refuses the provider. Counterpart of
 * the Web `NeuralSpeechWebProvider speech controls` suite and the Swift `testNeuralSpeechControls...` cases.
 */
@RunWith(RobolectricTestRunner::class)
class NeuralSpeechControlsEngineTest {
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

    private fun engine(provider: NeuralSpeechProvider) = IndeRun(
        ProviderRegistry().apply { register(provider) },
        conformanceHostServices().copy(audioOutput = FixtureAudioOutputService()),
    )

    @Test
    fun declaresNoControlsAndReportsNoControlStates() = runTest {
        val provider = NeuralSpeechProvider(modelPackage, FixtureNeuralSpeechRuntime())

        assertNull(provider.describe().taskCapabilities?.single()?.controls)
        val dynamic = provider.capabilities(conformanceHostServices())
        assertNull(dynamic.taskCapabilities?.single()?.controlStates)
    }

    @Test
    fun aPreferredControlIsNotAppliedAndNeverClaimed() = runTest {
        val provider = NeuralSpeechProvider(modelPackage, FixtureNeuralSpeechRuntime())

        val ending = engine(provider).speak(
            SpeakOptions(
                "Hallo Welt.",
                "de-AT",
                controls = SharedSynthesisControls(
                    pitch = RequestedNumber(value = 0.8),
                    speakingRate = RequestedNumber(value = 1.5),
                ),
            ),
            this,
        ).result.await()

        val records = ending.speech!!.controls!!
        assertEquals(listOf(SpeechControlId.SpeechSpeakingRate, SpeechControlId.SpeechPitch), records.map { it.id })
        assertTrue(records.all { it.status == SpeechControlStatus.NotApplied })
        assertTrue(records.all { it.reason == SpeechControlOutcomeReason.NotReported })
        assertTrue(records.all { it.effective == null })
    }

    @Test
    fun aRequiredControlRefusesTheProvider() = runTest {
        val provider = NeuralSpeechProvider(modelPackage, FixtureNeuralSpeechRuntime())

        try {
            engine(provider).speak(
                SpeakOptions(
                    "Hallo Welt.",
                    "de-AT",
                    controls = SharedSynthesisControls(
                        speakingRate = RequestedNumber(requirement = RequirementLevel.Required, value = 1.5),
                    ),
                ),
                this,
            ).result.await()
            fail("expected a refusal")
        } catch (error: IndeRunException) {
            assertEquals(IndeRunErrorClass.CapabilityMismatch, error.errorClass)
        }
    }
}
