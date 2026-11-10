import { createIndeRunCapacitor, type IndeRunError } from "@independo/capacitor-inderun";

// iOS and Android register the platform's on-device model; no cloud provider is configured.
const ai = createIndeRunCapacitor();

type RejectedProvider = { providerId: string; reasons: { code: string }[] };

const byId = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const prompt = byId<HTMLTextAreaElement>("prompt");
const button = byId<HTMLButtonElement>("run");
const capabilityList = byId<HTMLUListElement>("capabilities");
const output = byId<HTMLPreElement>("output");

function addItem(list: HTMLElement, text: string) {
  const item = document.createElement("li");
  item.textContent = text;
  list.append(item);
}

async function showCapabilities() {
  capabilityList.replaceChildren();
  for (const provider of await ai.checkCapabilities()) {
    const { available, reason } = provider.capabilities;
    addItem(
      capabilityList,
      `${provider.providerId} (${provider.descriptor.type}): ` +
        (available ? "available" : `unavailable: ${reason ?? "no reason reported"}`)
    );
  }
}

async function runLocalOnly() {
  button.disabled = true;
  output.textContent = "Running…";
  try {
    const result = await ai.run({
      schemaVersion: "1.0",
      task: { kind: "text_to_text" },
      prompt: prompt.value,
      constraints: { privacy: "local_required" }
    });
    output.textContent = [
      result.output.text,
      "",
      `provider: ${result.provenance?.providerId}`,
      `locality: ${result.provenance?.locality}`
    ].join("\n");
  } catch (error) {
    const refusal = error as IndeRunError;
    const rejected = (refusal.details?.rejectedProviders ?? []) as RejectedProvider[];
    output.textContent = [
      `Refused: ${refusal.message}`,
      ...rejected.map(
        (entry) => `- ${entry.providerId}: ${entry.reasons.map((r) => r.code).join(", ")}`
      )
    ].join("\n");
  } finally {
    button.disabled = false;
  }
}

button.addEventListener("click", () => void runLocalOnly());
void showCapabilities();
