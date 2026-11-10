import { createIndeRunCapacitor } from "@independo/capacitor-inderun";

const ai = createIndeRunCapacitor(); // native iOS / Android
const capabilities = await ai.checkCapabilities();

const result = await ai.run({
  schemaVersion: "1.0",
  task: { kind: "text_to_text" },
  prompt: "Explain this in plain language.",
  constraints: {
    privacy: "local_required"
  }
});

console.log(capabilities, result.provenance);
