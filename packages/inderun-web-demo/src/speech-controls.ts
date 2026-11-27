import type {
  SpeechControls,
  SpeechPlaybackControls,
  SpeechVoiceInfo,
  SpokenSpeech
} from "@independo/inderun-web";

type SpeechVoiceControl = NonNullable<SpeechVoiceInfo["controls"]>[number];
type SpeechControlOutcome = NonNullable<NonNullable<SpokenSpeech["speech"]>["controls"]>[number];

export type ControlId = "speech.speakingRate" | "speech.pitch" | "playback.volume";
export type ControlDelivery = "playback" | "artifact";

export const CONTROL_IDS: { id: ControlId; label: string }[] = [
  { id: "speech.speakingRate", label: "Rate" },
  { id: "speech.pitch", label: "Pitch" },
  { id: "playback.volume", label: "Volume" }
];

/** What the slider of one control can do for the picked voice and a delivery. */
export interface ControlState {
  usable: boolean;
  min: number;
  max: number;
  step: number;
  value: number;
  /** Why it is disabled; "unknown" when the provider has not said. */
  reason?: string;
}

/**
 * The state of one control as the picked voice offers it on one delivery. A missing voice, a
 * missing entry, an unavailable control and an unknown range all read as disabled, never as usable.
 */
export function controlState(
  voice: SpeechVoiceInfo | undefined,
  id: ControlId,
  delivery: ControlDelivery
): ControlState {
  const off = (reason: string): ControlState => ({
    usable: false,
    min: 0,
    max: 1,
    step: 0.1,
    value: 1,
    reason
  });
  if (voice === undefined) return off("pick a voice");
  const entry: SpeechVoiceControl | undefined = voice.controls?.find(
    (control) => control.id === id && control.delivery === delivery
  );
  if (entry === undefined) return off("not offered");
  if (entry.available === false) return off(entry.reason ?? "unavailable");
  if (entry.available !== true) return off(entry.reason ?? "unknown");
  const range = entry.range;
  if (range === undefined) return off("unknown range");
  return {
    usable: true,
    min: range.min,
    max: range.max,
    step: range.step ?? (range.max - range.min) / 20,
    value: range.default ?? Math.min(Math.max(1, range.min), range.max)
  };
}

/** The values the person turned on; an absent entry sends nothing. */
export interface ChosenControls {
  rate?: number;
  pitch?: number;
  volume?: number;
  requireRate: boolean;
}

/**
 * Whether a value may be sent on one delivery: that delivery's state is usable and the value lies
 * inside its range. Never clamps; a value outside is simply not sent.
 */
export function sendable(
  voice: SpeechVoiceInfo | undefined,
  id: ControlId,
  delivery: ControlDelivery,
  value: number | undefined
): value is number {
  if (value === undefined) return false;
  const state = controlState(voice, id, delivery);
  return state.usable && value >= state.min && value <= state.max;
}

/** The row's per-delivery text: available, outside the range, or why not. */
export function deliveryNote(
  voice: SpeechVoiceInfo | undefined,
  id: ControlId,
  delivery: ControlDelivery,
  value: number | undefined
): string {
  const state = controlState(voice, id, delivery);
  if (!state.usable) return state.reason ?? "unknown";
  if (value !== undefined && !sendable(voice, id, delivery, value)) {
    return `outside ${state.min}\u2013${state.max}`;
  }
  return "available";
}

/** Synthesis controls for one action: rate and pitch, each only if that delivery accepts it. */
export function synthesisControls(
  chosen: ChosenControls,
  voice: SpeechVoiceInfo | undefined,
  delivery: ControlDelivery
): SpeechControls | undefined {
  const controls: SpeechControls = {};
  if (sendable(voice, "speech.speakingRate", delivery, chosen.rate)) {
    controls.speakingRate = {
      value: chosen.rate!,
      ...(chosen.requireRate ? { requirement: "required" as const } : {})
    };
  }
  if (sendable(voice, "speech.pitch", delivery, chosen.pitch)) {
    controls.pitch = { value: chosen.pitch! };
  }
  return Object.keys(controls).length > 0 ? controls : undefined;
}

/** Playback controls for speak() only, when the playback state accepts the volume. */
export function playbackControls(
  chosen: ChosenControls,
  voice: SpeechVoiceInfo | undefined
): SpeechPlaybackControls | undefined {
  return sendable(voice, "playback.volume", "playback", chosen.volume)
    ? { volume: { value: chosen.volume! } }
    : undefined;
}

/** One line per reported control: applied, or not applied with its reason. */
export function describeControls(records: SpeechControlOutcome[] | undefined): string | undefined {
  if (records === undefined || records.length === 0) return undefined;
  return records
    .map((record) =>
      record.status === "applied"
        ? `${record.id} applied ${record.effective ?? record.requested}${
            record.method !== undefined ? ` (${record.method})` : ""
          }`
        : `${record.id} not applied: ${record.reason ?? "unknown"}`
    )
    .join("; ");
}
