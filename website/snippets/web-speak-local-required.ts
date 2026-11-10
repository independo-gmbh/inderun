import { createIndeRunWeb, speak } from "@independo/inderun-web";

const inderun = createIndeRunWeb({ systemSpeech: {} });

try {
  await speak(inderun, {
    text: "Ihr Termin wurde verschoben.",
    locale: "de-DE",
    execution: { privacy: "local_required" }
  });
} catch (error) {
  // Always refused in a browser: it cannot prove that a voice stays on the device.
  console.warn(error);
}
