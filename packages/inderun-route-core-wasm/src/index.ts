type WasmGeneratedModule = {
  default?: (moduleOrPath?: unknown) => Promise<unknown>;
  plan_route_json?: (inputJson: string) => string;
};

let initialized = false;
let generatedModule: WasmGeneratedModule | null = null;

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
