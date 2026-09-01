#!/usr/bin/env node
/**
 * Builds the Rust route core for the Apple platforms and packages it into
 * `ios/IndeRun/Frameworks/InderunRouteCoreFFI.xcframework`, which `Package.swift`
 * links as a binaryTarget. That XCFramework is how the Swift SDK reaches the
 * shared planner; there is no second planner behind it.
 *
 * Unlike the WASM bindings, the XCFramework is committed to git. SwiftPM has no
 * publish step -- consumers resolve `.package(url:from:)` against a git tag, so
 * whatever the tag contains is what they get, and an artifact injected at release
 * time would leave every prerelease tag unbuildable. Committing it is also what
 * lets `swift build` work on a plain checkout with no Rust toolchain. CI rebuilds
 * it from source before running `swift test`, so the tests never depend on the
 * committed copy being current (see docs/ci.md).
 *
 * Dynamic frameworks, not static archives: a `staticlib` is a bundle of object
 * files with nothing eliminated until the consumer links, so it weighs ~17 MB per
 * slice -- 87 MB of binary rewritten in git on every planner change. The same
 * code as a `cdylib` is ~400 KB per slice, because the linker drops the parts of
 * std and serde_json the two FFI entry points never reach. A framework (rather
 * than a bare dylib) is also what Xcode knows how to embed and sign.
 *
 * Freshness is delegated to cargo for the same reason as the WASM build: cargo
 * fingerprints every effective input (sources, workspace manifest, lockfile,
 * features, rustc version), and re-deriving that list here would skip rebuilds
 * after, say, a dependency bump. Only the packaging step is skipped, keyed off
 * the libraries cargo just produced.
 */
import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { pinnedRustcPath, pinnedRustcVersion, pinnedToolchain } from "./rust-toolchain.mjs";
import { manifestPath, provenanceManifest, writeManifest } from "./route-core-apple-provenance.mjs";

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const headersDir = join(repoRoot, "rust", "inderun-route-core", "include");
const stagingDir = join(repoRoot, "target", "apple");

// The framework, the module Swift imports, and the binaryTarget in Package.swift
// all have to carry this one name.
const NAME = "InderunRouteCoreFFI";
const BUNDLE_ID = "app.independo.inderun.routecore";
const xcframework = join(repoRoot, "ios", "IndeRun", "Frameworks", `${NAME}.xcframework`);
const DYLIB = "libinderun_route_core.dylib";
const PROFILE = "apple";

// Deployment targets must match Package.swift's platform minimums, or the linker
// warns that the objects were built for a different OS version.
const IOS_MIN = "16.0";
const MACOS_MIN = "14.0";

/**
 * One XCFramework slice each. A slice with several Rust targets is `lipo`d into a
 * single fat binary first; xcodebuild rejects two libraries for the same
 * platform+variant, so this grouping is not optional.
 */
const slices = [
  { name: "ios", rustTargets: ["aarch64-apple-ios"], platforms: ["iPhoneOS"] },
  {
    name: "ios-simulator",
    rustTargets: ["aarch64-apple-ios-sim", "x86_64-apple-ios"],
    platforms: ["iPhoneSimulator"]
  },
  {
    name: "macos",
    rustTargets: ["aarch64-apple-darwin", "x86_64-apple-darwin"],
    platforms: ["MacOSX"]
  }
];

const rustTargets = slices.flatMap((slice) => slice.rustTargets);

const toolchain = pinnedToolchain();

const TOOLCHAIN_HINT =
  "The Apple route core is required to build and test the Swift SDK. Install the\n" +
  "pinned Rust toolchain, its Apple targets, and the Xcode command line tools, then retry:\n" +
  `  rustup toolchain install ${toolchain}\n` +
  `  rustup target add --toolchain ${toolchain} ${rustTargets.join(" ")}\n` +
  "  xcode-select --install\n" +
  "See ios/IndeRun/README.md.";

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { cwd: repoRoot, stdio: "inherit", ...options });
  if (result.error?.code === "ENOENT") {
    console.error(
      `\n[build-route-core-apple] '${command}' was not found on PATH.\n${TOOLCHAIN_HINT}`
    );
    process.exit(1);
  }
  if (result.status !== 0) {
    console.error(
      `\n[build-route-core-apple] '${command} ${args.join(" ")}' failed.\n${TOOLCHAIN_HINT}`
    );
    process.exit(result.status ?? 1);
  }
}

function libraryFor(rustTarget) {
  return join(repoRoot, "target", rustTarget, PROFILE, DYLIB);
}

