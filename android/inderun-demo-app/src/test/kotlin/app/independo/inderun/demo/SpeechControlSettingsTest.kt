package app.independo.inderun.demo

import app.independo.inderun.contracts.ControlDelivery
import app.independo.inderun.contracts.RequestedNumber
import app.independo.inderun.contracts.RequirementLevel
import app.independo.inderun.contracts.SpeechControlId
import app.independo.inderun.contracts.SpeechControlMethod
import app.independo.inderun.contracts.SpeechControlOutcome
import app.independo.inderun.contracts.SpeechControlOutcomeReason
import app.independo.inderun.contracts.SpeechControlPhase
import app.independo.inderun.contracts.SpeechControlRange
import app.independo.inderun.contracts.SpeechControlStatus
import app.independo.inderun.sdk.SpeechVoiceControl
import app.independo.inderun.sdk.SpeechVoiceInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SpeechControlSettingsTest {
    private val voice = SpeechVoiceInfo(
        providerId = "p",
        locale = "de-DE",
        id = "anna",
        controls = listOf(
            SpeechVoiceControl(
                SpeechControlId.SpeechSpeakingRate,
                ControlDelivery.Playback,
                SpeechControlPhase.Synthesis,
                available = true,
                range = SpeechControlRange(max = 2.0, min = 0.5),
            ),
            SpeechVoiceControl(SpeechControlId.SpeechPitch, ControlDelivery.Playback, SpeechControlPhase.Synthesis),
            SpeechVoiceControl(
                SpeechControlId.SpeechPitch,
                ControlDelivery.Artifact,
                SpeechControlPhase.Synthesis,
                available = false,
                reason = "no pitch",
            ),
        ),
    )

    @Test
    fun aSliderUsesTheVoicesRange() {
        val slider = voice.controlSlider(SpeechControlId.SpeechSpeakingRate, ControlDelivery.Playback)
        assertTrue(slider.usable)
        assertEquals(0.5, slider.min, 0.0)
        assertEquals(2.0, slider.max, 0.0)
        assertEquals(1.0, slider.initial, 0.0)
    }

    @Test
    fun unknownUnavailableAndMissingStatesAreDisabledWithAReason() {
        assertEquals("unknown", voice.controlSlider(SpeechControlId.SpeechPitch, ControlDelivery.Playback).reason)
        val unavailable = voice.controlSlider(SpeechControlId.SpeechPitch, ControlDelivery.Artifact)
        assertFalse(unavailable.usable)
        assertEquals("no pitch", unavailable.reason)
        assertEquals("not offered", voice.controlSlider(SpeechControlId.PlaybackVolume, ControlDelivery.Playback).reason)
        assertEquals("pick a voice", null.controlSlider(SpeechControlId.SpeechPitch, ControlDelivery.Playback).reason)
    }

    @Test
    fun choicesBuildOnlyWhatIsTurnedOn() {
        assertNull(SpeechControlChoices(requireRate = true).synthesisControls(voice, ControlDelivery.Playback))
        assertNull(SpeechControlChoices().playbackControls(voice))
        val full = SpeechVoiceInfo(
            providerId = "p",
            locale = "de-DE",
            id = "a",
            controls = listOf(
                control(SpeechControlId.SpeechSpeakingRate, ControlDelivery.Playback, true),
                control(SpeechControlId.SpeechPitch, ControlDelivery.Playback, true),
                control(SpeechControlId.PlaybackVolume, ControlDelivery.Playback, true, 0.0, 1.0),
            ),
        )
        val controls = SpeechControlChoices(rate = 1.5, pitch = 0.8, volume = 0.4, requireRate = true)
        val synthesis = controls.synthesisControls(full, ControlDelivery.Playback)
        assertEquals(RequestedNumber(requirement = RequirementLevel.Required, value = 1.5), synthesis?.speakingRate)
        assertNull(synthesis?.pitch?.requirement)
        assertEquals(0.4, controls.playbackControls(full)?.volume?.value ?: 0.0, 0.0)
    }

    @Test
    fun outcomesShowAppliedAndNotAppliedWithReason() {
        assertNull(null.describeControls())
        val text = listOf(
            SpeechControlOutcome(
                effective = 1.5,
                id = SpeechControlId.SpeechSpeakingRate,
                method = SpeechControlMethod.PlatformSynthesis,
                requested = 1.5,
                status = SpeechControlStatus.Applied,
            ),
            SpeechControlOutcome(
                id = SpeechControlId.PlaybackVolume,
                reason = SpeechControlOutcomeReason.NotReported,
                requested = 0.4,
                status = SpeechControlStatus.NotApplied,
            ),
        ).describeControls()
        assertEquals(
            "speech.speakingRate applied 1.5 (platform_synthesis); playback.volume not applied: not_reported",
            text,
        )
    }

    private fun control(id: SpeechControlId, delivery: ControlDelivery, available: Boolean, min: Double = 0.5, max: Double = 2.0) = SpeechVoiceControl(
        id,
        delivery,
        SpeechControlPhase.Synthesis,
        available = available,
        range = if (available) SpeechControlRange(max = max, min = min) else null,
    )

    @Test
    fun generateDoesNotGetWhatTheArtifactDeliveryRejects() {
        val narrow = SpeechVoiceInfo(
            providerId = "p",
            locale = "de-DE",
            id = "a",
            controls = listOf(
                control(SpeechControlId.SpeechSpeakingRate, ControlDelivery.Playback, true),
                control(SpeechControlId.SpeechSpeakingRate, ControlDelivery.Artifact, true, 0.8, 1.2),
                control(SpeechControlId.SpeechPitch, ControlDelivery.Playback, true),
                control(SpeechControlId.SpeechPitch, ControlDelivery.Artifact, false),
            ),
        )
        val choices = SpeechControlChoices(rate = 1.5, pitch = 1.0)
        assertEquals(1.5, choices.synthesisControls(narrow, ControlDelivery.Playback)?.speakingRate?.value ?: 0.0, 0.0)
        assertEquals(1.0, choices.synthesisControls(narrow, ControlDelivery.Playback)?.pitch?.value ?: 0.0, 0.0)
        // Outside the artifact range and unavailable there: nothing is sent, nothing is clamped.
        assertNull(choices.synthesisControls(narrow, ControlDelivery.Artifact))
        assertEquals("outside 0.8\u20131.2", narrow.deliveryNote(SpeechControlId.SpeechSpeakingRate, ControlDelivery.Artifact, 1.5))
        assertEquals("unavailable", narrow.deliveryNote(SpeechControlId.SpeechPitch, ControlDelivery.Artifact, 1.0))
    }

    @Test
    fun anArtifactOnlyControlGoesToGenerateAndNotToSpeak() {
        val artifactOnly = SpeechVoiceInfo(
            providerId = "p",
            locale = "de-DE",
            id = "a",
            controls = listOf(
                control(SpeechControlId.SpeechSpeakingRate, ControlDelivery.Playback, false),
                control(SpeechControlId.SpeechSpeakingRate, ControlDelivery.Artifact, true),
            ),
        )
        val choices = SpeechControlChoices(rate = 1.0)
        assertNull(choices.synthesisControls(artifactOnly, ControlDelivery.Playback))
        assertEquals(1.0, choices.synthesisControls(artifactOnly, ControlDelivery.Artifact)?.speakingRate?.value ?: 0.0, 0.0)
        assertNull(choices.synthesisControls(null, ControlDelivery.Artifact))
    }
}
