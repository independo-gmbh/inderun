import { describe, expect, it, vi } from "vitest";
import type { ProviderDescriptor, TaskRequest } from "@independo/inderun-contracts";
import { prepare } from "../facade/prepare.js";
import { createBrowserHostServices } from "./browser-host.js";
import { IndeRun } from "./engine.js";
import type { PreparableProviderAdapter, ProviderDynamicCapabilities } from "./provider.js";
import { ProviderRegistry } from "./registry.js";

type Readiness = "ready" | "cold" | "not_prepared" | "preparing";

const text: TaskRequest = { schemaVersion: "1.0", task: { kind: "text_to_text" }, prompt: "Hi" };

function fakeProvider(id: string, initial: Readiness, work: () => Promise<void> = async () => {}) {
  let readiness = initial;
  const calls = { prepare: 0, run: 0 };
  const probes = { capabilities: 0 };
  const provider: PreparableProviderAdapter = {
    describe: (): ProviderDescriptor => ({
      id,
      type: "local",
      transport: "in_process",
      supports: {
        run: true,
        streaming: false,
        realtime: false,
        tools: false,
        reasoningEvents: false,
        structuredOutput: false,
        multimodal: false
      },
      cancel: "none",
      tasks: ["text_to_text"],
      taskCapabilities: [
        {
          kind: "text_to_text",
          inputs: ["text"],
          interaction: { run: true, stream: false, prepare: true },
          cancel: "none",
          outputs: [{ delivery: "inline" }]
        }
      ]
    }),
    capabilities: async (): Promise<ProviderDynamicCapabilities> => {
      probes.capabilities += 1;
      return {
        available: readiness === "ready" || readiness === "cold",
        taskCapabilities: [{ kind: "text_to_text", readiness }]
      };
    },
    run: async (_request, context) => {
      calls.run += 1;
      return {
        schemaVersion: "1.0",
        runId: context.runId,
        output: { type: "text", text: "ok" },
        finishReason: "stop",
        telemetry: { providerUsed: id, totalMs: 0 }
      };
    },
    async *prepare() {
      calls.prepare += 1;
      yield { fractionCompleted: 0.5 };
      await work();
      readiness = "ready";
    }
  };
  return { provider, calls, probes };
}

function engine(providers: PreparableProviderAdapter[], autoDownload = false): IndeRun {
  const registry = new ProviderRegistry();
  for (const provider of providers) registry.register(provider, { autoDownload });
  return new IndeRun(
    registry,
    createBrowserHostServices({ connectivity: { isOnline: async () => true } })
  );
}

