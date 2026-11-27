import Foundation
import IndeRunContracts
import IndeRunSwift

/// The values the person turned on in the Speech controls section. Nil sends nothing. Held in
/// view-model state only: the demo does not persist speech settings.
struct SpeechControlChoices: Equatable {
    var rate: Double?
    var pitch: Double?
    var volume: Double?
    var requireRate = false

    /// Rate and pitch for one action, each only if that delivery's state accepts the value
    /// (usable, and inside its range). Never clamped. Nil when neither is sent.
    func synthesisControls(voice: SpeechVoiceInfo?, delivery: ControlDelivery) -> SharedSynthesisControls? {
        let sendRate = voice.accepts(.speechSpeakingRate, delivery: delivery, value: rate)
        let sendPitch = voice.accepts(.speechPitch, delivery: delivery, value: pitch)
        guard sendRate || sendPitch else { return nil }
        return SharedSynthesisControls(
            pitch: sendPitch ? pitch.map { RequestedNumber(requirement: nil, value: $0) } : nil,
            speakingRate: sendRate
                ? rate.map { RequestedNumber(requirement: requireRate ? .requirementLevelRequired : nil, value: $0) }
                : nil
        )
    }

    /// Volume, for `speak` only, when the playback state accepts it.
    func playbackControls(voice: SpeechVoiceInfo?) -> PlaybackControls? {
        guard voice.accepts(.playbackVolume, delivery: .playback, value: volume), let volume else { return nil }
        return PlaybackControls(volume: RequestedUnitNumber(requirement: nil, value: volume))
    }

    /// Ranges belong to a voice, so a new voice starts with every control off; "require rate" stays.
    func forNewVoice() -> SpeechControlChoices {
        SpeechControlChoices(requireRate: requireRate)
    }
}

/// What a slider can do for the selected voice and one delivery.
struct SpeechControlSlider: Equatable {
    var usable: Bool
    var min = 0.0
    var max = 1.0
    var initial = 1.0
    /// Why it is disabled; "unknown" when the provider has not said.
    var reason: String?
}

extension Optional where Wrapped == SpeechVoiceInfo {
    /// No voice, no entry, an unavailable control and an unknown range all read as disabled,
    /// never as usable.
    func controlSlider(_ id: SpeechControlId, delivery: ControlDelivery) -> SpeechControlSlider {
        guard let voice = self else { return SpeechControlSlider(usable: false, reason: "pick a voice") }
        guard let entry = voice.controls?.first(where: { $0.id == id && $0.delivery == delivery }) else {
            return SpeechControlSlider(usable: false, reason: "not offered")
        }
        if entry.available == false {
            return SpeechControlSlider(usable: false, reason: entry.reason ?? "unavailable")
        }
        if entry.available != true {
            return SpeechControlSlider(usable: false, reason: entry.reason ?? "unknown")
        }
        guard let range = entry.range else { return SpeechControlSlider(usable: false, reason: "unknown range") }
        return SpeechControlSlider(
            usable: true,
            min: range.min,
            max: range.max,
            initial: range.speechControlRangeDefault ?? Swift.min(Swift.max(1.0, range.min), range.max)
        )
    }
}

extension Optional where Wrapped == SpeechVoiceInfo {
    /// A value is sent on a delivery only if its state is usable and the value is inside its range.
    func accepts(_ id: SpeechControlId, delivery: ControlDelivery, value: Double?) -> Bool {
        guard let value else { return false }
        let slider = controlSlider(id, delivery: delivery)
        return slider.usable && value >= slider.min && value <= slider.max
    }

    /// The row's per-delivery text: available, outside the range, or why not.
    func deliveryNote(_ id: SpeechControlId, delivery: ControlDelivery, value: Double?) -> String {
        let slider = controlSlider(id, delivery: delivery)
        if !slider.usable { return slider.reason ?? "unknown" }
        if let value, !accepts(id, delivery: delivery, value: value) {
            return "outside \(slider.min)\u{2013}\(slider.max)"
        }
        return "available"
    }
}

/// One entry per reported control: applied, or not applied with its reason. Nil when none.
func describeSpeechControls(_ records: [SpeechControlOutcome]?) -> String? {
    guard let records, !records.isEmpty else { return nil }
    return records.map { record in
        if record.status == .applied {
            let method = record.method.map { " (\($0.rawValue))" } ?? ""
            return "\(record.id.rawValue) applied \(record.effective ?? record.requested)\(method)"
        }
        return "\(record.id.rawValue) not applied: \(record.reason?.rawValue ?? "unknown")"
    }.joined(separator: "; ")
}
