// @vitest-environment happy-dom
import type { IndeRunApi, ProviderCapabilitySnapshot, StreamRun } from "@independo/inderun-web";
import { describe, expect, it, vi } from "vitest";
import { mountSpeechPanel } from "./speech-panel";

async function flush(): Promise<void> {
  for (let i = 0; i < 10; i += 1) {
    await Promise.resolve();
  }
}

function speechDescriptor(id: string, deliveries: string[]) {
  return {
    id,
    taskCapabilities: [
      { kind: "text_to_speech", outputs: deliveries.map((delivery) => ({ delivery })) }
    ]
  };
}

const snapshots = [
  {
    providerId: "web_system_speech",
    descriptor: speechDescriptor("web_system_speech", ["playback"]),
    capabilities: {
      available: true,
      taskCapabilities: [
        {
          kind: "text_to_speech",
          voices: [
            { id: "anna", name: "Anna", locale: "de-DE" },
            { id: "anna-2", name: "Anna", locale: "de-DE" },
            { id: "sam", name: "Samantha", locale: "en-US" }
          ]
        }
      ]
    }
  }
] as unknown as ProviderCapabilitySnapshot[];

function terminal(outcome: Record<string, unknown>): StreamRun {
  return {
    handle: { runId: "r" },
    events: (async function* () {
      yield { type: "terminal", runId: "r", payload: { runId: "r", ...outcome } };
    })(),
    cancel: vi.fn()
  } as unknown as StreamRun;
}

function setup(stream: IndeRunApi["stream"], extra: Partial<IndeRunApi> = {}) {
  const root = document.createElement("div");
  const api = {
    stream,
    checkCapabilities: async () => snapshots,
    ...extra,
    prepare: async () =>
      terminal({ outcome: "completed", output: { type: "prepared", preparation: [] } })
  } as unknown as IndeRunApi;
  mountSpeechPanel(root, api);
  const query = <T extends HTMLElement>(id: string) => root.querySelector<T>(`#${id}`)!;
  return {
    speak: query<HTMLButtonElement>("speech-speak"),
    stop: query<HTMLButtonElement>("speech-stop"),
    status: query("speech-status"),
    voices: query("speech-voices"),
    voice: query<HTMLSelectElement>("speech-voice"),
    locale: query<HTMLSelectElement>("speech-locale"),
    generate: query<HTMLButtonElement>("speech-generate"),
    delivery: query("speech-delivery"),
    audio: query<HTMLAudioElement>("speech-audio")
  };
}

type SentRequest = { delivery: unknown; speech: { controls?: unknown } };

