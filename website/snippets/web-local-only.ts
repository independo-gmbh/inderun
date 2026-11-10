import { createIndeRunWeb, generateText } from "@independo/inderun-web";

// Registers the browser-managed model (Chrome's Prompt API). In a browser
// without it there is no eligible local provider, so the call is refused.
const inderun = createIndeRunWeb({ systemModel: {} });

const { text, provenance } = await generateText(inderun, {
  prompt: "Rewrite in plain language: Your appointment has been rescheduled.",
  execution: { privacy: "local_required" }
});

console.log(text, provenance?.providerId);
