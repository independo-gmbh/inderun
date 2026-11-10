import { describe, expect, it } from "vitest";

import { encodeWav, WAV_HEADER_BYTES } from "./wav.js";

describe("encodeWav", () => {
  it("writes a canonical 44-byte mono 16-bit header followed by little-endian samples", () => {
    const bytes = encodeWav(new Int16Array([0, 1, -1]), 24000);
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const ascii = (at: number): string => String.fromCharCode(...bytes.subarray(at, at + 4));

    expect(WAV_HEADER_BYTES).toBe(44);
    expect(bytes.length).toBe(50);
    expect(ascii(0)).toBe("RIFF");
    expect(view.getUint32(4, true)).toBe(42);
    expect(ascii(8)).toBe("WAVE");
    expect(ascii(12)).toBe("fmt ");
    expect(view.getUint32(16, true)).toBe(16);
    expect(view.getUint16(20, true)).toBe(1);
    expect(view.getUint16(22, true)).toBe(1);
    expect(view.getUint32(24, true)).toBe(24000);
    expect(view.getUint32(28, true)).toBe(48000);
    expect(view.getUint16(32, true)).toBe(2);
    expect(view.getUint16(34, true)).toBe(16);
    expect(ascii(36)).toBe("data");
    expect(view.getUint32(40, true)).toBe(6);
    expect(Array.from(bytes.subarray(44))).toEqual([0x00, 0x00, 0x01, 0x00, 0xff, 0xff]);
  });
});
