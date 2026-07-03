import {
  createBrowserHostServices,
  type CreateBrowserHostServicesOptions
} from "./browser-host.js";
import { IndeRun } from "./engine.js";
import {
  DEFAULT_OPENAI_RESPONSES_ENDPOINT,
  OpenAIResponsesProvider,
  type OpenAIProviderOptions
} from "./openai-provider.js";
import { ProviderRegistry } from "./registry.js";

/**
 * Configuration for the default Web SDK factory.
 */
export interface CreateIndeRunWebOptions {
  /**
   * OpenAI Responses provider configuration registered by the factory.
   */
  openAI: OpenAIProviderOptions;
  /**
   * Optional browser host service overrides.
   */
  hostServices?: CreateBrowserHostServicesOptions;
  /**
   * Explicit opt-in for calling the public OpenAI endpoint directly from this Web SDK factory.
   *
   * Browser apps should leave this unset and use a proxy endpoint with `openAI.auth = "none"` instead.
   * Direct calls can expose credentials to client-side code and are appropriate only for controlled
   * non-production environments.
   */
  allowDirectOpenAIEndpoint?: boolean;
}

/**
 * Creates a Web SDK instance with the OpenAI Responses provider registered.
 *
 * Use `openAI.auth = "none"` with a proxy endpoint for production browser apps so the OpenAI API key never ships
 * to the client. Direct OpenAI calls require `allowDirectOpenAIEndpoint` and should resolve credentials through
 * `authContextRef` and `SecureStorageService`.
 *
 * @param options - OpenAI provider configuration and optional host service overrides.
 */
export function createIndeRunWeb(options: CreateIndeRunWebOptions): IndeRun {
  assertSafeOpenAIEndpoint(options);

  const registry = new ProviderRegistry();
  registry.register(new OpenAIResponsesProvider(options.openAI));

  return new IndeRun(registry, createBrowserHostServices(options.hostServices));
}

function assertSafeOpenAIEndpoint(options: CreateIndeRunWebOptions): void {
  const endpointUrl = options.openAI.endpointUrl ?? DEFAULT_OPENAI_RESPONSES_ENDPOINT;
  const auth = options.openAI.auth ?? "authContextRef";
  const isDirectOpenAIEndpoint = isOpenAIResponsesEndpoint(endpointUrl);

  if (isDirectOpenAIEndpoint && auth !== "none" && !options.allowDirectOpenAIEndpoint) {
    throw new Error(
      'createIndeRunWeb is proxy-first for browser safety. Configure openAI.endpointUrl to a server-side proxy with auth: "none", or set allowDirectOpenAIEndpoint: true for controlled direct OpenAI calls.'
    );
  }
}

function isOpenAIResponsesEndpoint(endpointUrl: string): boolean {
  let parsed: URL;
  try {
    parsed = new URL(endpointUrl);
  } catch {
    return false;
  }

  const pathname = parsed.pathname.replace(/\/+$/u, "");
  return parsed.hostname.toLowerCase() === "api.openai.com" && pathname === "/v1/responses";
}
