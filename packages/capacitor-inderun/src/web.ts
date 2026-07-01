import type { TaskResult } from "@independo/inderun-contracts";
import { WebPlugin } from "@capacitor/core";
import { createIndeRunWeb, createUnavailable, toIndeRunException } from "@independo/inderun-web";
import type { ConfigureOptions, IndeRunCapacitorPlugin } from "./definitions.js";
import type { TaskRequest } from "@independo/inderun-contracts";
import type { IndeRun } from "@independo/inderun-web";

export class IndeRunWeb extends WebPlugin implements IndeRunCapacitorPlugin {
  private engine: IndeRun | null = null;

  async configure(options?: ConfigureOptions): Promise<void> {
    if (!options?.openAI) {
      throw createUnavailable(
        "Capacitor web execution requires OpenAI provider registration. Configure with openAI bootstrap options before calling run(request)."
      ).toContractError();
    }

    try {
      const webOptions: {
        openAI: {
          model: string;
          endpointUrl?: string;
          auth?: "authContextRef" | "none";
          authContextRef?: string;
          timeoutMs?: number;
        };
        allowDirectOpenAIEndpoint?: boolean;
      } = {
        openAI: compactOpenAIOptions(options)
      };

      if (options.allowDirectOpenAIEndpoint !== undefined) {
        webOptions.allowDirectOpenAIEndpoint = options.allowDirectOpenAIEndpoint;
      }

      this.engine = createIndeRunWeb(webOptions);
    } catch (error) {
      throw toIndeRunException(error).toContractError();
    }
  }

  async run(request: TaskRequest): Promise<TaskResult> {
    if (!this.engine) {
      throw createUnavailable(
        "Capacitor IndeRun has not been configured. Configure providers before calling run(request)."
      ).toContractError();
    }

    try {
      return await this.engine.run(request);
    } catch (error) {
      throw toIndeRunException(error).toContractError();
    }
  }
}

function compactOpenAIOptions(options: ConfigureOptions): {
  model: string;
  endpointUrl?: string;
  auth?: "authContextRef" | "none";
  authContextRef?: string;
  timeoutMs?: number;
} {
  const openAI = options.openAI!;
  const result: {
    model: string;
    endpointUrl?: string;
    auth?: "authContextRef" | "none";
    authContextRef?: string;
    timeoutMs?: number;
  } = {
    model: openAI.model
  };

  if (openAI.endpointUrl !== undefined) {
    result.endpointUrl = openAI.endpointUrl;
  }
  if (openAI.auth !== undefined) {
    result.auth = openAI.auth;
  }
  if (openAI.authContextRef !== undefined) {
    result.authContextRef = openAI.authContextRef;
  }
  if (openAI.timeoutMs !== undefined) {
    result.timeoutMs = openAI.timeoutMs;
  }

  return result;
}
