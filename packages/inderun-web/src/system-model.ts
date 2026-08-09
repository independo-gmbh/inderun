/**
 * Provider-specific entry point for the Web member of the system-model provider family.
 *
 * Kept out of the unified SDK index (`@independo/inderun-web`) so the top-level
 * surface stays provider-agnostic. Import from `@independo/inderun-web/system-model`
 * when registering the adapter manually or when implementing a custom
 * `SystemModelRuntime`; most browser apps should pass `systemModel` to
 * `createIndeRunWeb` from the main entry point instead.
 */
export {
  DEFAULT_SYSTEM_MODEL_WEB_PROVIDER_ID,
  SystemModelWebProvider,
  type SystemModelProviderOptions
} from "./system-model-provider.js";

export {
  SystemModelRuntimeError,
  createFixtureSystemModelRuntime,
  type FixtureSystemModelRuntimeOptions,
  type SystemModelAvailability,
  type SystemModelAvailabilityKind,
  type SystemModelGenerationInput,
  type SystemModelGenerationOutput,
  type SystemModelPromptMessage,
  type SystemModelRuntime,
  type SystemModelRuntimeErrorKind
} from "./system-model-runtime.js";

export {
  createChromePromptApiRuntime,
  type ChromePromptApiGenerationOptions,
  type ChromePromptApiRuntimeOptions,
  type PromptApiLanguageModel,
  type PromptApiSession
} from "./system-model-chrome-runtime.js";
