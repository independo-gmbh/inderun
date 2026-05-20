import type { ProviderAdapter } from "./provider.js";

/**
 * Registry class that holds and manages all active ProviderAdapter instances.
 * Loaded adapters are queried by the Router to choose appropriate routes.
 */
export class ProviderRegistry {
  private providers = new Map<string, ProviderAdapter>();

  /**
   * Registers a provider adapter in the registry.
   * @param provider - The provider adapter instance to register.
   * @throws {Error} If the provider does not have a valid ID.
   * @throws {Error} If another provider is already registered with the same ID.
   */
  register(provider: ProviderAdapter): void {
    const descriptor = provider.describe();
    if (!descriptor.id) {
      throw new Error("Provider must have a non-empty ID.");
    }
    if (this.providers.has(descriptor.id)) {
      throw new Error(`Provider with ID "${descriptor.id}" is already registered.`);
    }
    this.providers.set(descriptor.id, provider);
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
  }
}
