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
    await mod.default(
      moduleOrPath === undefined ? undefined : { module_or_path: moduleOrPath }
    );
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
    const specifier = "../generated/inderun_route_core.js";
    return (await import(specifier)) as WasmGeneratedModule;
  } catch (error) {
    throw new Error(
      "Generated WASM bindings are missing. Build them with wasm-pack before using @independo/inderun-route-core-wasm.",
      { cause: error }
    );
  }
}
