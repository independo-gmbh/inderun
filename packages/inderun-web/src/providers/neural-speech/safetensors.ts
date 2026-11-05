import { NeuralSpeechRuntimeError, type SpeechTensor } from "./runtime.js";

/** A parsed safetensors file: its tensors by name and the `__metadata__` string map. */
export interface SafetensorsFile {
  tensors: Record<string, SpeechTensor>;
  metadata: Record<string, string>;
}

interface HeaderEntry {
  dtype?: unknown;
  shape?: unknown;
  data_offsets?: unknown;
}

function malformed(why: string): NeuralSpeechRuntimeError {
  return new NeuralSpeechRuntimeError("capability", `voice file malformed: ${why}`);
}

/**
 * Reads a safetensors file: an 8-byte little-endian header length, the JSON header and the byte
 * buffer. Only `F32` and `I64` tensors are accepted; any other dtype is refused by name.
 */
export function parseSafetensors(bytes: Uint8Array): SafetensorsFile {
  if (bytes.length < 8) throw malformed("shorter than the 8-byte header length");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const headerLength = view.getBigUint64(0, true);
  if (headerLength > BigInt(bytes.length - 8)) throw malformed("header length exceeds the file");
  const bufferStart = 8 + Number(headerLength);

  let header: Record<string, unknown>;
  try {
    const parsed: unknown = JSON.parse(new TextDecoder().decode(bytes.subarray(8, bufferStart)));
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      throw new Error("header is not an object");
    }
    header = parsed as Record<string, unknown>;
  } catch (error) {
    throw malformed(`header is not valid JSON (${(error as Error).message})`);
  }

  const bufferLength = bytes.length - bufferStart;
  const tensors: Record<string, SpeechTensor> = {};
  const metadata: Record<string, string> = {};

  for (const [name, raw] of Object.entries(header)) {
    if (name === "__metadata__") {
      for (const [key, value] of Object.entries((raw ?? {}) as Record<string, unknown>)) {
        if (typeof value !== "string") throw malformed(`metadata '${key}' is not a string`);
        metadata[key] = value;
      }
      continue;
    }
    const entry = (raw ?? {}) as HeaderEntry;
    if (entry.dtype !== "F32" && entry.dtype !== "I64") {
      throw new NeuralSpeechRuntimeError(
        "capability",
        `voice file unsupported: dtype ${String(entry.dtype)} of '${name}'`
      );
    }
    const { shape, data_offsets: offsets } = entry;
    if (
      !Array.isArray(shape) ||
      !shape.every((n) => Number.isInteger(n) && n >= 0) ||
      !Array.isArray(offsets) ||
      offsets.length !== 2 ||
      !offsets.every((n) => Number.isInteger(n) && n >= 0)
    ) {
      throw malformed(`'${name}' has an invalid shape or data_offsets`);
    }
    const [begin, end] = offsets as [number, number];
    if (begin > end || end > bufferLength)
      throw malformed(`'${name}' offsets lie outside the buffer`);
    const width = entry.dtype === "F32" ? 4 : 8;
    const count = (shape as number[]).reduce((a, b) => a * b, 1);
    if (end - begin !== count * width)
      throw malformed(`'${name}' byte range does not match its shape`);

    const at = bufferStart + begin;
    if (entry.dtype === "F32") {
      const data = new Float32Array(count);
      for (let i = 0; i < count; i += 1) data[i] = view.getFloat32(at + i * 4, true);
      tensors[name] = { shape: shape as number[], data };
    } else {
      const data = new BigInt64Array(count);
      for (let i = 0; i < count; i += 1) data[i] = view.getBigInt64(at + i * 8, true);
      tensors[name] = { shape: shape as number[], data };
    }
  }
  return { tensors, metadata };
}
