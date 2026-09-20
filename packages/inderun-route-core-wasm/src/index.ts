/**
 * Thin loader around the wasm-bindgen output of the shared Rust route planner
 * (`rust/inderun-route-core`), published as `@independo/inderun-route-core-wasm`.
 *
 * The Web SDK has no JavaScript fallback planner, so this is the only thing that
 * turns a request plus a host capability snapshot into a route plan on the web.
 * The bindings under `generated/` are built by `pnpm build:wasm` and are not
 * committed; the package's `prepublishOnly` refuses to publish without them.
 */

type WasmGeneratedModule = {
  default?: (moduleOrPath?: unknown) => Promise<unknown>;
  plan_route_json?: (inputJson: string) => string;
};

let initialized = false;
let generatedModule: WasmGeneratedModule | null = null;

/**
 * Loads and initializes the WASM module. Idempotent: later calls are no-ops, so
 * callers may invoke it defensively.
 *
 * @param moduleOrPath - Where to fetch the `.wasm` bytes from, for hosts that
 * cannot use the bindings' default resolution (a custom bundler layout, a
 * non-standard asset URL). Omit it to let wasm-bindgen resolve them.
 */
export async function initSharedCore(moduleOrPath?: unknown): Promise<void> {
  if (initialized) {
    return;
  }

  const mod = await importGeneratedModule();
  if (typeof mod.default === "function") {
    await mod.default(moduleOrPath === undefined ? undefined : { module_or_path: moduleOrPath });
  }

  generatedModule = mod;
  initialized = true;
}

/**
 * Plans a route, in and out as JSON so the Rust/JS boundary carries no structured
 * types. Initializes the module on first use.
 *
 * @param inputJson - A `RoutePlannerInput` (see `contracts/schemas/route-planner-input.schema.json`).
 * @returns A `RoutePlan` (see `contracts/schemas/route-plan.schema.json`).
 * @throws If the generated bindings are missing — build them with `pnpm build:wasm`.
 */
export async function planRouteJson(inputJson: string): Promise<string> {
  if (!initialized) {
    await initSharedCore();
  }

  if (!generatedModule?.plan_route_json) {
    throw new Error("Generated WASM route planner bindings are not available.");
  }

  return generatedModule.plan_route_json(inputJson);
}

async function importGeneratedModule(): Promise<WasmGeneratedModule> {
  try {
    // Literal specifier (not a variable) so bundlers can statically resolve and
    // chunk it — a variable specifier defeats bundler analysis (see issue #109).
    return (await import("../generated/inderun_route_core.js")) as WasmGeneratedModule;
  } catch (error) {
    throw new Error(
      "Generated WASM bindings are missing. Build them with wasm-pack before using @independo/inderun-route-core-wasm.",
      { cause: error }
    );
  }
}
