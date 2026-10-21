import {
  createBrowserHostServices,
  type CreateBrowserHostServicesOptions
} from "./core/browser-host.js";
import { IndeRun } from "./core/engine.js";
import type { ModelProfiles } from "./core/model-profiles.js";
import { OnnxRuntimeWebProvider, type OnnxProviderOptions } from "./providers/onnx/provider.js";
import {
  DEFAULT_OPENAI_RESPONSES_ENDPOINT,
  OpenAIResponsesProvider,
  type OpenAIProviderOptions
} from "./providers/openai/provider.js";
import { ProviderRegistry } from "./core/registry.js";
import {
  SystemModelWebProvider,
  type SystemModelProviderOptions
} from "./providers/system-model/provider.js";

/**
 * Configuration for the default Web SDK factory.
 */
export interface CreateIndeRunWebOptions {
  /**
   * OpenAI Responses provider configuration registered by the factory. One target is
   * registered per entry in `models`, with id `<id>:<model>` (`id` defaults to
   * `"openai"`), so model profiles can list each model separately.
   */
  openAI?: OpenAIFactoryOptions;
  /**
   * Web ONNX Runtime provider configuration registered by the factory, for developer-supplied
   * local models. Registering it is what makes `constraints.privacy = "local_required"` routable.
   */
  onnx?: OnnxProviderOptions;
  /**
   * Web system-model provider configuration registered by the factory, for browser-managed
   * on-device models (for example Chrome's Prompt API). Unlike `onnx`, this provider takes no
   * developer-supplied model: the browser owns model availability, download, and execution.
   */
  systemModel?: SystemModelProviderOptions;
  /**
   * Optional browser host service overrides.
   */
  hostServices?: CreateBrowserHostServicesOptions;
  /**
   * Explicit opt-in for calling a public Responses endpoint directly from this Web SDK factory —
   * OpenAI's or OpenRouter's — with browser-held credentials.
   *
   * Browser apps should leave this unset and use a proxy endpoint with `openAI.auth = "none"` instead.
   * Direct calls can expose credentials to client-side code and are appropriate only for controlled
   * non-production environments.
   */
  allowDirectOpenAIEndpoint?: boolean;
  /**
   * Named model profiles requests can route within. Each maps a profile name to an
   * ordered list of target ids, for example `{ smart: ["openai:gpt-5.2"] }`.
   */
  modelProfiles?: ModelProfiles;
}

/**
 * OpenAI options for {@link createIndeRunWeb}: the provider options with `models` in
 * place of the single `model`. The first model is not special; every model becomes
 * its own target.
 */
export type OpenAIFactoryOptions = Omit<OpenAIProviderOptions, "model"> & {
  /** OpenAI model ids to register, one target each. */
  models: readonly string[];
};

/**
 * Creates a Web SDK instance with the configured providers registered.
 *
 * Pass `openAI` for cloud execution, `onnx` for developer-supplied local models, `systemModel` for
 * browser-managed on-device models, or any combination to let routing choose between them; at
 * least one is required.
 *
 * Use `openAI.auth = "none"` with a proxy endpoint for production browser apps so the OpenAI API key never ships
 * to the client. Direct OpenAI calls require `allowDirectOpenAIEndpoint` and should resolve credentials through
 * `authContextRef` and `SecureStorageService`.
 *
 * @param options - Provider configuration and optional host service overrides.
 */
export function createIndeRunWeb(options: CreateIndeRunWebOptions): IndeRun {
  if (!options.openAI && !options.onnx && !options.systemModel) {
    throw new Error(
      "createIndeRunWeb requires at least one provider configuration (openAI, onnx, and/or systemModel)."
    );
  }

  const registry = new ProviderRegistry();

  if (options.openAI) {
    assertSafeOpenAIEndpoint(options.openAI, options.allowDirectOpenAIEndpoint);
    const { models, id = "openai", ...shared } = options.openAI;
    if (models.length === 0) {
      throw new Error("createIndeRunWeb requires openAI.models to list at least one model.");
    }
    for (const model of models) {
      registry.register(new OpenAIResponsesProvider({ ...shared, id: `${id}:${model}`, model }));
    }
  }

  if (options.onnx) {
    registry.register(new OnnxRuntimeWebProvider(options.onnx));
  }

  if (options.systemModel) {
    registry.register(new SystemModelWebProvider(options.systemModel));
  }

  return new IndeRun(registry, createBrowserHostServices(options.hostServices), {
    ...(options.modelProfiles ? { modelProfiles: options.modelProfiles } : {})
  });
}

function assertSafeOpenAIEndpoint(
  openAI: OpenAIFactoryOptions,
  allowDirectOpenAIEndpoint?: boolean
): void {
  const endpointUrl = openAI.endpointUrl ?? DEFAULT_OPENAI_RESPONSES_ENDPOINT;
  const auth = openAI.auth ?? "authContextRef";
  const isDirectPublicEndpoint = isPublicResponsesEndpoint(endpointUrl);

  if (isDirectPublicEndpoint && auth !== "none" && !allowDirectOpenAIEndpoint) {
    throw new Error(
      'createIndeRunWeb is proxy-first for browser safety. Configure openAI.endpointUrl to a server-side proxy with auth: "none", or set allowDirectOpenAIEndpoint: true for controlled direct OpenAI calls.'
    );
  }
}

function isPublicResponsesEndpoint(endpointUrl: string): boolean {
  let parsed: URL;
  try {
    parsed = new URL(endpointUrl);
  } catch {
    return false;
  }

  const pathname = parsed.pathname.replace(/\/+$/u, "");
  const endpoint = `${parsed.hostname.toLowerCase()}${pathname}`;
  return PUBLIC_RESPONSES_ENDPOINTS.includes(endpoint);
}

/**
 * Hosted Responses endpoints whose credentials are developer-owned API keys, which the
 * factory keeps out of browser code unless `allowDirectOpenAIEndpoint` says otherwise.
 */
const PUBLIC_RESPONSES_ENDPOINTS = [
  "api.openai.com/v1/responses",
  "openrouter.ai/api/v1/responses"
];
