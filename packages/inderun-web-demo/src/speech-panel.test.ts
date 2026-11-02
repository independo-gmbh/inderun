// @vitest-environment happy-dom
import type { IndeRunApi, ProviderCapabilitySnapshot, StreamRun } from "@independo/inderun-web";
import { describe, expect, it, vi } from "vitest";
import { mountSpeechPanel } from "./speech-panel";

async function flush(): Promise<void> {
  for (let i = 0; i < 10; i += 1) {
    await Promise.resolve();
  }
}

const snapshots = [
  {
    providerId: "web_system_speech",
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

function setup(stream: IndeRunApi["stream"]) {
  const root = document.createElement("div");
  const api = {
    stream,
    checkCapabilities: async () => snapshots,
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
    locale: query<HTMLSelectElement>("speech-locale")
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
});
