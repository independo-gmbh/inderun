import {
  validateIndeRunError,
  type IndeRunError,
  type TaskRequest,
  type TaskResult
} from "@independo/inderun-contracts";
import { registerPlugin } from "@capacitor/core";
import type {
  ConfigureOptions,
  IndeRunCapacitorPlugin as IndeRunCapacitorPluginContract,
  OpenAIProviderBootstrapOptions
} from "./definitions.js";

const IndeRunCapacitorNative = registerPlugin<IndeRunCapacitorPluginContract>("IndeRunCapacitor", {
  web: () => import("./web.js").then((module) => new module.IndeRunWeb())
});

function normalizePluginError(error: unknown): unknown {
  if (validateIndeRunError(error)) {
    return error;
  }

  if (
    typeof error === "object" &&
    error !== null &&
    "data" in error &&
    validateIndeRunError((error as { data?: unknown }).data)
  ) {
    return (error as { data: IndeRunError }).data;
  }

  return error;
}

export const IndeRunCapacitor: IndeRunCapacitorPluginContract = {
  async configure(options?: ConfigureOptions): Promise<void> {
    try {
      await IndeRunCapacitorNative.configure(options);
    } catch (error) {
      throw normalizePluginError(error);
    }
  },

  async run(request: TaskRequest): Promise<TaskResult> {
    try {
      return await IndeRunCapacitorNative.run(request);
    } catch (error) {
      throw normalizePluginError(error);
    }
  }
};

export interface IndeRunCapacitorInstance {
  run(request: TaskRequest): Promise<TaskResult>;
}

export function createIndeRunCapacitor(options?: ConfigureOptions): IndeRunCapacitorInstance {
  let configured: Promise<void> | null = null;

  function ensureConfigured(): Promise<void> {
    configured ??= IndeRunCapacitor.configure(options);
    return configured;
  }

  return {
    async run(request: TaskRequest): Promise<TaskResult> {
      await ensureConfigured();
      return IndeRunCapacitor.run(request);
    }
  };
}

export type {
  ConfigureOptions,
  IndeRunCapacitorPluginContract as IndeRunCapacitorPlugin,
  OpenAIProviderBootstrapOptions,
  TaskRequest,
  TaskResult
};

export type * from "@independo/inderun-contracts";
