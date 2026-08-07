#!/usr/bin/env node
// Fails the build if the shared Rust route-core WASM asset was not emitted into
// dist/assets/. This is the regression gate for issue #109: the WASM route
// planner previously loaded via a variable specifier + `/* @vite-ignore */`,
// which Vite/Rollup cannot statically resolve — the import silently became a
// bare, unresolvable specifier at runtime, and (crucially) `@vite-ignore`
// suppresses the "cannot be statically analyzed" warning too, so a build-time
// `onwarn` hook cannot catch this class of regression. Checking the actual
// emitted output is the only reliable gate.
import { readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";

const assetsDir = fileURLToPath(new URL("../dist/assets", import.meta.url));

let entries;
try {
  entries = readdirSync(assetsDir);
} catch (error) {
  console.error(`[verify-wasm-route-planner-bundled] Could not read ${assetsDir}:`, error.message);
  process.exit(1);
}

const wasmAsset = entries.find((name) => /^inderun_route_core_bg[.-].*\.wasm$/.test(name));
const jsChunk = entries.find((name) => /^inderun_route_core[.-].*\.js$/.test(name));

if (!wasmAsset || !jsChunk) {
  console.error(
    "[verify-wasm-route-planner-bundled] Expected the shared route-core WASM asset " +
      `and JS chunk in ${assetsDir}, but found none matching. This means the WASM route ` +
      "planner's dynamic import regressed to something Vite cannot statically resolve " +
      "(see issue #109) — the app would silently fall back to the TS route planner at runtime."
  );
  process.exit(1);
}

console.log(
  `[verify-wasm-route-planner-bundled] OK: found ${wasmAsset} and ${jsChunk} in dist/assets.`
);
