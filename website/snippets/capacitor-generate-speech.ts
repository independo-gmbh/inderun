import { createIndeRunCapacitor } from "@independo/capacitor-inderun";

const ai = createIndeRunCapacitor({ systemSpeech: true });

// Silent: this returns an artifact handle, never bytes. The audio is WAV on iOS and Android; the
// browser's system speech can only play, so routing refuses it here.
const speech = await ai.generateSpeech({
  text: "Your appointment has been rescheduled.",
  locale: "en-US",
  mediaTypes: ["audio/wav"]
});

try {
  const chunks: Uint8Array[] = [];
  let offset = 0;
  for (;;) {
    const chunk = await ai.readArtifact({ artifactId: speech.artifact.id, offset });
    chunks.push(chunk.bytes);
    offset += chunk.bytes.byteLength;
    if (chunk.done) {
      break;
    }
  }
  const wav = new Blob(chunks as BlobPart[], { type: speech.artifact.mediaType });
  console.log(wav.size, speech.artifact.mediaType);
} finally {
  await ai.disposeArtifact(speech.artifact);
}
