import { describe, expect, it } from "vitest";
import {
  controlState,
  deliveryNote,
  describeControls,
  playbackControls,
  synthesisControls
} from "./speech-controls";

describe("speech controls", () => {
  const voice = {
    controls: [
      {
        id: "speech.speakingRate",
        delivery: "playback",
        available: true,
        range: { min: 0.5, max: 2 }
      },
      { id: "speech.pitch", delivery: "playback" },
      { id: "speech.pitch", delivery: "artifact", available: false, reason: "unsupported" }
    ]
  } as never;

  it("reads range, unknown and unavailable states", () => {
    expect(controlState(voice, "speech.speakingRate", "playback")).toMatchObject({
      usable: true,
      min: 0.5,
      max: 2,
      value: 1
    });
    expect(controlState(voice, "speech.pitch", "playback")).toMatchObject({
      usable: false,
      reason: "unknown"
    });
    expect(controlState(voice, "speech.pitch", "artifact").reason).toBe("unsupported");
    expect(controlState(undefined, "speech.pitch", "playback").reason).toBe("pick a voice");
  });

  const both = {
    controls: [
      {
        id: "speech.speakingRate",
        delivery: "playback",
        available: true,
        range: { min: 0.5, max: 2 }
      },
      {
        id: "speech.speakingRate",
        delivery: "artifact",
        available: true,
        range: { min: 0.8, max: 1.2 }
      },
      { id: "speech.pitch", delivery: "playback", available: true, range: { min: 0.5, max: 2 } },
      { id: "speech.pitch", delivery: "artifact", available: false, reason: "unsupported" },
      { id: "playback.volume", delivery: "playback", available: true, range: { min: 0, max: 1 } }
    ]
  } as never;
  const artifactOnly = {
    controls: [
      { id: "speech.speakingRate", delivery: "playback", available: false, reason: "no rate" },
      {
        id: "speech.speakingRate",
        delivery: "artifact",
        available: true,
        range: { min: 0.5, max: 2 }
      }
    ]
  } as never;

  it("builds options per delivery, sending required only for the rate", () => {
    const chosen = { rate: 1.5, pitch: 0.8, volume: 0.4, requireRate: true };
    expect(synthesisControls({ requireRate: true }, both, "playback")).toBeUndefined();
    expect(synthesisControls(chosen, both, "playback")).toEqual({
      speakingRate: { value: 1.5, requirement: "required" },
      pitch: { value: 0.8 }
    });
    expect(playbackControls(chosen, both)).toEqual({ volume: { value: 0.4 } });
  });

  it("does not send to Generate what the artifact delivery rejects", () => {
    // Rate 1.5 is outside the artifact range 0.8-1.2; pitch is unavailable on artifact.
    const chosen = { rate: 1.5, pitch: 0.8, requireRate: false };
    expect(synthesisControls(chosen, both, "artifact")).toBeUndefined();
    expect(synthesisControls({ rate: 1, requireRate: false }, both, "artifact")).toEqual({
      speakingRate: { value: 1 }
    });
    expect(deliveryNote(both, "speech.speakingRate", "artifact", 1.5)).toBe("outside 0.8\u20131.2");
    expect(deliveryNote(both, "speech.pitch", "artifact", 0.8)).toBe("unsupported");
  });

  it("sends an artifact-only control to Generate and not to Speak", () => {
    const chosen = { rate: 1, requireRate: false };
    expect(synthesisControls(chosen, artifactOnly, "playback")).toBeUndefined();
    expect(synthesisControls(chosen, artifactOnly, "artifact")).toEqual({
      speakingRate: { value: 1 }
    });
    expect(synthesisControls(chosen, undefined, "artifact")).toBeUndefined();
  });

  it("describes outcomes", () => {
    expect(describeControls(undefined)).toBeUndefined();
    expect(
      describeControls([
        { id: "playback.volume", requested: 0.4, status: "not_applied", reason: "not_reported" }
      ])
    ).toBe("playback.volume not applied: not_reported");
  });
});
