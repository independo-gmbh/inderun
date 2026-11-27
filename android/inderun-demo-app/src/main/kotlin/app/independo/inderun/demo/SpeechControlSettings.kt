package app.independo.inderun.demo

import app.independo.inderun.contracts.ControlDelivery
import app.independo.inderun.contracts.PlaybackControls
import app.independo.inderun.contracts.RequestedNumber
import app.independo.inderun.contracts.RequestedUnitNumber
import app.independo.inderun.contracts.RequirementLevel
import app.independo.inderun.contracts.SharedSynthesisControls
import app.independo.inderun.contracts.SpeechControlId
import app.independo.inderun.contracts.SpeechControlOutcome
import app.independo.inderun.contracts.SpeechControlStatus
import app.independo.inderun.sdk.SpeechVoiceInfo

/** The values the person turned on. A null value sends nothing. Kept in view-model state only. */
internal data class SpeechControlChoices(
    val rate: Double? = null,
    val pitch: Double? = null,
    val volume: Double? = null,
    val requireRate: Boolean = false,
) {
    /**
     * Rate and pitch for one action, each only if that delivery's state accepts the value
     * (usable, and inside its range). Never clamped. Null when neither is sent.
     */
    fun synthesisControls(voice: SpeechVoiceInfo?, delivery: ControlDelivery): SharedSynthesisControls? {
        val sendRate = voice.accepts(SpeechControlId.SpeechSpeakingRate, delivery, rate)
        val sendPitch = voice.accepts(SpeechControlId.SpeechPitch, delivery, pitch)
        if (!sendRate && !sendPitch) return null
        return SharedSynthesisControls(
            pitch = if (sendPitch) RequestedNumber(value = pitch!!) else null,
            speakingRate = if (sendRate) {
                RequestedNumber(requirement = if (requireRate) RequirementLevel.Required else null, value = rate!!)
            } else {
                null
            },
        )
    }

    /** Ranges belong to a voice, so a new voice starts with every control off; "require rate" stays. */
    fun forNewVoice(): SpeechControlChoices = SpeechControlChoices(requireRate = requireRate)

    /** Volume, for `speak` only, when the playback state accepts it. */
    fun playbackControls(voice: SpeechVoiceInfo?): PlaybackControls? = if (voice.accepts(SpeechControlId.PlaybackVolume, ControlDelivery.Playback, volume)) {
        PlaybackControls(volume = RequestedUnitNumber(value = volume!!))
    } else {
        null
    }
}

/** What a slider can do for the selected voice and one delivery. */
internal data class SpeechControlSlider(
    val usable: Boolean,
    val min: Double = 0.0,
    val max: Double = 1.0,
    val initial: Double = 1.0,
    val reason: String? = null,
)

/**
 * The state of one control as the voice offers it on one delivery. No voice, no entry, an
 * unavailable control and an unknown range all read as disabled, never as usable.
 */
internal fun SpeechVoiceInfo?.controlSlider(id: SpeechControlId, delivery: ControlDelivery): SpeechControlSlider {
    if (this == null) return SpeechControlSlider(usable = false, reason = "pick a voice")
    val entry = controls?.firstOrNull { it.id == id && it.delivery == delivery }
        ?: return SpeechControlSlider(usable = false, reason = "not offered")
    if (entry.available == false) return SpeechControlSlider(usable = false, reason = entry.reason ?: "unavailable")
    if (entry.available != true) return SpeechControlSlider(usable = false, reason = entry.reason ?: "unknown")
    val range = entry.range ?: return SpeechControlSlider(usable = false, reason = "unknown range")
    return SpeechControlSlider(
        usable = true,
        min = range.min,
        max = range.max,
        initial = range.default ?: 1.0.coerceIn(range.min, range.max),
    )
}

/** One entry per reported control: applied, or not applied with its reason. Null when none. */
internal fun List<SpeechControlOutcome>?.describeControls(): String? {
    if (isNullOrEmpty()) return null
    return joinToString("; ") { record ->
        if (record.status == SpeechControlStatus.Applied) {
            "${record.id.rawValue} applied ${record.effective ?: record.requested}" +
                (record.method?.let { " (${it.rawValue})" } ?: "")
        } else {
            "${record.id.rawValue} not applied: ${record.reason?.rawValue ?: "unknown"}"
        }
    }
}

/** A value is sent on a delivery only if its state is usable and the value is inside its range. */
internal fun SpeechVoiceInfo?.accepts(id: SpeechControlId, delivery: ControlDelivery, value: Double?): Boolean {
    if (value == null) return false
    val slider = controlSlider(id, delivery)
    return slider.usable && value >= slider.min && value <= slider.max
}

/** The row's per-delivery text: available, outside the range, or why not. */
internal fun SpeechVoiceInfo?.deliveryNote(id: SpeechControlId, delivery: ControlDelivery, value: Double?): String {
    val slider = controlSlider(id, delivery)
    if (!slider.usable) return slider.reason ?: "unknown"
    if (value != null && !accepts(id, delivery, value)) return "outside ${slider.min}\u2013${slider.max}"
    return "available"
}
