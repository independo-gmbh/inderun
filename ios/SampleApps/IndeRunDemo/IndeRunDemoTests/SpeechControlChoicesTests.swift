import IndeRunContracts
import IndeRunSwift
import XCTest
@testable import IndeRunDemo

final class SpeechControlChoicesTests: XCTestCase {
    /// The facade's own types have internal initializers, so the voice is decoded, as any app gets it.
    private let voice: SpeechVoiceInfo = {
        let json = """
        {"providerId": "apple_system_speech", "kind": "platform", "locale": "de-DE", "id": "anna",
         "controls": [
           {"id": "speech.speakingRate", "delivery": "playback", "phase": "synthesis", "available": true,
            "range": {"min": 0.5, "max": 2}},
           {"id": "speech.pitch", "delivery": "playback", "phase": "synthesis"},
           {"id": "speech.pitch", "delivery": "artifact", "phase": "synthesis", "available": false,
            "reason": "no pitch"}
         ]}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(SpeechVoiceInfo.self, from: Data(json.utf8))
    }()

    private static func decode(_ controls: String) -> SpeechVoiceInfo {
        let json = """
        {"providerId": "apple_system_speech", "kind": "platform", "locale": "de-DE", "id": "a", "controls": \(controls)}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(SpeechVoiceInfo.self, from: Data(json.utf8))
    }

    func testGenerateDoesNotGetWhatTheArtifactDeliveryRejects() {
        let narrow = Self.decode("""
        [{"id": "speech.speakingRate", "delivery": "playback", "phase": "synthesis", "available": true,
          "range": {"min": 0.5, "max": 2}},
         {"id": "speech.speakingRate", "delivery": "artifact", "phase": "synthesis", "available": true,
          "range": {"min": 0.8, "max": 1.2}},
         {"id": "speech.pitch", "delivery": "playback", "phase": "synthesis", "available": true,
          "range": {"min": 0.5, "max": 2}},
         {"id": "speech.pitch", "delivery": "artifact", "phase": "synthesis", "available": false}]
        """)
        let choices = SpeechControlChoices(rate: 1.5, pitch: 1.0)
        XCTAssertEqual(choices.synthesisControls(voice: narrow, delivery: .playback)?.speakingRate?.value, 1.5)
        XCTAssertEqual(choices.synthesisControls(voice: narrow, delivery: .playback)?.pitch?.value, 1.0)
        // Outside the artifact range and unavailable there: nothing is sent, nothing is clamped.
        XCTAssertNil(choices.synthesisControls(voice: narrow, delivery: .artifact))
        XCTAssertEqual(
            Optional(narrow).deliveryNote(.speechSpeakingRate, delivery: .artifact, value: 1.5),
            "outside 0.8\u{2013}1.2"
        )
        XCTAssertEqual(Optional(narrow).deliveryNote(.speechPitch, delivery: .artifact, value: 1.0), "unavailable")
    }

    func testAnArtifactOnlyControlGoesToGenerateAndNotToSpeak() {
        let artifactOnly = Self.decode("""
        [{"id": "speech.speakingRate", "delivery": "playback", "phase": "synthesis", "available": false},
         {"id": "speech.speakingRate", "delivery": "artifact", "phase": "synthesis", "available": true,
          "range": {"min": 0.5, "max": 2}}]
        """)
        let choices = SpeechControlChoices(rate: 1.0)
        XCTAssertNil(choices.synthesisControls(voice: artifactOnly, delivery: .playback))
        XCTAssertEqual(choices.synthesisControls(voice: artifactOnly, delivery: .artifact)?.speakingRate?.value, 1.0)
        XCTAssertNil(choices.synthesisControls(voice: nil, delivery: .artifact))
    }

    func testSliderUsesTheVoicesRange() {
        let slider = Optional(voice).controlSlider(.speechSpeakingRate, delivery: .playback)
        XCTAssertTrue(slider.usable)
        XCTAssertEqual(slider.min, 0.5)
        XCTAssertEqual(slider.max, 2)
        XCTAssertEqual(slider.initial, 1)
    }

    func testUnknownUnavailableAndMissingStatesAreDisabledWithAReason() {
        let selected = Optional(voice)
        XCTAssertEqual(selected.controlSlider(.speechPitch, delivery: .playback).reason, "unknown")
        XCTAssertFalse(selected.controlSlider(.speechPitch, delivery: .artifact).usable)
        XCTAssertEqual(selected.controlSlider(.speechPitch, delivery: .artifact).reason, "no pitch")
        XCTAssertEqual(selected.controlSlider(.playbackVolume, delivery: .playback).reason, "not offered")
        let none: SpeechVoiceInfo? = nil
        XCTAssertEqual(none.controlSlider(.speechPitch, delivery: .playback).reason, "pick a voice")
    }

    func testChoicesBuildOnlyWhatIsTurnedOn() {
        XCTAssertNil(SpeechControlChoices(requireRate: true).synthesisControls(voice: voice, delivery: .playback))
        XCTAssertNil(SpeechControlChoices().playbackControls(voice: voice))
        let full = Self.decode("""
        [{"id": "speech.speakingRate", "delivery": "playback", "phase": "synthesis", "available": true,
          "range": {"min": 0.5, "max": 2}},
         {"id": "speech.pitch", "delivery": "playback", "phase": "synthesis", "available": true,
          "range": {"min": 0.5, "max": 2}},
         {"id": "playback.volume", "delivery": "playback", "phase": "playback", "available": true,
          "range": {"min": 0, "max": 1}}]
        """)
        let choices = SpeechControlChoices(rate: 1.5, pitch: 0.8, volume: 0.4, requireRate: true)
        let synthesis = choices.synthesisControls(voice: full, delivery: .playback)
        XCTAssertEqual(synthesis?.speakingRate?.requirement, .requirementLevelRequired)
        XCTAssertEqual(synthesis?.speakingRate?.value, 1.5)
        XCTAssertNil(synthesis?.pitch?.requirement)
        XCTAssertEqual(choices.playbackControls(voice: full)?.volume?.value, 0.4)
        XCTAssertEqual(choices.forNewVoice(), SpeechControlChoices(requireRate: true))
    }

    func testOutcomesShowAppliedAndNotAppliedWithReason() {
        XCTAssertNil(describeSpeechControls(nil))
        let text = describeSpeechControls([
            SpeechControlOutcome(
                effective: 1.5, id: .speechSpeakingRate, method: .platformSynthesis, reason: nil,
                requested: 1.5, status: .applied
            ),
            SpeechControlOutcome(
                effective: nil, id: .playbackVolume, method: nil, reason: .notReported,
                requested: 0.4, status: .notApplied
            ),
        ])
        XCTAssertEqual(
            text,
            "speech.speakingRate applied 1.5 (platform_synthesis); playback.volume not applied: not_reported"
        )
    }
}
