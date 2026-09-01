#!/usr/bin/env node
/**
 * Verifies the committed route-core XCFramework against its provenance manifest
 * and against what an Apple binary is allowed to look like.
 *
 * This exists because the artifact in git is an executable that SwiftPM consumers
 * run, and until now the only evidence tying it to the reviewed Rust source was
 * that some file under the framework directory had been touched in the same
 * change. That is not evidence. This script checks instead that:
 *
 *   1. the manifest was produced by the pinned toolchain (`rust-toolchain.toml`);
 *   2. every declared source input still hashes to what the manifest recorded, so
 *      the binary belongs to *this* revision of the crate, lockfile, header, and
 *      build scripts;
 *   3. every file inside the XCFramework hashes to what the manifest recorded, so
 *      no slice was swapped, added, or dropped after the build;
 *   4. each slice really is what it claims: architectures, platform, deployment
 *      target, exported FFI symbols, install name, and dynamic dependencies.
 *
 * What it deliberately does not do is rebuild and diff bytes. Rust builds are not
 * byte-reproducible, so that check would fail for reasons unrelated to integrity.
 * The behavioural half of the question is answered separately, by rebuilding from
 * source in CI and re-running the Swift suite against the result.
 *
 * Exit status is the point: non-zero means do not ship this artifact.
 */
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { pinnedRustcVersion, pinnedToolchain } from "./rust-toolchain.mjs";
import {
  artifactHashes,
  manifestPath,
  readManifest,
  sourceHashes,
  xcframeworkPath
} from "./route-core-apple-provenance.mjs";

const SYMBOLS = ["_inderun_plan_route_json", "_inderun_free_string"];
const INSTALL_NAME = "@rpath/InderunRouteCoreFFI.framework/InderunRouteCoreFFI";

// Mach-O platform ids, as reported by LC_BUILD_VERSION.
const MACOS = 1;
const IOS = 2;
const IOS_SIMULATOR = 7;

// Only libSystem is expected. Anything else means the framework acquired a
// dependency a consumer app would have to satisfy, which for a self-contained
// planner core is a defect rather than a detail.
const ALLOWED_DYLIBS = new Set([INSTALL_NAME, "/usr/lib/libSystem.B.dylib"]);

const slices = [
  { id: "ios-arm64", archs: ["arm64"], platform: IOS, minos: "16.0" },
  {
    id: "ios-arm64_x86_64-simulator",
    archs: ["arm64", "x86_64"],
    platform: IOS_SIMULATOR,
    minos: "16.0"
  },
  { id: "macos-arm64_x86_64", archs: ["arm64", "x86_64"], platform: MACOS, minos: "14.0" }
];

const failures = [];

function fail(message) {
  failures.push(message);
}

function capture(command, args) {
  const result = spawnSync(command, args, { encoding: "utf8" });
  if (result.error?.code === "ENOENT") {
    fail(`'${command}' was not found on PATH; the Xcode command line tools are required.`);
    return "";
  }
  if (result.status !== 0) {
    fail(`'${command} ${args.join(" ")}' failed: ${(result.stderr || "").trim()}`);
    return "";
  }
  return result.stdout;
}

/** Reports added, removed, and changed keys rather than just "did not match". */
function diffHashes(label, expected, actual) {
  for (const [path, hash] of Object.entries(expected)) {
    if (!(path in actual)) {
      fail(`${label}: '${path}' is recorded in the manifest but missing from the tree.`);
    } else if (actual[path] !== hash) {
      fail(
        `${label}: '${path}' does not match the manifest (recorded ${hash}, found ${actual[path]}).`
      );
    }
  }
  for (const path of Object.keys(actual)) {
    if (!(path in expected)) {
      fail(`${label}: '${path}' is present but not recorded in the manifest.`);
    }
  }
}

