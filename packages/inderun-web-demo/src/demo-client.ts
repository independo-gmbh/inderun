import type { TaskResult } from "@independo/inderun-contracts";
import { createIndeRunWeb } from "@independo/inderun-web";
import { getDemoModel, getDemoProxyEndpointUrl } from "./config";

const inderun = createIndeRunWeb({
  openAI: {
    model: getDemoModel(),
    endpointUrl: getDemoProxyEndpointUrl(),
    auth: "none"
  }
});

export async function runPrompt(
  prompt: string,
  executionMode: "on_device" | "cloud"
): Promise<TaskResult> {
  return inderun.run({
    schemaVersion: "1.0",
    task: { kind: "text_to_text" },
    prompt,
    constraints:
      executionMode === "on_device" ? { privacy: "local_required" } : { privacy: "cloud_required" }
  });
}

export function getDemoClientConfig(): { model: string; proxyEndpointUrl: string } {
  return {
    model: getDemoModel(),
    proxyEndpointUrl: getDemoProxyEndpointUrl()
  };
}
