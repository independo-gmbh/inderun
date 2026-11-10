// @vitest-environment happy-dom
import { describe, expect, it } from "vitest";
import { catalog } from "./fixtures.test-support";
import { catalogEntryToModelPackage, type InstalledModel } from "./neural-catalog";
import { createVoicesLabEngine } from "./voices-lab-engine";

describe("createVoicesLabEngine", () => {
  it("registers one neural provider per installed entry next to system speech", async () => {
    const entry = catalog().entries.find((e) => e.id === "articulino-de-en-int8")!;
    const installed: InstalledModel[] = [
      {
        entry,
        modelPackage: catalogEntryToModelPackage(entry, "voices-lab/articulino-de-en-int8/1"),
        files: { read: async () => new Uint8Array() }
      }
    ];
    const lab = createVoicesLabEngine(installed);
    const ids = (await lab.engine.checkCapabilities()).map((s) => s.providerId);
    expect(ids).toContain("local.onnx.speech.web:articulino-de-en-int8");
    expect(ids).toContain("web_system_speech");
  });

  it("close closes the engine and the runtimes created for it", async () => {
    const entry = catalog().entries.find((e) => e.id === "articulino-de-en-int8")!;
    const lab = createVoicesLabEngine([
      {
        entry,
        modelPackage: catalogEntryToModelPackage(entry, "voices-lab/articulino-de-en-int8/1"),
        files: { read: async () => new Uint8Array() }
      }
    ]);
    await lab.close();
    await lab.close();
    // The engine refuses work once closed.
    await expect(lab.engine.readArtifact({ artifactId: "x" })).rejects.toMatchObject({
      details: { code: "engine_closed" }
    });
  });
});
