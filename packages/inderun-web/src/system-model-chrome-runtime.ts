import {
  SystemModelRuntimeError,
  type SystemModelAvailability,
  type SystemModelGenerationInput,
  type SystemModelGenerationOutput,
  type SystemModelRuntime
} from "./system-model-runtime.js";

/**
 * Structural view of the Chrome/Edge Prompt API's `LanguageModel` global this runtime uses.
 *
 * Typed structurally (not imported from `@types/dom`) since the Prompt API is not yet part of
 * stable browser type definitions. See https://developer.chrome.com/docs/ai/prompt-api.
 */
export interface PromptApiLanguageModel {
  availability: (options?: Record<string, unknown>) => Promise<string>;
  create: (options?: Record<string, unknown>) => Promise<PromptApiSession>;
}

/** Structural view of a Prompt API session. */
export interface PromptApiSession {
  prompt: (input: string, options?: { signal?: AbortSignal }) => Promise<string>;
  destroy: () => void;
}

/**
 * Generation controls forwarded to `LanguageModel.availability()` and `LanguageModel.create()`.
 *
 * Chrome's docs require passing the same options to both calls, since availability can depend on
 * the requested configuration.
 */
export interface ChromePromptApiGenerationOptions {
  temperature?: number;
  topK?: number;
}

/**
 * Configuration for the Chrome Prompt API-backed system-model runtime.
 */
export interface ChromePromptApiRuntimeOptions {
  /** Generation controls passed to both `availability()` and `create()`. */
  generation?: ChromePromptApiGenerationOptions;
}

/**
 * Creates the default Web system-model runtime, backed by Chrome's built-in Prompt API
 * (`LanguageModel`).
 *
 * The browser owns model availability, download, and execution; this runtime never bundles or
 * fetches a model itself. When `LanguageModel` is not defined (unsupported browser, disabled
 * flag, or origin trial not enrolled) the runtime reports itself unavailable instead of throwing,
 * so routing degrades to an explainable `capability_unavailable` rejection.
 *
 * @param options - Generation control overrides forwarded to the Prompt API.
 */
export function createChromePromptApiRuntime(
  options: ChromePromptApiRuntimeOptions = {}
): SystemModelRuntime {
  const promptOptions = toPromptApiOptions(options.generation);

  return {
    async availability(): Promise<SystemModelAvailability> {
      const languageModel = getLanguageModel();
      if (!languageModel) {
        return {
          kind: "api_missing",
          reason:
            "system model API missing: 'LanguageModel' is not defined on this browser. See https://developer.chrome.com/docs/ai/prompt-api."
        };
      }

      let result: string;
      try {
        result = await languageModel.availability(promptOptions);
      } catch (err) {
        return mapAvailabilityError(err);
      }

      switch (result) {
        case "available":
          return { kind: "available" };
        case "downloadable":
          return {
            kind: "downloadable",
            reason: "model downloadable: the model can be downloaded but is not installed yet."
          };
        case "downloading":
          return {
            kind: "downloading",
            reason: "model downloading: the model is currently downloading."
          };
        case "unavailable":
          return {
            kind: "model_unavailable",
            reason: "model unavailable: the model is unavailable on this device."
          };
        default:
          return {
            kind: "unavailable",
            reason: `provider temporarily unavailable: unrecognized availability result '${result}'.`
          };
      }
    },

    async generate(
      input: SystemModelGenerationInput,
      signal?: AbortSignal
    ): Promise<SystemModelGenerationOutput> {
      const languageModel = getLanguageModel();
      if (!languageModel) {
        throw new SystemModelRuntimeError(
          "capability",
          "system model API missing: 'LanguageModel' is not defined on this browser."
        );
      }

      let session: PromptApiSession;
      try {
        session = await languageModel.create({ ...promptOptions, signal });
      } catch (err) {
        throw mapGenerateError(err);
      }

      try {
        const text = await session.prompt(
          toPromptText(input),
          signal !== undefined ? { signal } : {}
        );
        return { text };
      } catch (err) {
        throw mapGenerateError(err);
      } finally {
        session.destroy();
      }
    }
  };
}

function getLanguageModel(): PromptApiLanguageModel | undefined {
  return (globalThis as { LanguageModel?: PromptApiLanguageModel }).LanguageModel;
}

function toPromptApiOptions(
  generation?: ChromePromptApiGenerationOptions
): Record<string, unknown> {
  const promptOptions: Record<string, unknown> = {};
  if (generation?.temperature !== undefined) promptOptions.temperature = generation.temperature;
  if (generation?.topK !== undefined) promptOptions.topK = generation.topK;
  return promptOptions;
}

function toPromptText(input: SystemModelGenerationInput): string {
  return input.messages.map((message) => `${message.role}: ${message.content}`).join("\n");
}

function mapAvailabilityError(error: unknown): SystemModelAvailability {
  const name = getDomExceptionName(error);
  if (name === "NotSupportedError") {
    return {
      kind: "browser_unsupported",
      reason: `browser unsupported: ${getErrorMessage(error)}`
    };
  }
  if (name === "NotAllowedError" || name === "SecurityError") {
    return {
      kind: "feature_disabled",
      reason: `browser feature disabled: ${getErrorMessage(error)}`
    };
  }
  return {
    kind: "unavailable",
    reason: `provider temporarily unavailable: ${getErrorMessage(error)}`
  };
}

function mapGenerateError(error: unknown): SystemModelRuntimeError {
  if (error instanceof SystemModelRuntimeError) return error;

  const name = getDomExceptionName(error);
  switch (name) {
    case "NotSupportedError":
      return new SystemModelRuntimeError(
        "capability",
        `hardware unsupported: ${getErrorMessage(error)}`,
        error
      );
    case "NotAllowedError":
    case "SecurityError":
      return new SystemModelRuntimeError(
        "capability",
        `browser feature disabled: ${getErrorMessage(error)}`,
        error
      );
    case "QuotaExceededError":
      return new SystemModelRuntimeError(
        "unavailable",
        `storage or network constraints: ${getErrorMessage(error)}`,
        error
      );
    case "AbortError":
      return new SystemModelRuntimeError(
        "timeout",
        `system model generation was aborted: ${getErrorMessage(error)}`,
        error
      );
    default:
      return new SystemModelRuntimeError(
        "internal",
        `system model generation failed: ${getErrorMessage(error)}`,
        error
      );
  }
}

function getDomExceptionName(error: unknown): string | undefined {
  return error instanceof DOMException ? error.name : undefined;
}

function getErrorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
