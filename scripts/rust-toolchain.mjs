/**
 * Resolves the Rust toolchain pinned in `rust-toolchain.toml`.
 *
 * The scripts that produce shipped artifacts (the WASM bindings and the Apple
 * XCFramework) must not build with "whatever stable is today": the XCFramework is
 * committed, and its provenance manifest records the exact compiler that produced
 * it. Reading the pin from one file keeps that claim honest and keeps the version
 * from being restated per script and per workflow.
 *
 * Parsed with a regex rather than a TOML dependency: the file is ours, the shape
 * is one key, and this runs before any install step.
 */
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));

export function pinnedToolchain() {
  const manifest = readFileSync(join(repoRoot, "rust-toolchain.toml"), "utf8");
  const channel = /^\s*channel\s*=\s*"([^"]+)"/m.exec(manifest);
  if (!channel) {
    throw new Error("rust-toolchain.toml does not declare a channel");
  }
  return channel[1];
}

/**
 * The `rustc --version` string of the pinned toolchain, e.g.
 * "rustc 1.96.0 (ac68faa20 2026-05-25)". Recorded in the provenance manifest,
 * so it identifies the build, not just the channel name.
 */
export function pinnedRustcVersion(toolchain = pinnedToolchain()) {
  const result = spawnSync("rustup", ["run", toolchain, "rustc", "--version"], {
    encoding: "utf8"
  });
  if (result.error || result.status !== 0) {
    throw new Error(`Could not resolve rustc for toolchain '${toolchain}'`);
  }
  return result.stdout.trim();
}

/**
 * Absolute path to the pinned toolchain's rustc. Exported as RUSTC so the build
 * does not pick up whatever rustc happens to be first on PATH -- a Homebrew rust
 * install shadows rustup's shim and silently builds with a different compiler.
 */
export function pinnedRustcPath(toolchain = pinnedToolchain()) {
  const result = spawnSync("rustup", ["which", "rustc", "--toolchain", toolchain], {
    encoding: "utf8"
  });
  if (result.error || result.status !== 0) {
    throw new Error(`Could not resolve rustc path for toolchain '${toolchain}'`);
  }
  return result.stdout.trim();
}
