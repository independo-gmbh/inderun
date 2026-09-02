import { readFile } from "node:fs/promises";
import { beforeEach } from "vitest";
import { initSharedCore } from "@independo/inderun-route-core-wasm";

/**
 * Boots the real shared Rust route core for every suite, so the tests exercise
 * the planner that ships rather than a stand-in.
 *
 * The bytes are passed to `initSharedCore` explicitly instead of letting
 * wasm-bindgen's `--target web` init fetch them: Node cannot `fetch()` a
 * `file://` URL, and suites that stub `global.fetch` for their own provider
 * tests would otherwise intercept the WASM request. `route-planner.wasm.test.ts`
 * still covers the browser fetch path on purpose.
 *
 * `initSharedCore` is idempotent, but the wrapper's "already initialized" flag
 * is module-registry state, so it is re-run per test file (and after any
 * `vi.resetModules()`) via `beforeEach`.
 */
const WASM_PATH = new URL(
  "../../../inderun-route-core-wasm/generated/inderun_route_core_bg.wasm",
  import.meta.url
);

const wasmBytes = await readFile(WASM_PATH);

await initSharedCore(wasmBytes);

beforeEach(async () => {
  await initSharedCore(wasmBytes);
});
