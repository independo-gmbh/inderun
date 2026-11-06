import { describe, expect, it } from "vitest";
import { MemoryDirectory } from "./memory-opfs.test-support";
import { createOpfsModelStorage } from "./opfs-storage";

describe("createOpfsModelStorage", () => {
  it("writes into subdirectories, reads back, reports size and removes", async () => {
    const root = new MemoryDirectory();
    const storage = createOpfsModelStorage(root);
    expect(await storage.size("voices/a.bin")).toBeUndefined();
    const writer = await storage.write("voices/a.bin");
    await writer.write(new Uint8Array([1, 2]));
    await writer.write(new Uint8Array([3]));
    // The real OPFS creates the (empty) file at once; the bytes land on close.
    expect(await storage.size("voices/a.bin")).toBe(0);
    await writer.close();
    expect(await storage.size("voices/a.bin")).toBe(3);
    const read: number[] = [];
    for await (const chunk of storage.read("voices/a.bin")) read.push(...chunk);
    expect(read).toEqual([1, 2, 3]);
    await storage.remove("voices/a.bin");
    await storage.remove("voices/a.bin");
    expect(await storage.size("voices/a.bin")).toBeUndefined();
  });
});
