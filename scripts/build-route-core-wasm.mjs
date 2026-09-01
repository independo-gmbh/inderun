#!/usr/bin/env node
/**
 * Builds the Rust route core to WASM and runs wasm-bindgen over it, producing
 * `packages/inderun-route-core-wasm/generated/`.
 *
 * The generated bindings are gitignored (see docs/ci.md), but they are no longer
 * optional: the Web SDK has a single planner, so a test run without them would
 * not be testing the planner that ships. This script is what `pnpm test:js` and
 * both CI workflows call, so there is one definition of the build.
 *
 * Freshness is delegated to cargo rather than re-derived here: cargo already
 * fingerprints every effective input (crate sources, the workspace manifest, the
 * lockfile, feature selection, and the rustc version itself), and a hand-rolled
 * mtime check over a subset of those inputs would hand back stale bindings the
 * moment an input outside that subset changed — a dependency bump, say. Cargo is
 * a no-op when nothing changed, so the only thing worth skipping is wasm-bindgen,
 * and that is keyed off the .wasm cargo just produced.
 */
import { spawnSync } from "node:child_process";
import { existsSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const outDir = join(repoRoot, "packages", "inderun-route-core-wasm", "generated");
const wasmInput = join(
  repoRoot,
  "target",
  "wasm32-unknown-unknown",
  "debug",
  "inderun_route_core.wasm"
);
const outputs = [
  join(outDir, "inderun_route_core.js"),
  join(outDir, "inderun_route_core_bg.wasm"),
  join(outDir, "inderun_route_core_bg.wasm.d.ts")
];

/**
 * True when every wasm-bindgen output already exists and is newer than the
 * `.wasm` cargo just produced — i.e. cargo did not rebuild and the bindings on
 * disk were generated from exactly this artifact.
 */
function bindingsMatchBuiltWasm() {
  if (!outputs.every((output) => existsSync(output))) {
    return false;
  }
  const builtAt = statSync(wasmInput).mtimeMs;
  const oldestOutput = Math.min(...outputs.map((output) => statSync(output).mtimeMs));
  return oldestOutput > builtAt;
}

function run(command, args, hint) {
  const result = spawnSync(command, args, { cwd: repoRoot, stdio: "inherit" });
  if (result.error?.code === "ENOENT") {
    console.error(`\n[build-route-core-wasm] '${command}' was not found on PATH.\n${hint}`);
    process.exit(1);
  }
  if (result.status !== 0) {
    console.error(`\n[build-route-core-wasm] '${command} ${args.join(" ")}' failed.\n${hint}`);
    process.exit(result.status ?? 1);
  }
}

const TOOLCHAIN_HINT =
  "The WASM route core is required to build and test the Web SDK. Install the Rust\n" +
  "toolchain and the wasm-bindgen CLI, then retry:\n" +
  "  rustup target add wasm32-unknown-unknown\n" +
  "  cargo install wasm-bindgen-cli --version 0.2.125 --locked\n" +
  "See packages/inderun-route-core-wasm/README.md.";

// `rustup which` pins RUSTC to the stable toolchain's binary so the build does not
// pick up whatever rustc happens to be first on PATH (mirrors the CI invocation).
const stableRustc = spawnSync("rustup", ["which", "rustc", "--toolchain", "stable"], {
  encoding: "utf8"
});
if (stableRustc.error?.code === "ENOENT" || stableRustc.status !== 0) {
  console.error(
    `\n[build-route-core-wasm] Could not resolve the stable Rust toolchain.\n${TOOLCHAIN_HINT}`
  );
  process.exit(1);
}

process.env.RUSTC = stableRustc.stdout.trim();
run(
  "rustup",
  [
    "run",
    "stable",
    "cargo",
    "build",
    "-p",
    "inderun_route_core",
    "--target",
    "wasm32-unknown-unknown"
  ],
  TOOLCHAIN_HINT
);
if (bindingsMatchBuiltWasm()) {
  console.log(
    "[build-route-core-wasm] Bindings already match the built WASM; skipping wasm-bindgen."
  );
  process.exit(0);
}

run(
  "wasm-bindgen",
  [wasmInput, "--target", "web", "--out-dir", outDir, "--out-name", "inderun_route_core"],
  TOOLCHAIN_HINT
);

console.log(`[build-route-core-wasm] Wrote bindings to ${outDir}`);
