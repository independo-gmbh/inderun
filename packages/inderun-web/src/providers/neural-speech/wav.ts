/** Size of the canonical WAV header written by {@link encodeWav}. */
export const WAV_HEADER_BYTES = 44;

/** Encodes mono 16-bit PCM as a canonical little-endian WAV file. */
export function encodeWav(samples: Int16Array, sampleRate: number): Uint8Array {
  const dataBytes = samples.length * 2;
  const bytes = new Uint8Array(WAV_HEADER_BYTES + dataBytes);
  const view = new DataView(bytes.buffer);
  const tag = (at: number, value: string): void => {
    for (let i = 0; i < 4; i += 1) view.setUint8(at + i, value.charCodeAt(i));
  };

  tag(0, "RIFF");
  view.setUint32(4, 36 + dataBytes, true);
  tag(8, "WAVE");
  tag(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  tag(36, "data");
  view.setUint32(40, dataBytes, true);
  samples.forEach((sample, i) => view.setInt16(WAV_HEADER_BYTES + i * 2, sample, true));
  return bytes;
}
