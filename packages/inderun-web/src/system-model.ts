/**
 * Provider-specific entry point for the Web member of the system-model provider family.
 *
 * Kept out of the unified SDK index (`@independo/inderun-web`) so the top-level
 * surface stays provider-agnostic. Import from `@independo/inderun-web/system-model`
 * when registering the adapter manually or when implementing a custom
 * `SystemModelRuntime`; most browser apps should pass `systemModel` to
 * `createIndeRunWeb` from the main entry point instead.
 *
 * "System model" means a model the browser itself manages, so availability is a
 * richer answer than a boolean: it may be present, downloadable, mid-download, or
 * blocked for a browser, device, or policy reason. The provider flattens every
 * non-available state into one route rejection and carries the detail as text.
 */

/** The adapter itself, plus the default id the router plans against. */
export {
  DEFAULT_SYSTEM_MODEL_WEB_PROVIDER_ID,
  SystemModelWebProvider,
  type SystemModelProviderOptions
} from "./providers/system-model/provider.js";

/**
 * The runtime seam. The provider delegates generation to a `SystemModelRuntime`,
 * so an app can target a different browser API, or use
 * `createFixtureSystemModelRuntime()` in demos and tests where no system model
 * exists.
 */
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
} from "./providers/system-model/runtime.js";

/** The default runtime, backed by Chrome's built-in Prompt API. */
export {
  createChromePromptApiRuntime,
  type ChromePromptApiGenerationOptions,
  type ChromePromptApiRuntimeOptions,
  type PromptApiLanguageModel,
  type PromptApiSession
} from "./providers/system-model/chrome-runtime.js";
