import { describe, expect, it } from "vitest";

import { assemble, encodeSafetensors } from "../../test/safetensors-writer.js";
import { NeuralSpeechRuntimeError } from "./runtime.js";
import { parseSafetensors } from "./safetensors.js";

function failure(bytes: Uint8Array): NeuralSpeechRuntimeError {
  try {
    parseSafetensors(bytes);
  } catch (error) {
    expect(error).toBeInstanceOf(NeuralSpeechRuntimeError);
    return error as NeuralSpeechRuntimeError;
  }
  throw new Error("expected parseSafetensors to throw");
}

describe("parseSafetensors", () => {
  it("round-trips F32 and I64 tensors and metadata", () => {
    const bytes = encodeSafetensors(
      {
        a: { shape: [2, 3], data: new Float32Array([1, 2, 3, 4, 5, -6.5]) },
        b: { shape: [2], data: new BigInt64Array([7n, -8n]) }
      },
      { format: "test/1" }
    );
    const file = parseSafetensors(bytes);
    expect(file.metadata).toEqual({ format: "test/1" });
    expect(file.tensors.a?.shape).toEqual([2, 3]);
    expect(Array.from(file.tensors.a?.data ?? [])).toEqual([1, 2, 3, 4, 5, -6.5]);
    expect(file.tensors.b?.data).toBeInstanceOf(BigInt64Array);
    expect(Array.from(file.tensors.b?.data ?? [])).toEqual([7n, -8n]);
  });

  it("refuses a dtype other than F32 and I64 by name", () => {
    const header = JSON.stringify({ w: { dtype: "F16", shape: [1], data_offsets: [0, 2] } });
    const error = failure(assemble(header, [new Uint8Array(2)]));
    expect(error.kind).toBe("capability");
    expect(error.message).toBe("voice file unsupported: dtype F16 of 'w'");
  });

  it("refuses offsets beyond the buffer", () => {
    const header = JSON.stringify({ w: { dtype: "F32", shape: [2], data_offsets: [0, 8] } });
    const error = failure(assemble(header, [new Uint8Array(4)]));
    expect(error.kind).toBe("capability");
    expect(error.message).toMatch(/^voice file malformed: /u);
  });

  it("refuses a byte range that does not match the shape", () => {
    const header = JSON.stringify({ w: { dtype: "F32", shape: [3], data_offsets: [0, 8] } });
    expect(failure(assemble(header, [new Uint8Array(8)])).message).toMatch(
      /^voice file malformed: /u
    );
  });

  it("refuses a truncated or oversized header", () => {
    expect(failure(new Uint8Array(4)).message).toMatch(/^voice file malformed: /u);
    const bytes = new Uint8Array(16);
    new DataView(bytes.buffer).setBigUint64(0, 1000n, true);
    expect(failure(bytes).message).toMatch(/^voice file malformed: /u);
    expect(failure(assemble("not json", [])).message).toMatch(/^voice file malformed: /u);
  });
});