describe("prepare", () => {
  it("runs once on the first call when the application never called it", async () => {
    const { provider, calls } = fakeProvider("a", "preparing");
    const inderun = engine([provider]);

    await inderun.run(text);
    await inderun.run(text);

    expect(calls).toEqual({ prepare: 1, run: 2 });
  });

  it("is skipped on the first call after an explicit prepare", async () => {
    const { provider, calls } = fakeProvider("a", "cold");
    const inderun = engine([provider]);

    await (
      await prepare(inderun)
    ).result;
    await inderun.run(text);

    expect(calls).toEqual({ prepare: 1, run: 1 });
  });

  it("shares one preparation between concurrent first calls", async () => {
    let release!: () => void;
    const gate = new Promise<void>((resolve) => (release = resolve));
    const { provider, calls } = fakeProvider("a", "preparing", () => gate);
    const inderun = engine([provider]);

    const runs = Promise.all([inderun.run(text), inderun.run(text)]);
    await new Promise((resolve) => setTimeout(resolve, 5));
    release();
    await runs;

    expect(calls.prepare).toBe(1);
  });

  it("leaves a cold provider alone on the first call, because a cold run warms itself", async () => {
    const { provider, calls } = fakeProvider("a", "cold");

    await engine([provider]).run(text);

    expect(calls).toEqual({ prepare: 0, run: 1 });
  });

  it("warms a cold provider when asked to", async () => {
    const { provider, calls } = fakeProvider("a", "cold");

    const { items } = await (await prepare(engine([provider]))).result;

    expect(calls.prepare).toBe(1);
    expect(items).toEqual([{ providerId: "a", task: "text_to_text", status: "prepared" }]);
  });

  it("never starts a download without permission", async () => {
    const { provider, calls } = fakeProvider("a", "not_prepared");
    const inderun = engine([provider]);

    const { items } = await (await prepare(inderun)).result;

    expect(calls.prepare).toBe(0);
    expect(items).toMatchObject([{ status: "skipped" }]);
    await expect(inderun.run(text)).rejects.toMatchObject({
      details: expect.objectContaining({
        rejectedProviders: [
          expect.objectContaining({ reasons: [expect.objectContaining({ code: "not_ready" })] })
        ]
      })
    });
    expect(calls.prepare).toBe(0);
  });

  it("downloads on the first call under autoDownload, then runs", async () => {
    const { provider, calls } = fakeProvider("a", "not_prepared");

    await engine([provider], true).run(text);

    expect(calls).toEqual({ prepare: 1, run: 1 });
  });

  it("lets one call allow a download, whatever registration said", async () => {
    const { provider, calls } = fakeProvider("a", "not_prepared");

    await (
      await prepare(engine([provider]), { allowDownload: true })
    ).result;

    expect(calls.prepare).toBe(1);
  });

  it("gives up waiting at the bound, so routing can fall back", async () => {
    const stuck = fakeProvider("a", "not_prepared", () => new Promise(() => {}));
    const fallback = fakeProvider("b", "ready");

    const result = await engine([stuck.provider, fallback.provider], true).run({
      ...text,
      constraints: { timeoutMs: 10 }
    });

    expect(result.telemetry?.providerUsed).toBe("b");
  });

  it("keeps going when one provider fails, and reports it", async () => {
    const broken = fakeProvider("a", "cold", async () => {
      throw new Error("no");
    });
    const healthy = fakeProvider("b", "cold");

    const { finishReason, items } = await (
      await prepare(engine([broken.provider, healthy.provider]))
    ).result;

    expect(finishReason).toBe("stop");
    expect(items.map((item) => item.status).sort()).toEqual(["failed", "prepared"]);
  });

  it("reports progress with the provider and task", async () => {
    const { provider } = fakeProvider("a", "cold");
    const onProgress = vi.fn();

    await (
      await prepare(engine([provider]), { onProgress })
    ).result;

    expect(onProgress).toHaveBeenCalledWith({
      providerId: "a",
      task: "text_to_text",
      fractionCompleted: 0.5
    });
  });

  it("shares a failure with a caller that waited for the same preparation", async () => {
    let release!: () => void;
    const gate = new Promise<void>((resolve) => (release = resolve));
    const { provider, calls, probes } = fakeProvider("a", "cold", async () => {
      await gate;
      throw new Error("no");
    });
    const inderun = engine([provider]);

    const first = await prepare(inderun);
    await vi.waitFor(() => expect(calls.prepare).toBe(1));
    const checks = probes.capabilities;
    const second = await prepare(inderun);
    await vi.waitFor(() => expect(probes.capabilities).toBeGreaterThan(checks));
    await new Promise((resolve) => setTimeout(resolve, 50));
    release();

    expect((await first.result).items).toMatchObject([{ status: "failed" }]);
    expect((await second.result).items).toMatchObject([{ status: "failed" }]);
    expect(calls.prepare).toBe(1);
  });

  it("does not count a skipped preparation as done for a first run that may download", async () => {
    const { provider, calls } = fakeProvider("a", "not_prepared");
    const inderun = engine([provider], true);

    const { items } = await (await prepare(inderun, { allowDownload: false })).result;
    expect(items).toMatchObject([{ status: "skipped" }]);
    await inderun.run(text);

    expect(calls).toEqual({ prepare: 1, run: 1 });
  });

  it("does not count a failed preparation as done", async () => {
    let attempts = 0;
    const { provider, calls } = fakeProvider("a", "preparing", async () => {
      attempts += 1;
      if (attempts === 1) throw new Error("no");
    });
    const inderun = engine([provider]);

    await (
      await prepare(inderun)
    ).result;
    await inderun.run(text);

    expect(calls).toEqual({ prepare: 2, run: 1 });
  });

  it("does not let prepared scope stand in for another", async () => {
    const { provider, calls } = fakeProvider("a", "preparing");
    const inderun = engine([provider]);

    await (
      await prepare(inderun, { locale: "de-DE" })
    ).result;
    await inderun.run(text);

    expect(calls.prepare).toBe(1);
  });
});