describe("speech panel", () => {
  it("shows the voices for the selected language", async () => {
    const panel = setup(vi.fn());
    await flush();

    expect(panel.voices.textContent).toContain("2 voice(s) available for de-DE");
  });

  it("offers every voice, numbering repeated names", async () => {
    const panel = setup(vi.fn());
    await flush();

    expect([...panel.voice.options].map((option) => option.textContent)).toEqual([
      "Automatic",
      "Anna (de-DE)",
      "Anna (de-DE) 2"
    ]);
  });

  it("speaks the picked voice and names it in the status", async () => {
    const stream = vi.fn(async () =>
      terminal({
        outcome: "completed",
        finishReason: "stop",
        output: {
          type: "playback",
          speech: { locale: "de-DE", voice: { id: "anna-2", name: "Anna" } }
        },
        provenance: { providerId: "web_system_speech", locality: "unknown" }
      })
    );
    const panel = setup(stream);
    await flush();

    panel.voice.value = "1";
    panel.speak.click();
    await flush();

    expect(stream).toHaveBeenCalledWith(
      expect.objectContaining({
        speech: expect.objectContaining({
          voice: { id: "anna-2", providerId: "web_system_speech" }
        })
      })
    );
    expect(panel.status.textContent).toBe("stop · de-DE · Anna · web_system_speech · unknown");
  });

  it("speaks through the facade and reports the provenance", async () => {
    const stream = vi.fn(async () =>
      terminal({
        outcome: "completed",
        finishReason: "stop",
        output: { type: "playback", speech: { locale: "de-DE" } },
        provenance: { providerId: "web_system_speech", locality: "unknown" }
      })
    );
    const panel = setup(stream);

    panel.speak.click();
    await flush();

    expect(stream).toHaveBeenCalledWith(
      expect.objectContaining({
        task: { kind: "text_to_speech" },
        delivery: { mode: "playback" }
      })
    );
    expect(panel.status.textContent).toBe("stop · de-DE · web_system_speech · unknown");
    expect(panel.speak.disabled).toBe(false);
    expect(panel.stop.disabled).toBe(true);
  });

  it("stops playback with the Stop button", async () => {
    let finish!: () => void;
    const gate = new Promise<void>((resolve) => {
      finish = resolve;
    });
    const cancel = vi.fn(() => finish());
    const run = {
      handle: { runId: "r" },
      events: (async function* () {
        await gate;
        yield {
          type: "terminal",
          runId: "r",
          payload: { outcome: "cancelled", runId: "r" }
        };
      })(),
      cancel
    } as unknown as StreamRun;
    const panel = setup(async () => run);

    panel.speak.click();
    await flush();
    expect(panel.stop.disabled).toBe(false);
    panel.stop.click();
    await flush();

    expect(cancel).toHaveBeenCalled();
    expect(panel.status.textContent).toContain("cancelled");
  });

  it("offers Stop only once there is a playback to stop", async () => {
    let route!: (run: StreamRun) => void;
    const panel = setup(() => new Promise<StreamRun>((resolve) => (route = resolve)));

    panel.speak.click();
    await flush();
    expect(panel.stop.disabled).toBe(true);

    route(
      terminal({
        outcome: "completed",
        finishReason: "stop",
        output: { type: "playback", speech: { locale: "de-DE" } },
        provenance: { providerId: "web_system_speech", locality: "unknown" }
      })
    );
    await flush();

    expect(panel.status.textContent).toContain("stop");
  });

  it("reports a refusal without throwing", async () => {
    const { IndeRunException } = await import("@independo/inderun-web");
    const panel = setup(async () => {
      throw new IndeRunException({ errorClass: "CapabilityMismatch", message: "no voice" });
    });

    panel.speak.click();
    await flush();

    expect(panel.status.textContent).toBe("failed: CapabilityMismatch: no voice");
  });

  it("offers no Generate when the live check takes speech away from an artifact provider", async () => {
    const panel = setup(vi.fn(), {
      checkCapabilities: async () => [
        ...snapshots,
        {
          providerId: "native_speech",
          descriptor: speechDescriptor("native_speech", ["playback", "artifact"]),
          capabilities: {
            available: true,
            taskCapabilities: [
              { kind: "text_to_speech", available: false, reason: "No voice is installed." }
            ]
          }
        }
      ]
    } as unknown as Partial<IndeRunApi>);
    await flush();
    expect(panel.generate.disabled).toBe(true);
    expect(panel.delivery.textContent).toBe(
      "Plays speech: web_system_speech. Returns audio: no provider here; speech is playback-only on this platform."
    );
  });

  it("says playback-only from capabilities and offers no Generate", async () => {
    const panel = setup(vi.fn());
    await flush();

    expect(panel.generate.disabled).toBe(true);
    expect(panel.delivery.textContent).toBe(
      "Plays speech: web_system_speech. Returns audio: no provider here; speech is playback-only on this platform."
    );
  });

  it("shows the first word time a provider reports", async () => {
    const stream = vi.fn(async () =>
      terminal({
        outcome: "completed",
        finishReason: "stop",
        output: {
          type: "playback",
          playback: { timing: { firstAudioMs: 142.4 } },
          speech: { locale: "de-DE" }
        },
        provenance: { providerId: "web_system_speech", locality: "unknown" }
      })
    );
    const panel = setup(stream);

    panel.speak.click();
    await flush();

    expect(panel.status.textContent).toBe(
      "stop · de-DE · web_system_speech · unknown · first word 142 ms"
    );
  });

  it("generates audio where a provider returns it, then reads and releases it", async () => {
    const artifact = { id: "a1", mediaType: "audio/wav", owner: "engine", durationMs: 1200 };
    const bytes = new Uint8Array([82, 73, 70, 70, 1, 2]);
    const run = vi.fn(async () => ({
      runId: "r",
      finishReason: "stop",
      output: { type: "artifact", artifact },
      provenance: { providerId: "native_speech", locality: "on_device" }
    }));
    const readArtifact = vi.fn(async ({ offset = 0 }: { offset?: number }) => ({
      artifactId: "a1",
      offset,
      bytes: bytes.subarray(offset, offset + 4),
      totalBytes: bytes.length,
      done: offset + 4 >= bytes.length
    }));
    const disposeArtifact = vi.fn(async () => {});
    URL.createObjectURL = vi.fn(() => "blob:speech");
    URL.revokeObjectURL = vi.fn();
    const panel = setup(vi.fn(), {
      run,
      readArtifact,
      disposeArtifact,
      checkCapabilities: async () => [
        ...snapshots,
        {
          providerId: "native_speech",
          descriptor: speechDescriptor("native_speech", ["playback", "artifact"]),
          capabilities: { available: true }
        }
      ]
    } as unknown as Partial<IndeRunApi>);
    await flush();
    expect(panel.generate.disabled).toBe(false);
    expect(panel.delivery.textContent).toContain("Returns audio: native_speech.");

    panel.generate.click();
    await flush();

    expect(run).toHaveBeenCalledWith(expect.objectContaining({ delivery: { mode: "artifact" } }));
    expect(readArtifact).toHaveBeenCalledTimes(2);
    expect(disposeArtifact).toHaveBeenCalledWith(artifact);
    expect(panel.audio.hidden).toBe(false);
    expect(panel.audio.getAttribute("src")).toBe("blob:speech");
    expect(panel.status.textContent).toBe(
      "audio/wav · 6 bytes · 1200 ms of audio · native_speech · on_device"
    );
  });

  describe("speech controls", () => {
    const state = (id: string, delivery: string, extra: Record<string, unknown>) => ({
      id,
      delivery,
      ...extra
    });
    const withControls = [
      {
        providerId: "web_system_speech",
        descriptor: {
          id: "web_system_speech",
          taskCapabilities: [
            {
              kind: "text_to_speech",
              outputs: [{ delivery: "playback" }],
              controls: [
                {
                  id: "speech.speakingRate",
                  valueKind: "number",
                  phase: "synthesis",
                  lifetime: "utterance",
                  deliveries: ["playback"]
                },
                {
                  id: "playback.volume",
                  valueKind: "number",
                  phase: "playback",
                  lifetime: "utterance",
                  deliveries: ["playback"]
                }
              ]
            }
          ]
        },
        capabilities: {
          available: true,
          taskCapabilities: [
            {
              kind: "text_to_speech",
              controlStates: [
                state("speech.speakingRate", "playback", {
                  available: true,
                  range: { min: 0.5, max: 2, default: 1, step: 0.1 }
                }),
                state("playback.volume", "playback", { available: false, reason: "no gain" })
              ],
              voices: [{ id: "anna", name: "Anna", locale: "de-DE" }]
            }
          ]
        }
      }
    ] as unknown as ProviderCapabilitySnapshot[];

    const mount = (stream: IndeRunApi["stream"]) => {
      const panel = setup(stream, { checkCapabilities: async () => withControls });
      const root = panel.speak.closest("section")!;
      return {
        ...panel,
        box: (id: string) =>
          root.querySelector<HTMLInputElement>(`input[type=checkbox][data-id="${id}"]`)!,
        slider: (id: string) =>
          root.querySelector<HTMLInputElement>(`input[type=range][data-id="${id}"]`)!,
        requireRate: root.querySelector<HTMLInputElement>("#speech-require-rate")!,
        rows: root.querySelector("#speech-control-rows")!
      };
    };

    it("sends no controls until one is turned on", async () => {
      const stream = vi.fn(async () =>
        terminal({ outcome: "completed", output: { type: "playback" } })
      );
      const panel = mount(stream);
      await flush();
      panel.voice.value = "0";
      panel.voice.dispatchEvent(new Event("change"));

      panel.speak.click();
      await flush();

      const [request] = stream.mock.calls[0] as unknown as [SentRequest];
      expect(request.delivery).toEqual({ mode: "playback" });
      expect(request.speech.controls).toBeUndefined();
    });

    it("builds the slider from the voice's range and disables an unavailable control", async () => {
      const panel = mount(vi.fn());
      await flush();
      panel.voice.value = "0";
      panel.voice.dispatchEvent(new Event("change"));

      expect(panel.slider("speech.speakingRate").min).toBe("0.5");
      expect(panel.slider("speech.speakingRate").max).toBe("2");
      expect(panel.box("speech.speakingRate").disabled).toBe(false);
      expect(panel.box("speech.pitch").disabled).toBe(true);
      expect(panel.box("playback.volume").disabled).toBe(true);
      expect(panel.rows.textContent).toContain("no gain");
      expect(panel.rows.textContent).toContain("not offered");
    });

    it("sends the chosen rate as required and shows what was applied", async () => {
      const stream = vi.fn(async () =>
        terminal({
          outcome: "completed",
          finishReason: "stop",
          output: {
            type: "playback",
            speech: {
              locale: "de-DE",
              controls: [
                {
                  id: "speech.speakingRate",
                  requested: 1.5,
                  effective: 1.5,
                  status: "applied",
                  method: "platform_synthesis"
                },
                { id: "speech.pitch", requested: 1.2, status: "not_applied", reason: "unsupported" }
              ]
            }
          }
        })
      );
      const panel = mount(stream);
      await flush();
      panel.voice.value = "0";
      panel.voice.dispatchEvent(new Event("change"));
      panel.box("speech.speakingRate").checked = true;
      panel.box("speech.speakingRate").dispatchEvent(new Event("change"));
      panel.slider("speech.speakingRate").value = "1.5";
      panel.requireRate.checked = true;

      panel.speak.click();
      await flush();

      const [request] = stream.mock.calls[0] as unknown as [SentRequest];
      expect(request.speech.controls).toEqual({
        speakingRate: { value: 1.5, requirement: "required" }
      });
      expect(panel.status.textContent).toContain(
        "speech.speakingRate applied 1.5 (platform_synthesis); speech.pitch not applied: unsupported"
      );
    });
  });
});