function infoPlist(slice) {
  const platforms = slice.platforms
    .map((platform) => `    <string>${platform}</string>`)
    .join("\n");
  const minimum =
    slice.name === "macos"
      ? `  <key>LSMinimumSystemVersion</key>\n  <string>${MACOS_MIN}</string>`
      : `  <key>MinimumOSVersion</key>\n  <string>${IOS_MIN}</string>`;
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${NAME}</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
${platforms}
  </array>
${minimum}
</dict>
</plist>
`;
}

/**
 * Assembles a flat framework bundle around the slice's binary and returns its
 * path. Flat (rather than the versioned macOS layout) throughout: xcodebuild
 * accepts it for every platform, and one layout is one thing to get right.
 */
function buildFramework(slice) {
  const framework = join(stagingDir, slice.name, `${NAME}.framework`);
  rmSync(framework, { recursive: true, force: true });
  mkdirSync(join(framework, "Headers"), { recursive: true });
  mkdirSync(join(framework, "Modules"), { recursive: true });

  const binary = join(framework, NAME);
  if (slice.rustTargets.length === 1) {
    copyFileSync(libraryFor(slice.rustTargets[0]), binary);
  } else {
    run("lipo", ["-create", ...slice.rustTargets.map(libraryFor), "-output", binary]);
  }

  // Rust emits an install name of the raw dylib path. dyld resolves the framework
  // through the embedding app's rpath, so it has to say so.
  run("install_name_tool", ["-id", `@rpath/${NAME}.framework/${NAME}`, binary]);

  copyFileSync(
    join(headersDir, "inderun_route_core.h"),
    join(framework, "Headers", "inderun_route_core.h")
  );
  writeFileSync(
    join(framework, "Modules", "module.modulemap"),
    `framework module ${NAME} {\n    umbrella header "inderun_route_core.h"\n    export *\n}\n`
  );
  writeFileSync(join(framework, "Info.plist"), infoPlist(slice));
  return framework;
}

/**
 * True when the XCFramework on disk is newer than every library cargo just
 * produced and newer than the packaged header -- i.e. nothing it was built from
 * has changed since.
 */
function xcframeworkIsCurrent() {
  if (!existsSync(xcframework)) {
    return false;
  }
  const builtAt = statSync(join(xcframework, "Info.plist")).mtimeMs;
  const inputs = [...rustTargets.map(libraryFor), join(headersDir, "inderun_route_core.h")];
  return inputs.every((input) => existsSync(input) && statSync(input).mtimeMs < builtAt);
}

let rustcPath;
let rustcVersion;
try {
  // Resolved explicitly so the build cannot pick up whatever rustc happens to be
  // first on PATH: a Homebrew rust install shadows rustup's shim.
  rustcPath = pinnedRustcPath(toolchain);
  rustcVersion = pinnedRustcVersion(toolchain);
} catch (error) {
  console.error(`\n[build-route-core-apple] ${error.message}\n${TOOLCHAIN_HINT}`);
  process.exit(1);
}

const env = {
  ...process.env,
  RUSTC: rustcPath,
  IPHONEOS_DEPLOYMENT_TARGET: IOS_MIN,
  MACOSX_DEPLOYMENT_TARGET: MACOS_MIN
};

for (const rustTarget of rustTargets) {
  run(
    "rustup",
    [
      "run",
      toolchain,
      "cargo",
      "build",
      "-p",
      "inderun_route_core",
      "--profile",
      PROFILE,
      "--target",
      rustTarget
    ],
    { env }
  );
}

// --force is what CI uses: skipping on an mtime comparison is a convenience for
// local iteration, not a statement about what the artifact contains, and a
// verification run must never be handed a package it did not just produce.
const force = process.argv.includes("--force");
if (!force && xcframeworkIsCurrent()) {
  console.log(
    "[build-route-core-apple] XCFramework already matches the built libraries; skipping packaging."
  );
  process.exit(0);
}

const createArgs = ["-create-xcframework"];
for (const slice of slices) {
  createArgs.push("-framework", buildFramework(slice));
}

// xcodebuild refuses to write over an existing XCFramework.
rmSync(xcframework, { recursive: true, force: true });
mkdirSync(dirname(xcframework), { recursive: true });
createArgs.push("-output", xcframework);
run("xcodebuild", createArgs);

// The manifest is what makes the committed binary checkable: it records the exact
// compiler plus content hashes of every source the artifact was built from, so CI
// can prove the executable being shipped belongs to the source under review
// without needing byte-reproducible builds. See scripts/verify-route-core-apple.mjs.
writeManifest(provenanceManifest({ rustcVersion, toolchain }));

console.log(`[build-route-core-apple] Wrote ${xcframework}`);
console.log(`[build-route-core-apple] Wrote ${manifestPath}`);
