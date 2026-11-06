// @vitest-environment happy-dom
import type { IndeRunApi } from "@independo/inderun-web";
import { describe, expect, it, vi } from "vitest";
import { catalog, loadFixture } from "./fixtures.test-support";
import { entryTotalBytes, type CatalogEntry } from "./neural-catalog";
import { mountVoicesLabPanel, type VoicesLabOptions } from "./voices-lab-panel";

const NEURAL_ID = "local.onnx.speech.web:articulino-de-en-int8";
const PROFILE = "voices-lab:articulino-de-en-int8";

async function flush(): Promise<void> {
  for (let i = 0; i < 30; i += 1) await Promise.resolve();
}

const corpus = loadFixture<VoicesLabOptions["corpus"]>("utterance-corpus.json");
const onnxEntry = () => catalog().entries.find((e) => e.id === "articulino-de-en-int8")!;

function storeOf(entry: CatalogEntry, installed: boolean) {
  const sizes = new Map(
    [...(entry.files ?? []), ...(entry.voices ?? []).map((v) => v.file)].map((f) => [
      f.path,
      f.bytes
    ])
  );
  return {
    ref: `voices-lab/${entry.id}/${entry.version}`,
    files: { read: async () => new Uint8Array() },
    storage: {
      size: async (path: string) => (installed ? sizes.get(path) : undefined),
      read: async function* () {},
      write: vi.fn(async () => ({
        write: async () => {},
        close: async () => {},
        abort: async () => {}
      })),
      remove: async () => {}
    }
  };
}

const LAB = { tag: "lab" } as unknown as IndeRunApi;
const BASE = { tag: "base" } as unknown as IndeRunApi;

function setup(over: Partial<VoicesLabOptions> & { installed?: boolean } = {}) {
  const root = document.createElement("div");
  const { installed = true, ...rest } = over;
  const speak = vi.fn(async (_engine: IndeRunApi, options: Record<string, unknown>) => ({
    runId: "r",
    cancel: vi.fn(),
    result: Promise.resolve({
      finishReason: "stop",
      speech: { locale: options["locale"], voice: { name: "Voice" } },
      provenance: {
        providerId: options["model"] === undefined ? "web_system_speech" : NEURAL_ID,
        locality: "local"
      },
      runId: "r"
    })
  }));
  const listVoices = vi.fn(async (engine: IndeRunApi) =>
    engine === LAB
      ? [
          {
            providerId: NEURAL_ID,
            kind: "model",
            model: "articulino-de-en-int8",
            id: "de-at-m-1",
            name: "Austrian German man 1",
            locale: "de-AT"
          },
          {
            providerId: NEURAL_ID,
            kind: "model",
            model: "articulino-de-en-int8",
            id: "en-us-f-1",
            name: "US English woman 1",
            locale: "en-US"
          }
        ]
      : [
          {
            providerId: "web_system_speech",
            kind: "platform",
            id: "anna",
            name: "Anna",
            locale: "de-DE"
          }
        ]
  );
  const prepare = vi.fn(async () => ({
    runId: "p",
    cancel: vi.fn(),
    result: Promise.resolve({ finishReason: "stop", items: [] })
  }));
  const fetchImpl = vi.fn();
  const createEngine = vi.fn((_installed: unknown[]) => LAB);
  const openEntryStore = vi.fn(async (entry: CatalogEntry, _mode: { create: boolean }) =>
    installed || _mode.create ? storeOf(entry, installed) : undefined
  );
  const options = {
    enabled: true,
    catalog: catalog(),
    corpus,
    assetsUrl: "https://proxy.test/assets",
    fetch: fetchImpl as unknown as typeof fetch,
    openEntryStore,
    createEngine,
    api: { speak, listVoices, prepare },
    ...rest
  } as unknown as VoicesLabOptions;
  const q = <T extends HTMLElement>(id: string) => root.querySelector<T>(`#${id}`)!;
  return {
    root,
    options,
    speak,
    listVoices,
    prepare,
    fetchImpl,
    createEngine,
    openEntryStore,
    q,
    base: BASE
  };
}

