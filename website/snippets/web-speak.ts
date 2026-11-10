import { createIndeRunWeb, listVoices, speak } from "@independo/inderun-web";

const inderun = createIndeRunWeb({ systemSpeech: {} });

const voices = await listVoices(inderun, { locale: "de-DE" });
console.log(voices.map((voice) => voice.name));

const playback = await speak(inderun, { text: "Ihr Termin wurde verschoben.", locale: "de-DE" });
document.querySelector("#stop")?.addEventListener("click", () => playback.cancel());

const { outcome, provenance } = await playback.result;
console.log(outcome, provenance?.locality); // locality: "unknown" in a browser
