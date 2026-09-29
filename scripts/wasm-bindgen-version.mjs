#!/usr/bin/env node
/**
 * Resolves the `wasm-bindgen` version pinned in `Cargo.lock`.
 *
 * The `wasm-bindgen` CLI and the `wasm-bindgen` crate agree on a schema version,
 * and the CLI rejects a `.wasm` produced by a crate it does not match -- so the
 * CLI version is not a free choice, it is whatever the lockfile resolved. Stating
 * it a second time in a workflow or an install hint means a dependency bump can
 * (and did, in #192) leave the two disagreeing, with the failure surfacing only
 * once CI runs wasm-bindgen. Reading it from the lockfile keeps one source.
 *
 * Parsed with a regex rather than a TOML dependency: this runs before
 * `pnpm install`, in a workflow step whose only tool is Node.
 *
 * Run directly (`node scripts/wasm-bindgen-version.mjs`) it prints the version,
 * which is how the workflows feed it to `cargo install` and the cache key.
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));

export function wasmBindgenVersion() {
  const lockfile = readFileSync(join(repoRoot, "Cargo.lock"), "utf8");
  const pin = /\[\[package\]\]\s*\nname = "wasm-bindgen"\nversion = "([^"]+)"/.exec(lockfile);
  if (!pin) {
    throw new Error("Cargo.lock does not resolve a wasm-bindgen version");
  }
  return pin[1];
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  process.stdout.write(`${wasmBindgenVersion()}\n`);
}