function verifySlice(slice) {
  const framework = join(xcframeworkPath, slice.id, "InderunRouteCoreFFI.framework");
  const binary = join(framework, "InderunRouteCoreFFI");
  if (!existsSync(binary)) {
    fail(`${slice.id}: framework binary is missing.`);
    return;
  }

  const plist = join(framework, "Info.plist");
  capture("plutil", ["-lint", plist]);

  const archs = capture("lipo", ["-archs", binary]).trim().split(/\s+/).filter(Boolean).sort();
  const expectedArchs = [...slice.archs].sort();
  if (archs.join(",") !== expectedArchs.join(",")) {
    fail(`${slice.id}: architectures are [${archs}], expected [${expectedArchs}].`);
  }

  // One LC_BUILD_VERSION per architecture, so every slice of a fat binary is checked.
  const loadCommands = capture("otool", ["-l", "-arch", "all", binary]);
  const platforms = [...loadCommands.matchAll(/^\s*platform\s+(\d+)$/gm)].map((match) =>
    Number(match[1])
  );
  const minimums = [...loadCommands.matchAll(/^\s*minos\s+([\d.]+)$/gm)].map((match) => match[1]);
  if (platforms.length !== slice.archs.length) {
    fail(
      `${slice.id}: expected ${slice.archs.length} LC_BUILD_VERSION command(s), found ${platforms.length}.`
    );
  }
  for (const platform of platforms) {
    if (platform !== slice.platform) {
      fail(`${slice.id}: Mach-O platform is ${platform}, expected ${slice.platform}.`);
    }
  }
  for (const minimum of minimums) {
    if (minimum !== slice.minos) {
      fail(`${slice.id}: deployment target is ${minimum}, expected ${slice.minos}.`);
    }
  }

  const installName = capture("otool", ["-D", "-arch", "all", binary])
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.startsWith("@rpath/"));
  for (const name of installName) {
    if (name !== INSTALL_NAME) {
      fail(`${slice.id}: install name is '${name}', expected '${INSTALL_NAME}'.`);
    }
  }
  if (installName.length === 0) {
    fail(`${slice.id}: no @rpath install name; the framework would not be found at runtime.`);
  }

  // For a fat binary otool repeats the listing per architecture, each introduced
  // by a "<path> (architecture <arch>):" header that is not a dependency.
  const linked = capture("otool", ["-L", "-arch", "all", binary])
    .split("\n")
    .filter((line) => line.startsWith("\t"))
    .map((line) => line.trim().split(" ")[0])
    .filter((line) => line.length > 0);
  for (const dylib of linked) {
    if (!ALLOWED_DYLIBS.has(dylib)) {
      fail(`${slice.id}: unexpected dynamic dependency '${dylib}'.`);
    }
  }

  // -gU: external, defined. The FFI surface is exactly two functions, and a slice
  // that exports neither would link but fail at the first call.
  const exported = capture("nm", ["-gU", "-arch", "all", binary]);
  for (const symbol of SYMBOLS) {
    if (!new RegExp(`\\b${symbol}\\b`).test(exported)) {
      fail(`${slice.id}: does not export ${symbol}.`);
    }
  }
}

if (!existsSync(manifestPath)) {
  console.error(
    `[verify-route-core-apple] No provenance manifest at ${manifestPath}. Run 'pnpm build:route-core-apple'.`
  );
  process.exit(1);
}

const manifest = readManifest();
if (manifest.manifestVersion !== 1) {
  console.error(
    `[verify-route-core-apple] Unsupported manifest version ${manifest.manifestVersion}; this verifier understands 1.`
  );
  process.exit(1);
}

const toolchain = pinnedToolchain();
if (manifest.toolchain !== toolchain) {
  fail(
    `The artifact was built with toolchain '${manifest.toolchain}' but rust-toolchain.toml pins '${toolchain}'.`
  );
}
try {
  const rustcVersion = pinnedRustcVersion(toolchain);
  if (manifest.rustcVersion !== rustcVersion) {
    fail(
      `The artifact records '${manifest.rustcVersion}' but the pinned toolchain is '${rustcVersion}'.`
    );
  }
} catch (error) {
  fail(`${error.message}. Install it with 'rustup toolchain install ${toolchain}'.`);
}

// After a rebuild the artifact hashes legitimately differ -- Rust builds are not
// byte-reproducible -- so a post-rebuild run checks the shape of what was just
// produced, not its identity against the committed manifest.
const slicesOnly = process.argv.includes("--slices-only");
if (!slicesOnly) {
  try {
    diffHashes("source", manifest.sources, sourceHashes());
  } catch (error) {
    // Reported rather than thrown, so an untracked input reads as a verification
    // failure with a reason instead of a stack trace.
    fail(error.message);
  }
  diffHashes("artifact", manifest.files, artifactHashes());
}
slices.forEach(verifySlice);

if (failures.length > 0) {
  console.error("[verify-route-core-apple] The committed XCFramework did not verify:\n");
  for (const failure of failures) {
    console.error(`  - ${failure}`);
  }
  console.error(
    "\nIf the Rust route core changed, rebuild and commit the artifact:\n  pnpm build:route-core-apple\n"
  );
  process.exit(1);
}

console.log(
  slicesOnly
    ? `[verify-route-core-apple] Every slice of ${manifest.artifact} is well-formed.`
    : `[verify-route-core-apple] ${manifest.artifact} matches its provenance manifest (${manifest.rustcVersion}).`
);
