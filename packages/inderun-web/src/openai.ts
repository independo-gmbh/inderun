/**
 * Provider-specific entry point for the OpenAI Responses adapter.
 *
 * Kept out of the unified SDK index (`@independo/inderun-web`) so the top-level
 * surface stays provider-agnostic. Import from `@independo/inderun-web/openai`
 * when registering the adapter manually; most browser apps should use
 * `createIndeRunWeb` from the main entry point instead.
 */
export {
  OpenAIResponsesProvider,
  type OpenAIProviderOptions,
  DEFAULT_OPENAI_RESPONSES_ENDPOINT
} from "./openai-provider.js";
