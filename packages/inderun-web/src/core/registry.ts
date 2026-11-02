import type { ProviderAdapter } from "./provider.js";

/** How a provider takes part in preparation (ADR 019). */
export interface ProviderRegistrationOptions {
  /**
   * Lets `prepare()`, explicit or on the first run, start this provider's platform download.
   * Defaults to `false`: a download can use mobile data, so it is the application's decision.
   * Off, a call can still allow one with `prepare({ allowDownload: true })`.
   */
  autoDownload?: boolean;
}

/**
 * Registry class that holds and manages all active ProviderAdapter instances.
 * Loaded adapters are queried by the Router to choose appropriate routes.
 */
export class ProviderRegistry {
  private providers = new Map<string, ProviderAdapter>();
  private options = new Map<string, ProviderRegistrationOptions>();

  /**
   * Registers a provider adapter in the registry.
   * @param provider - The provider adapter instance to register.
   * @param options - How the provider takes part in preparation.
   * @throws {Error} If the provider does not have a valid ID.
   * @throws {Error} If another provider is already registered with the same ID.
   */
  register(provider: ProviderAdapter, options: ProviderRegistrationOptions = {}): void {
    const descriptor = provider.describe();
    if (!descriptor.id) {
      throw new Error("Provider must have a non-empty ID.");
    }
    if (this.providers.has(descriptor.id)) {
      throw new Error(`Provider with ID "${descriptor.id}" is already registered.`);
    }
    this.providers.set(descriptor.id, provider);
    this.options.set(descriptor.id, options);
  }

  /** Whether `prepare()` may start this provider's platform download on its own. */
  allowsAutoDownload(id: string): boolean {
    return this.options.get(id)?.autoDownload === true;
  }

  /**
   * Retrieves a registered provider by its ID.
   * @param id - Unique provider identifier.
   */
  get(id: string): ProviderAdapter | undefined {
    return this.providers.get(id);
  }

  /**
   * Returns a list of all registered provider adapters.
   */
  list(): ProviderAdapter[] {
    return Array.from(this.providers.values());
  }

  /**
   * Clears all registered providers.
   */
  clear(): void {
    this.providers.clear();
    this.options.clear();
  }
}
