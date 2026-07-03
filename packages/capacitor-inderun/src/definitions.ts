import type { TaskRequest, TaskResult } from "@independo/inderun-contracts";

export interface OpenAIProviderOptions {
  model: string;
  endpointUrl?: string;
  auth?: "authContextRef" | "none";
  authContextRef?: string;
  timeoutMs?: number;
}

export interface ConfigureOptions {
  openAI?: OpenAIProviderOptions;
  allowDirectOpenAIEndpoint?: boolean;
}

export interface IndeRunCapacitorPlugin {
  configure(options?: ConfigureOptions): Promise<void>;
  run(request: TaskRequest): Promise<TaskResult>;
}