describe("voices lab panel", () => {
  it("lab off: nothing is rendered, fetched, stored or registered", async () => {
    const t = setup({ enabled: false });
    await mountVoicesLabPanel(t.root, BASE, t.options);
    expect(t.root.innerHTML).toBe("");
    expect(t.fetchImpl).not.toHaveBeenCalled();
    expect(t.createEngine).not.toHaveBeenCalled();
    expect(t.openEntryStore).not.toHaveBeenCalled();
  });

  it("shows the controls and registers one engine for the installed model", async () => {
    const t = setup();
    await mountVoicesLabPanel(t.root, BASE, t.options);
    await flush();
    for (const id of [
      "lab-language",
      "lab-model",
      "lab-voice",
      "lab-preset",
      "lab-text",
      "lab-speak",
      "lab-stop",
      "lab-repeat",
      "lab-ab",
      "lab-download",
      "lab-status-card"
    ]) {
      expect(t.q(id), id).not.toBeNull();
    }
    expect(Array.from(t.q<HTMLSelectElement>("lab-language").options).map((o) => o.value)).toEqual([
      "de-DE",
      "de-AT",
      "en-US",
      "en-GB"
    ]);
    const models = Array.from(t.q<HTMLSelectElement>("lab-model").options);
    expect(models.map((o) => o.value)).toContain("articulino-de-en-int8");
    expect(models.map((o) => o.value)).toContain("control");
    expect(t.createEngine).toHaveBeenCalledTimes(1);
    const installed = t.createEngine.mock.calls[0]![0] as {
      entry: CatalogEntry;
      modelPackage: { source: unknown };
    }[];
    expect(installed.map((i) => i.entry.id)).toEqual(["articulino-de-en-int8"]);
    expect(installed[0]!.modelPackage.source).toEqual({
      sourceType: "app_managed",
      ref: "voices-lab/articulino-de-en-int8/1"
    });
    // Seven neural voices come from the lab engine; presets come from the corpus.
    expect(t.q<HTMLSelectElement>("lab-voice").options.length).toBeGreaterThanOrEqual(2);
    expect(t.q<HTMLSelectElement>("lab-preset").options.length).toBeGreaterThan(5);
  });

  it("lists the Core AI entry as unavailable with its reason", async () => {
    const t = setup();
    await mountVoicesLabPanel(t.root, BASE, t.options);
    await flush();
    const option = Array.from(t.q<HTMLSelectElement>("lab-model").options).find((o) =>
      o.textContent!.includes("Core AI")
    )!;
    expect(option.disabled).toBe(true);
    expect(t.root.textContent).toContain("unavailable");
    expect(t.root.textContent).toContain("no .aimodel is published");
  });

  it("speaks the neural voice through the model profile, never a model id", async () => {
    const t = setup();
    await mountVoicesLabPanel(t.root, BASE, t.options);
    await flush();
    t.q<HTMLButtonElement>("lab-speak").click();
    await flush();
    expect(t.speak).toHaveBeenCalledTimes(1);
    const [engine, options] = t.speak.mock.calls[0]!;
    expect(engine).toBe(LAB);
    expect(options["model"]).toBe(PROFILE);
    expect(options["voice"]).toMatchObject({ providerId: NEURAL_ID, id: "de-at-m-1" });
    const card = t.q("lab-status-card").textContent!;
    expect(card).toContain(NEURAL_ID);
    expect(card).toContain("articulino-de-en-int8");
    expect(card).toContain("onnx-int8");
    expect(card).toContain("local");
    expect(card).toContain("playback");
  });

  it("A/B speaks the neural voice, then the OS control, one after the other", async () => {
    const t = setup();
    const order: string[] = [];
    t.speak.mockImplementation(async (engine, options) => {
      order.push(options["model"] === undefined ? "control" : String(options["model"]));
      const done = new Promise<never>((resolve) =>
        setTimeout(() => resolve({ finishReason: "stop", runId: "r" } as never), 5)
      );
      void engine;
      return { runId: "r", cancel: vi.fn(), result: done } as never;
    });
    await mountVoicesLabPanel(t.root, BASE, t.options);
    await flush();
    t.q<HTMLButtonElement>("lab-ab").click();
    await new Promise((resolve) => setTimeout(resolve, 40));
    expect(order).toEqual([PROFILE, "control"]);
    expect(t.speak.mock.calls[1]![0]).toBe(BASE);
  });

  it("the control model speaks through the base engine without a profile", async () => {
    const t = setup();
    await mountVoicesLabPanel(t.root, BASE, t.options);
    await flush();
    const model = t.q<HTMLSelectElement>("lab-model");
    model.value = "control";
    model.dispatchEvent(new Event("change"));
    await flush();
    t.q<HTMLButtonElement>("lab-speak").click();
    await flush();
    expect(t.speak.mock.calls[0]![0]).toBe(BASE);
    expect(t.speak.mock.calls[0]![1]["model"]).toBeUndefined();
  });

  it("explains that OPFS is missing and still offers the control", async () => {
    const t = setup({ openEntryStore: undefined });
    await mountVoicesLabPanel(t.root, BASE, t.options);
    await flush();
    expect(t.root.textContent).toContain(
      "This browser cannot store models (no Origin Private File System)"
    );
    expect(t.q<HTMLButtonElement>("lab-download").disabled).toBe(true);
    expect(Array.from(t.q<HTMLSelectElement>("lab-model").options).map((o) => o.value)).toContain(
      "control"
    );
  });

  it("asks consent with size and licence before any request, and declining fetches nothing", async () => {
    const t = setup({ installed: false });
    await mountVoicesLabPanel(t.root, BASE, t.options);
    await flush();
    expect(t.createEngine).not.toHaveBeenCalled();
    t.q<HTMLButtonElement>("lab-download").click();
    await flush();
    const consent = t.q("lab-consent");
    expect(consent.hidden).toBe(false);
    const mb = Math.round(entryTotalBytes(onnxEntry()) / 1_000_000);
    expect(consent.textContent).toContain(`${mb} MB`);
    expect(consent.textContent).toContain("Apache-2.0");
    expect(consent.textContent).toContain("LicenseRef-Independo-Demo-Voices");
    t.q<HTMLButtonElement>("lab-consent-decline").click();
    await flush();
    expect(t.fetchImpl).not.toHaveBeenCalled();
    expect(t.createEngine).not.toHaveBeenCalled();
    expect(consent.hidden).toBe(true);
  });

  it("fell back: the card names the OS voice and shows no neural model, checksum or runtime", async () => {
    const t = setup();
    t.speak.mockImplementation(async (_engine, options) => ({
      runId: "r",
      cancel: vi.fn(),
      result: Promise.resolve({
        finishReason: "stop",
        speech: { locale: options["locale"], voice: { name: "Anna" } },
        provenance: {
          providerId: "web_system_speech",
          locality: "local",
          fallbackOccurred: true,
          attempts: [{ providerId: NEURAL_ID, outcome: "failed", errorClass: "Unavailable" }]
        },
        runId: "r"
      })
    }));
    await mountVoicesLabPanel(t.root, BASE, t.options);
    await flush();
    t.q<HTMLButtonElement>("lab-speak").click();
    await flush();
    const card = t.q("lab-status-card").textContent!;
    expect(card).toContain("fell back to OS voice");
    expect(card).toContain("Unavailable");
    expect(card).toContain("web_system_speech");
    expect(card).not.toContain("sha256:");
    expect(card).not.toContain("onnxruntime-web");
    expect(card).not.toContain("onnx-int8");
    expect(t.q("lab-status").textContent).toContain("fell back");
  });

  it("mount creates nothing and never asks for persistent storage; consent comes first", async () => {
    const persist = vi.fn(async () => {});
    const t = setup({ installed: false, requestPersistence: persist });
    document.body.append(t.root);
    await mountVoicesLabPanel(t.root, BASE, t.options);
    await flush();
    expect(persist).not.toHaveBeenCalled();
    for (const call of t.openEntryStore.mock.calls) expect(call[1]).toEqual({ create: false });
    t.q<HTMLButtonElement>("lab-download").click();
    await flush();
    expect(persist).not.toHaveBeenCalled();
    expect(document.activeElement).toBe(t.q("lab-consent-accept"));
    t.q<HTMLButtonElement>("lab-consent-decline").click();
    await flush();
    expect(persist).not.toHaveBeenCalled();
  });

  it("cancel button appears only while downloading and abort ends with a kept-files status", async () => {
    const t = setup({ installed: false });
    let seenSignal: AbortSignal | undefined;
    t.fetchImpl.mockImplementation(async (_url: string, init?: { signal?: AbortSignal }) => {
      seenSignal = init?.signal;
      return new Promise((_resolve, reject) =>
        init?.signal?.addEventListener("abort", () =>
          reject(Object.assign(new Error("aborted"), { name: "AbortError" }))
        )
      );
    });
    await mountVoicesLabPanel(t.root, BASE, t.options);
    await flush();
    const cancel = t.q<HTMLButtonElement>("lab-cancel-download");
    expect(cancel.hidden).toBe(true);
    t.q<HTMLButtonElement>("lab-download").click();
    await flush();
    expect(cancel.hidden).toBe(true); // still asking for consent
    t.q<HTMLButtonElement>("lab-consent-accept").click();
    await flush();
    expect(cancel.hidden).toBe(false);
    expect(cancel.textContent).toBe("Cancel download");
    cancel.click();
    await flush();
    expect(seenSignal?.aborted).toBe(true);
    expect(t.q("lab-status").textContent).toBe("Download cancelled; verified files are kept.");
    expect(cancel.hidden).toBe(true);
    expect(t.createEngine).not.toHaveBeenCalled();
  });

  it("A/B control card shows the control's own voice, not the neural voice name", async () => {
    const t = setup();
    const cards: string[] = [];
    t.speak.mockImplementation(async (_engine, options) => {
      if (options["model"] === undefined) cards.push(t.q("lab-status-card").textContent!);
      return {
        runId: "r",
        cancel: vi.fn(),
        result: Promise.resolve({
          finishReason: "stop",
          speech: { locale: options["locale"] },
          provenance: {
            providerId: options["model"] === undefined ? "web_system_speech" : NEURAL_ID,
            locality: "local"
          },
          runId: "r"
        })
      } as never;
    });
    await mountVoicesLabPanel(t.root, BASE, t.options);
    await flush();
    t.q<HTMLButtonElement>("lab-ab").click();
    await new Promise((resolve) => setTimeout(resolve, 40));
    const card = t.q("lab-status-card").textContent!;
    expect(card).toContain("web_system_speech");
    expect(card).not.toContain("Austrian German man 1");
  });

  it("formats the entry size in whole decimal megabytes", async () => {
    const t = setup({ installed: false });
    await mountVoicesLabPanel(t.root, BASE, t.options);
    await flush();
    t.q<HTMLButtonElement>("lab-download").click();
    await flush();
    expect(entryTotalBytes(onnxEntry())).toBe(113_011_812);
    expect(t.q("lab-consent").textContent).toContain("113 MB");
    expect(t.q("lab-download").textContent).toContain("113 MB");
  });
});
