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
          playback: { firstAudioMs: 142.4 },
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
});
