import type {
  RoutePlan as SharedPlannerRoutePlan,
  RoutePlannerInput as SharedPlannerInput,
  TaskRequest
} from "@independo/inderun-contracts";
import type { HostServices } from "./host.js";
import type { ProviderAdapter, ProviderDescriptor, ProviderDynamicCapabilities } from "./provider.js";

export type {
  SharedPlannerInput,
  SharedPlannerRoutePlan
};

export interface SharedPlannerModule {
  initSharedCore?: () => Promise<void>;
  planRouteJson: (inputJson: string) => string | Promise<string>;
}

export interface RoutePlanner {
  planRoute(input: SharedPlannerInput): Promise<SharedPlannerRoutePlan | null>;
}

export interface ProviderRuntimeSnapshot {
  provider: ProviderAdapter;
  descriptor: SharedPlannerInput["providers"][number]["descriptor"];
  capabilities: SharedPlannerInput["providers"][number]["capabilities"];
}

const DEFAULT_WASM_SPECIFIER =
  "@independo/inderun-route-core-wasm";

export class WasmRoutePlanner implements RoutePlanner {
  private modulePromise?: Promise<SharedPlannerModule | null>;

  constructor(
    private readonly moduleSpecifier: string = DEFAULT_WASM_SPECIFIER
  ) {}

  async planRoute(
    input: SharedPlannerInput
  ): Promise<SharedPlannerRoutePlan | null> {
    const module = await this.loadModule();
    if (!module) {
      return null;
    }

    const json = JSON.stringify(input);
    const result = await module.planRouteJson(json);
    return JSON.parse(result) as SharedPlannerRoutePlan;
  }

  private async loadModule(): Promise<SharedPlannerModule | null> {
    if (!this.modulePromise) {
      this.modulePromise = this.importModule();
    }
    return this.modulePromise;
  }

  private async importModule(): Promise<SharedPlannerModule | null> {
    try {
      const mod = (await import(
        /* @vite-ignore */ this.moduleSpecifier
      )) as SharedPlannerModule;

      if (mod.initSharedCore) {
        await mod.initSharedCore();
      }

      if (typeof mod.planRouteJson !== "function") {
        return null;
      }

      return mod;
    } catch {
      return null;
    }
  }
}

export async function collectProviderRuntimeSnapshots(
  registryProviders: ProviderAdapter[],
  hostServices: HostServices
): Promise<ProviderRuntimeSnapshot[]> {
  const snapshots = await Promise.all(
    registryProviders.map(async (provider) => {
      const descriptor = provider.describe();
      const capabilities = await provider.capabilities(hostServices);

      return {
        provider,
        descriptor: toSharedPlannerDescriptor(descriptor),
        capabilities: toSharedPlannerCapabilities(capabilities)
      };
    })
  );

  return snapshots.sort((left, right) => left.descriptor.id.localeCompare(right.descriptor.id));
}

export function buildSharedPlannerInput(
  request: TaskRequest,
  snapshots: ProviderRuntimeSnapshot[],
  networkOnline: boolean
): SharedPlannerInput {
  const constraints = request.constraints ?? {};
  const preferences = request.preferences ?? {};

  return {
    task: {
      kind: request.task.kind
    },
    constraints: {
      privacy: constraints.privacy ?? "cloud_allowed",
      cloud: constraints.cloud ?? "allowed",
      networkOnline,
      ...(constraints.timeoutMs !== undefined ? { timeoutMs: constraints.timeoutMs } : {})
    },
    preferences: {
      optimizeFor: preferences.optimizeFor ?? "balanced"
    },
    providers: snapshots.map((snapshot) => ({
      descriptor: snapshot.descriptor,
      capabilities: snapshot.capabilities
    }))
  };
}

function toSharedPlannerDescriptor(
  descriptor: ProviderDescriptor
): SharedPlannerInput["providers"][number]["descriptor"] {
  return {
    id: descriptor.id,
    type: descriptor.type,
    supports: {
      run: descriptor.supports.run
    },
    tasks: descriptor.tasks,
    ...(descriptor.privacy
      ? {
          privacy: {
            dataLeavesDevice: descriptor.privacy.dataLeavesDevice,
            ...(descriptor.privacy.regions ? { regions: descriptor.privacy.regions } : {})
          }
        }
      : {})
  };
}

function toSharedPlannerCapabilities(
  capabilities: ProviderDynamicCapabilities
): SharedPlannerInput["providers"][number]["capabilities"] {
  return {
    available: capabilities.available,
    ...(capabilities.reason ? { reason: capabilities.reason } : {})
  };
}
