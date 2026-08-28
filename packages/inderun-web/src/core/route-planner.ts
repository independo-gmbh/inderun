import type {
  RoutePlan as SharedPlannerRoutePlan,
  RoutePlannerInput as SharedPlannerInput,
  TaskRequest
} from "@independo/inderun-contracts";
import type { HostServices } from "./host.js";
import type {
  ProviderAdapter,
  ProviderDescriptor,
  ProviderDynamicCapabilities
} from "./provider.js";

export type { SharedPlannerInput, SharedPlannerRoutePlan };

/**
 * Interaction mode the caller is requesting a route for. Passed to the shared
 * planner, which rejects providers that cannot satisfy it.
 */
export type InteractionMode = NonNullable<SharedPlannerInput["interactionMode"]>;

/**
 * Minimal shape of the shared route-core module (the WASM wrapper), used to
 * plan routes via JSON in/JSON out. `initSharedCore` initializes the WASM
 * bindings when present.
 */
export interface SharedPlannerModule {
  initSharedCore?: () => Promise<void>;
  planRouteJson: (inputJson: string) => string | Promise<string>;
}

/**
 * Coarse, privacy-safe reason the WASM planner produced no route plan. Used
 * only for observability (telemetry/logging) — callers still fall back to
 * local selection regardless of which reason fired.
 */
export type WasmUnavailableReason =
  "import_failed" | "invalid_module_shape" | "init_failed" | "plan_failed";

/**
 * Result of a {@link RoutePlanner} attempt. `routePlan` is `null` when the
 * planner could not produce a plan, in which case `source` is `"unavailable"`
 * and `unavailableReason` narrows down why, so callers can log/emit telemetry
 * instead of silently swapping planners.
 */
export interface PlannerOutcome {
  routePlan: SharedPlannerRoutePlan | null;
  source: "wasm" | "unavailable";
  unavailableReason?: WasmUnavailableReason;
}

/**
 * Strategy that turns planner input into a deterministic route plan, or an
 * "unavailable" outcome (callers then fall back to local selection).
 */
export interface RoutePlanner {
  planRoute(input: SharedPlannerInput): Promise<PlannerOutcome>;
}

/**
 * A provider paired with the descriptor/capability projection the shared route
 * planner consumes.
 */
export interface ProviderRuntimeSnapshot {
  provider: ProviderAdapter;
  descriptor: SharedPlannerInput["providers"][number]["descriptor"];
  capabilities: SharedPlannerInput["providers"][number]["capabilities"];
}

/**
 * {@link RoutePlanner} backed by the Rust route core compiled to WASM. The
 * module specifier is a static literal (not configurable) so bundlers such as
 * Vite/webpack/Rollup can statically resolve and chunk it — a variable
 * specifier defeats bundler analysis and silently never loads in the browser
 * (see issue #109). The module is imported lazily and memoized; if it cannot
 * be loaded, `planRoute` resolves an "unavailable" outcome so the engine can
 * fall back to local selection, and logs once via `console.warn` so the
 * degradation is never fully silent.
 */
export class WasmRoutePlanner implements RoutePlanner {
  private modulePromise?: Promise<SharedPlannerModule | null>;
  private loadFailureReason?: WasmUnavailableReason;
  private hasWarned = false;

  async planRoute(input: SharedPlannerInput): Promise<PlannerOutcome> {
    const module = await this.loadModule();
    if (!module) {
      const unavailableReason = this.loadFailureReason ?? "import_failed";
      this.warnOnce(unavailableReason);
      return { routePlan: null, source: "unavailable", unavailableReason };
    }

    try {
      const json = JSON.stringify(input);
      const result = await module.planRouteJson(json);
      return { routePlan: JSON.parse(result) as SharedPlannerRoutePlan, source: "wasm" };
    } catch (error) {
      this.warnOnce("plan_failed", error);
      return { routePlan: null, source: "unavailable", unavailableReason: "plan_failed" };
    }
  }

  private async loadModule(): Promise<SharedPlannerModule | null> {
    if (!this.modulePromise) {
      this.modulePromise = this.importModule();
    }
    return this.modulePromise;
  }

  private async importModule(): Promise<SharedPlannerModule | null> {
    let mod: SharedPlannerModule;
    try {
      mod = (await import("@independo/inderun-route-core-wasm")) as SharedPlannerModule;
    } catch (error) {
      this.loadFailureReason = "import_failed";
      this.warnOnce("import_failed", error);
      return null;
    }

    if (typeof mod.planRouteJson !== "function") {
      this.loadFailureReason = "invalid_module_shape";
      this.warnOnce("invalid_module_shape");
      return null;
    }

    if (mod.initSharedCore) {
      try {
        await mod.initSharedCore();
      } catch (error) {
        this.loadFailureReason = "init_failed";
        this.warnOnce("init_failed", error);
        return null;
      }
    }

    return mod;
  }

  private warnOnce(reason: WasmUnavailableReason, error?: unknown): void {
    if (this.hasWarned) {
      return;
    }
    this.hasWarned = true;
    console.warn(
      `[IndeRun] WASM route planner unavailable (${reason}); falling back to local route selection.`,
      error
    );
  }
}

/**
 * Describes each provider and evaluates its dynamic capabilities against the
 * host, returning snapshots sorted by provider id for deterministic planning.
 */
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
        capabilities: toSharedPlannerCapabilities(capabilities, descriptor, provider)
      };
    })
  );

  return snapshots.sort((left, right) => left.descriptor.id.localeCompare(right.descriptor.id));
}

/**
 * Assembles the normalized {@link SharedPlannerInput} the shared route core
 * consumes, applying default constraints/preferences and the current network
 * state.
 */
export function buildSharedPlannerInput(
  request: TaskRequest,
  snapshots: ProviderRuntimeSnapshot[],
  networkOnline: boolean,
  interactionMode: InteractionMode = "run"
): SharedPlannerInput {
  const constraints = request.constraints ?? {};
  const preferences = request.preferences ?? {};

  return {
    task: {
      kind: request.task.kind
    },
    interactionMode,
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
      run: descriptor.supports.run,
      streaming: descriptor.supports.streaming
    },
    cancel: descriptor.cancel,
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

/**
 * Projects the dynamic capability snapshot for the planner.
 *
 * `stream()` being absent from the adapter is folded in here rather than
 * filtered out downstream: an adapter that declares `supports.streaming` but
 * never implemented the method is not streaming-capable, and saying so as a
 * planner-visible reason is what lets the route explanation name the provider
 * instead of silently dropping it.
 */
function toSharedPlannerCapabilities(
  capabilities: ProviderDynamicCapabilities,
  descriptor: ProviderDescriptor,
  provider: ProviderAdapter
): SharedPlannerInput["providers"][number]["capabilities"] {
  const declaresStreaming = capabilities.streamingAvailable ?? descriptor.supports.streaming;
  const implementsStream = typeof provider.stream === "function";
  const streamingAvailable = declaresStreaming && implementsStream;
  const streamingUnavailableReason =
    capabilities.streamingUnavailableReason ??
    (declaresStreaming && !implementsStream
      ? `Provider '${descriptor.id}' declares streaming but does not implement stream().`
      : undefined);

  return {
    available: capabilities.available,
    ...(capabilities.reason ? { reason: capabilities.reason } : {}),
    streamingAvailable,
    ...(!streamingAvailable && streamingUnavailableReason ? { streamingUnavailableReason } : {}),
    ...(capabilities.cancellationAvailable !== undefined
      ? { cancellationAvailable: capabilities.cancellationAvailable }
      : {})
  };
}
