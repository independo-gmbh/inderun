import { createHash } from "node:crypto";
import { describe, expect, it, vi } from "vitest";
import type { CatalogEntry } from "./neural-catalog";
import { downloadEntry, type ConsentPrompt, type ModelStorage } from "./neural-downloader";

const sha = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex");
const HF = "https://huggingface.co/x/resolve/rev/";
const GH = "https://github.com/independo-gmbh/inderun/releases/download/tag/";
const ASSETS = "https://proxy.test/assets";

const blobs: Record<string, Uint8Array> = {
  [`${HF}config.json`]: new TextEncoder().encode('{"a":1}'),
  [`${GH}voice.safetensors`]: new Uint8Array(5000).map((_, i) => i % 251)
};

function entryOf(): CatalogEntry {
  const config = blobs[`${HF}config.json`]!;
  const voice = blobs[`${GH}voice.safetensors`]!;
  return {
    id: "m",
    family: "articulino",
    version: "1",
    variant: "v",
    license: { spdx: "Apache-2.0", restrictions: "none", attribution: "Upstream attribution." },
    review: { status: "benchmark_only" },
    runtime: { format: "onnx", platforms: ["web"], minOsVersion: null },
    speech: {
      pipeline: "articulino",
      sampleRate: 24000,
      channels: 1,
      graphs: { text: "text.onnx" },
      frontend: { kind: "grapheme", assets: { config: "config.json" } }
    },
    files: [
      {
        role: "config",
        path: "config.json",
        url: `${HF}config.json`,
        sha256: sha(config),
        bytes: config.length
      }
    ],
    voices: [
      {
        id: "v1",
        name: "Voice",
        locales: ["de-DE"],
        file: {
          path: "voices/v1.safetensors",
          url: `${GH}voice.safetensors`,
          sha256: sha(voice),
          bytes: voice.length
        },
        license: { spdx: "LicenseRef-Independo-Demo-Voices", restrictions: "demo use" }
      }
    ]
  } as CatalogEntry;
}

class FakeStorage implements ModelStorage {
  readonly files = new Map<string, Uint8Array>();
  writeError: Error | undefined;
  async size(path: string) {
    return this.files.get(path)?.length;
  }
  async *read(path: string) {
    const bytes = this.files.get(path);
    if (bytes !== undefined) yield bytes;
  }
  async write(path: string) {
    const parts: Uint8Array[] = [];
    return {
      write: async (chunk: Uint8Array) => {
        if (this.writeError !== undefined) throw this.writeError;
        parts.push(chunk.slice());
      },
      close: async () => {
        const all = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
        let at = 0;
        for (const p of parts) {
          all.set(p, at);
          at += p.length;
        }
        this.files.set(path, all);
      },
      abort: async () => undefined
    };
  }
  async remove(path: string) {
    this.files.delete(path);
  }
}

function response(bytes: Uint8Array, init: { status?: number; chunk?: number } = {}): Response {
  const chunk = init.chunk ?? 1024;
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      for (let at = 0; at < bytes.length; at += chunk)
        controller.enqueue(bytes.slice(at, at + chunk));
      controller.close();
    }
  });
  return new Response(init.status === 404 ? "nope" : body, { status: init.status ?? 200 });
}

function fakeFetch(overrides: Record<string, () => Response> = {}) {
  const calls: string[] = [];
  const impl = vi.fn(async (input: RequestInfo | URL) => {
    const url = String(input);
    calls.push(url);
    const real = url.startsWith(ASSETS)
      ? decodeURIComponent(new URL(url).searchParams.get("url")!)
      : url;
    const make = overrides[real];
    if (make !== undefined) return make();
    const bytes = blobs[real];
    return bytes === undefined ? response(new Uint8Array(), { status: 404 }) : response(bytes);
  });
  return { impl: impl as unknown as typeof fetch, calls };
}

const base = (
  fetchImpl: typeof fetch,
  storage: ModelStorage,
  consent: (prompt: ConsentPrompt) => Promise<boolean> = async () => true
) => ({
  fetch: fetchImpl,
  storage,
  assetsUrl: ASSETS,
  consent,
  onProgress: vi.fn()
});

