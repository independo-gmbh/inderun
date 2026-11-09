import { describe, expect, it } from "vitest";
import { createOpfsPackageFiles } from "./opfs-package-files";
import { MemoryDirectory } from "./memory-opfs.test-support";

describe("createOpfsPackageFiles", () => {
  async function dirWith(): Promise<MemoryDirectory> {
    const root = new MemoryDirectory();
    root.files.set("config.json", new TextEncoder().encode("{}"));
    const voices = (await root.getDirectoryHandle("voices", { create: true })) as MemoryDirectory;
    voices.files.set("a.safetensors", new Uint8Array([1, 2, 3]));
    return root;
  }

  it("reads files, including the ones in a subdirectory", async () => {
    const files = createOpfsPackageFiles(await dirWith());
    expect(new TextDecoder().decode(await files.read("config.json"))).toBe("{}");
    expect(Array.from(await files.read("voices/a.safetensors"))).toEqual([1, 2, 3]);
  });

  it("refuses names that leave the package", async () => {
    const files = createOpfsPackageFiles(await dirWith());
    for (const name of ["../x", "voices/../../x", "/etc/passwd", "%2e%2e/x", "https://x/y", ""]) {
      await expect(files.read(name), name).rejects.toThrow(/model file name invalid/);
    }
  });

  it("reports a missing file by name", async () => {
    const files = createOpfsPackageFiles(await dirWith());
    await expect(files.read("text.onnx")).rejects.toThrow(/model files missing: text.onnx/);
  });
});
