import { createHash, randomBytes } from "node:crypto";
import { describe, expect, it } from "vitest";
import { Sha256 } from "./sha256";

const reference = (data: Uint8Array) => createHash("sha256").update(data).digest("hex");

describe("incremental sha256", () => {
  it("matches the empty and short vectors", () => {
    expect(new Sha256().digestHex()).toBe(reference(new Uint8Array()));
    expect(new Sha256().update(new TextEncoder().encode("abc")).digestHex()).toBe(
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
  });

  it("matches node for every length around the block boundaries, in odd chunks", () => {
    for (const size of [1, 55, 56, 57, 63, 64, 65, 119, 120, 127, 128, 129, 1000, 70001]) {
      const data = new Uint8Array(randomBytes(size));
      const hash = new Sha256();
      for (let at = 0; at < size;) {
        const step = 1 + ((at * 7 + size) % 97);
        hash.update(data.subarray(at, at + step));
        at += step;
      }
      expect(hash.digestHex(), `size ${size}`).toBe(reference(data));
    }
  });
});
