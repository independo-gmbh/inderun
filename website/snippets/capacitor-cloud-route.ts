import { createIndeRunCapacitor } from "@independo/capacitor-inderun";

// Credentials stay on your server; the app calls your proxy.
const ai = createIndeRunCapacitor({
  openAI: {
    models: ["your-model-id"],
    endpointUrl: "https://api.example.com/inderun/v1", // your OpenAI-compatible proxy
    auth: "none" // the proxy adds the API key server-side
  }
});

const result = await ai.run({
  schemaVersion: "1.0",
  task: { kind: "text_to_text" },
  prompt: "Rewrite in plain language: Your appointment has been rescheduled.",
  // Tries the device first; the configured cloud target stays eligible.
  constraints: { privacy: "local_preferred" }
});

console.log(result.provenance?.locality, result.provenance?.fallbackOccurred);
