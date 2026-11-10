import { createIndeRunCapacitor, type IndeRunError } from "@independo/capacitor-inderun";

const ai = createIndeRunCapacitor();

try {
  const result = await ai.run({
    schemaVersion: "1.0",
    task: { kind: "text_to_text" },
    prompt: "Rewrite in plain language: Your appointment has been rescheduled.",
    constraints: { privacy: "local_required" }
  });
  console.log(result.output.text);
  console.log(result.provenance?.providerId, result.provenance?.locality); // locality: "on_device"
} catch (error) {
  const refusal = error as IndeRunError;
  if (refusal.errorClass === "CapabilityMismatch") {
    // Refused before anything ran. `details.rejectedProviders` lists each
    // registered provider and the reason codes it was skipped for.
    console.warn(refusal.message, refusal.details?.rejectedProviders);
  } else {
    throw error;
  }
}
