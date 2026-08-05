import {
  createBrowserHostServices,
  type CreateBrowserHostServicesOptions
} from "./browser-host.js";
import { IndeRun } from "./engine.js";
import { OnnxRuntimeWebProvider, type OnnxProviderOptions } from "./onnx-provider.js";
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
  openAI?: OpenAIProviderOptions;
  /**
   * Web ONNX Runtime provider configuration registered by the factory, for developer-supplied
   * local models. Registering it is what makes `constraints.privacy = "local_required"` routable.
   */
  onnx?: OnnxProviderOptions;
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
 * Creates a Web SDK instance with the configured providers registered.
 *
 * Pass `openAI` for cloud execution, `onnx` for developer-supplied local models, or both to let
 * routing choose between them; at least one is required.
 *
 * Use `openAI.auth = "none"` with a proxy endpoint for production browser apps so the OpenAI API key never ships
 * to the client. Direct OpenAI calls require `allowDirectOpenAIEndpoint` and should resolve credentials through
 * `authContextRef` and `SecureStorageService`.
 *
 * @param options - Provider configuration and optional host service overrides.
 */
export function createIndeRunWeb(options: CreateIndeRunWebOptions): IndeRun {
  if (!options.openAI && !options.onnx) {
    throw new Error(
      "createIndeRunWeb requires at least one provider configuration (openAI and/or onnx)."
    );
  }

  const registry = new ProviderRegistry();

  if (options.openAI) {
    assertSafeOpenAIEndpoint(options.openAI, options.allowDirectOpenAIEndpoint);
    registry.register(new OpenAIResponsesProvider(options.openAI));
  }

  if (options.onnx) {
    registry.register(new OnnxRuntimeWebProvider(options.onnx));
  }

  return new IndeRun(registry, createBrowserHostServices(options.hostServices));
}

function assertSafeOpenAIEndpoint(
  openAI: OpenAIProviderOptions,
  allowDirectOpenAIEndpoint?: boolean
): void {
  const endpointUrl = openAI.endpointUrl ?? DEFAULT_OPENAI_RESPONSES_ENDPOINT;
  const auth = openAI.auth ?? "authContextRef";
  const isDirectOpenAIEndpoint = isOpenAIResponsesEndpoint(endpointUrl);

  if (isDirectOpenAIEndpoint && auth !== "none" && !allowDirectOpenAIEndpoint) {
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
