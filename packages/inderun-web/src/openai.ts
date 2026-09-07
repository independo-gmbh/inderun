/**
 * Provider-specific entry point for the OpenAI Responses adapter.
 *
 * Kept out of the unified SDK index (`@independo/inderun-web`) so the top-level
 * surface stays provider-agnostic. Import from `@independo/inderun-web/openai`
 * when registering the adapter manually; most browser apps should use
 * `createIndeRunWeb` from the main entry point instead.
 *
 * Browser apps must point `endpointUrl` at a same-origin proxy that holds the
 * API key server-side. Provider credentials must never reach the browser.
 */

/**
 * The adapter and its options. Runs Mode 1 and Mode 2 against any
 * OpenAI-Responses-compatible endpoint, not just OpenAI's own.
 */
export {
  OpenAIResponsesProvider,
  type OpenAIProviderOptions,
  DEFAULT_OPENAI_RESPONSES_ENDPOINT
} from "./providers/openai/provider.js";
