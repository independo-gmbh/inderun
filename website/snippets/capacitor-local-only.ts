import { createIndeRunCapacitor } from "@independo/capacitor-inderun";

// iOS and Android register the platform's on-device model automatically.
// No cloud provider is configured, so no request can be routed to the cloud.
const ai = createIndeRunCapacitor();

try {
  const result = await ai.run({
    schemaVersion: "1.0",
    task: { kind: "text_to_text" },
    prompt: "Rewrite in plain language: Your appointment has been rescheduled.",
    constraints: { privacy: "local_required" }
  });
  console.log(result.output.text, result.provenance?.providerId);
} catch (error) {
  // No eligible on-device model (unsupported device, Apple Intelligence off,
  // Gemini Nano not downloaded, …): refused before execution, with reasons.
  console.warn(error);
}
