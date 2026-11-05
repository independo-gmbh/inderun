import type { SpeechTensor } from "../providers/neural-speech/runtime.js";

/** Test-side safetensors writer (F32 and I64 only); the production code only reads the format. */
export function encodeSafetensors(
  tensors: Record<string, SpeechTensor>,
  metadata: Record<string, string> = {}
): Uint8Array {
  const header: Record<string, unknown> = { __metadata__: metadata };
  const chunks: Uint8Array[] = [];
  let offset = 0;
  for (const [name, tensor] of Object.entries(tensors)) {
    const bytes = new Uint8Array(tensor.data.byteLength);
    const view = new DataView(bytes.buffer);
    if (tensor.data instanceof BigInt64Array) {
      tensor.data.forEach((v, i) => view.setBigInt64(i * 8, v, true));
    } else {
      tensor.data.forEach((v, i) => view.setFloat32(i * 4, v, true));
    }
    header[name] = {
      dtype: tensor.data instanceof BigInt64Array ? "I64" : "F32",
      shape: tensor.shape,
      data_offsets: [offset, offset + bytes.length]
    };
    chunks.push(bytes);
    offset += bytes.length;
  }
  return assemble(JSON.stringify(header), chunks);
}

/** Frames an arbitrary header JSON and body: the 8-byte little-endian header length comes first. */
export function assemble(headerJson: string, body: Uint8Array[]): Uint8Array {
  const json = new TextEncoder().encode(headerJson);
  const total = body.reduce((n, c) => n + c.length, 0);
  const out = new Uint8Array(8 + json.length + total);
  new DataView(out.buffer).setBigUint64(0, BigInt(json.length), true);
  out.set(json, 8);
  let at = 8 + json.length;
  for (const chunk of body) {
    out.set(chunk, at);
    at += chunk.length;
  }
  return out;
}
