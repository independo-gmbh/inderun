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

type SpeechTextGeneratedModule = {
  default?: (moduleOrPath?: unknown) => Promise<unknown>;
  normalize_speech_text?: (text: string, locale: string) => string;
};

let initialized = false;
let generatedModule: WasmGeneratedModule | null = null;
let speechText: SpeechTextGeneratedModule | null = null;
let speechTextLoading: Promise<SpeechTextGeneratedModule> | null = null;

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

/**
 * Loads and initializes the speech text module, a second WASM module that only
 * `normalizeSpeechText` needs, so apps that just route never download it. Idempotent, and
 * independent of `initSharedCore`; call it only to control where the bytes come from.
 *
 * @param moduleOrPath - Same meaning as for `initSharedCore`, for the speech module's
 * `inderun_speech_text_bg.wasm`.
 */
export async function initSpeechText(moduleOrPath?: unknown): Promise<void> {
  await loadSpeechText(moduleOrPath);
}

/**
 * Rewrites speech text into its spoken form for `locale`: numbers, dates, times, abbreviations
 * and the like written out in words. Only German (`de`, `de-DE`, `de-AT`, ...) is rewritten; any
 * other locale returns the text unchanged. Never fails on input. Initializes the speech text
 * module on first use; `planRouteJson` never loads it.
 *
 * @throws If the generated bindings are missing or predate this export — build them with
 * `pnpm build:wasm`.
 */
export async function normalizeSpeechText(text: string, locale: string): Promise<string> {
  const mod = await loadSpeechText();
  if (!mod.normalize_speech_text) {
    throw new Error("Generated WASM speech text bindings are not available.");
  }
  return mod.normalize_speech_text(text, locale);
}

function loadSpeechText(moduleOrPath?: unknown): Promise<SpeechTextGeneratedModule> {
  if (speechText !== null) {
    return Promise.resolve(speechText);
  }
  speechTextLoading ??= (async () => {
    try {
      const mod = await importSpeechTextModule();
      if (typeof mod.default === "function") {
        await mod.default(
          moduleOrPath === undefined ? undefined : { module_or_path: moduleOrPath }
        );
      }
      speechText = mod;
      return mod;
    } finally {
      speechTextLoading = null;
    }
  })();
  return speechTextLoading;
}

async function importSpeechTextModule(): Promise<SpeechTextGeneratedModule> {
  try {
    // Literal specifier, like `importGeneratedModule`, so bundlers chunk it separately.
    return (await import("../generated/inderun_speech_text.js")) as SpeechTextGeneratedModule;
  } catch (error) {
    throw new Error(
      "Generated WASM speech text bindings are missing. Build them with `pnpm build:wasm` before using normalizeSpeechText.",
      { cause: error }
    );
  }
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
