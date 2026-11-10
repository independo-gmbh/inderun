import { createIndeRunCapacitor } from "@independo/capacitor-inderun";

// Speech providers register only when asked for. `systemSpeech` is AVSpeechSynthesizer on iOS and
// TextToSpeech on Android; the app never receives audio bytes.
const ai = createIndeRunCapacitor({ systemSpeech: true });

const playback = await ai.speak({
  text: "Your appointment has been rescheduled.",
  locale: "en-US",
  execution: { privacy: "local_required" }
});

// Stop early with `cancel()`; no audio plays after it returns.
setTimeout(() => void playback.cancel(), 1500);

// `result` settles when playback ends or is stopped.
const result = await playback.result;
console.log(result.outcome, result.provenance?.providerId);