describe("downloadEntry", () => {
  it("declined consent makes no request", async () => {
    const { impl, calls } = fakeFetch();
    const storage = new FakeStorage();
    const consent = vi.fn(async (_prompt: { totalBytes: number; licenses: string[] }) => false);
    const result = await downloadEntry(entryOf(), base(impl, storage, consent));
    expect(result).toEqual({ installed: false, reason: "declined" });
    expect(calls).toEqual([]);
    expect(storage.files.size).toBe(0);
    const prompt = consent.mock.calls[0]![0];
    expect(prompt.totalBytes).toBe(7 + 5000);
    expect(prompt.licenses.join(" ")).toMatch(/Upstream attribution/);
    expect(prompt.licenses.join(" ")).toMatch(/demo use/);
  });

  it("routes GitHub assets through the proxy and Hugging Face directly", async () => {
    const { impl, calls } = fakeFetch();
    const storage = new FakeStorage();
    const progress = vi.fn();
    const result = await downloadEntry(entryOf(), { ...base(impl, storage), onProgress: progress });
    expect(result).toEqual({ installed: true });
    expect(calls).toEqual([
      `${HF}config.json`,
      `${ASSETS}?url=${encodeURIComponent(`${GH}voice.safetensors`)}`
    ]);
    expect(storage.files.get("voices/v1.safetensors")).toEqual(blobs[`${GH}voice.safetensors`]);
    const last = progress.mock.calls.at(-1)![0];
    expect(last.doneBytes).toBe(last.totalBytes);
  });

  it("resume skips verified files", async () => {
    const storage = new FakeStorage();
    storage.files.set("config.json", blobs[`${HF}config.json`]!);
    const { impl, calls } = fakeFetch();
    await downloadEntry(entryOf(), base(impl, storage));
    expect(calls).toHaveLength(1);
    expect(calls[0]).toContain("voice.safetensors");
  });

  it("re-fetches a stored file whose bytes do not verify", async () => {
    const storage = new FakeStorage();
    storage.files.set("config.json", new TextEncoder().encode('{"a":9}'));
    const { impl, calls } = fakeFetch();
    await downloadEntry(entryOf(), base(impl, storage));
    expect(calls).toHaveLength(2);
    expect(storage.files.get("config.json")).toEqual(blobs[`${HF}config.json`]);
  });

  it("partial file is not accepted", async () => {
    const full = blobs[`${GH}voice.safetensors`]!;
    const { impl } = fakeFetch({
      [`${GH}voice.safetensors`]: () => response(full.slice(0, 2000))
    });
    const storage = new FakeStorage();
    await expect(downloadEntry(entryOf(), base(impl, storage))).rejects.toThrow(
      "checksum mismatch: voices/v1.safetensors"
    );
    expect(storage.files.has("voices/v1.safetensors")).toBe(false);
    // The verified file before it stays, so a retry resumes.
    expect(storage.files.has("config.json")).toBe(true);
  });

  it("checksum mismatch removes the file", async () => {
    const wrong = blobs[`${GH}voice.safetensors`]!.slice();
    wrong[10] ^= 0xff;
    const { impl } = fakeFetch({ [`${GH}voice.safetensors`]: () => response(wrong) });
    const storage = new FakeStorage();
    await expect(downloadEntry(entryOf(), base(impl, storage))).rejects.toThrow(
      "checksum mismatch: voices/v1.safetensors"
    );
    expect(storage.files.has("voices/v1.safetensors")).toBe(false);
  });

  it("storage error is reported", async () => {
    const { impl } = fakeFetch();
    const storage = new FakeStorage();
    const quota = new Error("quota");
    quota.name = "QuotaExceededError";
    const original = storage.write.bind(storage);
    storage.write = async (path: string) => {
      const writer = await original(path);
      if (path.startsWith("voices/")) storage.writeError = quota;
      return writer;
    };
    await expect(downloadEntry(entryOf(), base(impl, storage))).rejects.toThrow(
      /not enough storage space to save voices\/v1.safetensors/
    );
    expect(storage.files.has("voices/v1.safetensors")).toBe(false);
  });

  it("says when an asset is not published yet", async () => {
    const { impl } = fakeFetch({
      [`${GH}voice.safetensors`]: () => response(new Uint8Array(), { status: 404 })
    });
    await expect(downloadEntry(entryOf(), base(impl, new FakeStorage()))).rejects.toThrow(
      "asset not published yet (HTTP 404): voices/v1.safetensors"
    );
  });

  it("abort mid-stream removes the partial file, keeps verified ones and fetches nothing more", async () => {
    const { impl, calls } = fakeFetch();
    const storage = new FakeStorage();
    const controller = new AbortController();
    const onProgress = vi.fn((p: { path: string; doneBytes: number }) => {
      if (p.path.startsWith("voices/") && p.doneBytes > 7 + 1024) controller.abort();
    });
    await expect(
      downloadEntry(entryOf(), { ...base(impl, storage), onProgress, signal: controller.signal })
    ).rejects.toMatchObject({ name: "AbortError" });
    expect(storage.files.has("voices/v1.safetensors")).toBe(false);
    expect(storage.files.has("config.json")).toBe(true);
    expect(calls).toHaveLength(2);
    expect(impl).toHaveBeenLastCalledWith(expect.any(String), { signal: controller.signal });
    const seen = onProgress.mock.calls.length;
    await Promise.resolve();
    expect(onProgress.mock.calls.length).toBe(seen);
  });

  it("abort between files makes no further request", async () => {
    const { impl, calls } = fakeFetch();
    const storage = new FakeStorage();
    const controller = new AbortController();
    const onProgress = vi.fn(() => controller.abort());
    await expect(
      downloadEntry(entryOf(), { ...base(impl, storage), onProgress, signal: controller.signal })
    ).rejects.toMatchObject({ name: "AbortError" });
    expect(calls).toHaveLength(1);
    expect(storage.files.has("voices/v1.safetensors")).toBe(false);
  });
});
