import { createIndeRunCapacitor } from "@independo/capacitor-inderun";

const ai = createIndeRunCapacitor();

for (const provider of await ai.checkCapabilities()) {
  const { available, reason } = provider.capabilities;
  console.log(
    provider.providerId,
    provider.descriptor.type, // "local" or "cloud"
    available ? "available" : `unavailable: ${reason}`
  );
}
