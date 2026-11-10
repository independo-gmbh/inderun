#!/usr/bin/env node
/**
 * Builds the Rust route core for the Apple platforms and packages it into
 * `ios/IndeRun/Frameworks/InderunRouteCoreFFI.xcframework` (the planner, features off) and
 * `InderunSpeechTextFFI.xcframework` (the German speech text normalizer, the `speech-text`
 * feature), which `Package.swift` links as binaryTargets. That XCFramework is how the Swift SDK reaches the
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
import { artifacts, provenanceManifest, writeManifest } from "./route-core-apple-provenance.mjs";

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const headersDir = join(repoRoot, "rust", "inderun-route-core", "include");
const stagingDir = join(repoRoot, "target", "apple");

/**
 * Two XCFrameworks from one crate. The framework, the module Swift imports, and the binaryTarget in
 * Package.swift all have to carry the artifact's one name. The speech text build has its own cargo
 * target directory: the same crate with different features would otherwise overwrite the planner's
 * libraries, and cargo would rebuild both every time.
 *
 * The two C modules never declare the same symbol (the speech one frees with its own
 * `inderun_speech_text_free`), or a Swift target that saw both would find an ambiguity.
 */
const builds = [
  {
    ...artifacts[0],
    bundleId: "app.independo.inderun.routecore",
    header: "inderun_route_core.h",
    targetDir: "target",
    cargoArgs: ["--no-default-features"],
    cargoFeatures: "none"
  },
  {
    ...artifacts[1],
    bundleId: "app.independo.inderun.speechtext",
    header: "inderun_speech_text.h",
    targetDir: join("target", "speech-text"),
    cargoArgs: ["--no-default-features", "--features", "speech-text"],
    cargoFeatures: "speech-text"
  }
];
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

function libraryFor(build, rustTarget) {
  return join(repoRoot, build.targetDir, rustTarget, PROFILE, DYLIB);
}

function infoPlist(build, slice) {
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
  <string>${build.name}</string>
  <key>CFBundleIdentifier</key>
  <string>${build.bundleId}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${build.name}</string>
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
function buildFramework(build, slice) {
  const framework = join(stagingDir, build.name, slice.name, `${build.name}.framework`);
  rmSync(framework, { recursive: true, force: true });
  mkdirSync(join(framework, "Headers"), { recursive: true });
  mkdirSync(join(framework, "Modules"), { recursive: true });

  const binary = join(framework, build.name);
  if (slice.rustTargets.length === 1) {
    copyFileSync(libraryFor(build, slice.rustTargets[0]), binary);
  } else {
    run("lipo", [
      "-create",
      ...slice.rustTargets.map((target) => libraryFor(build, target)),
      "-output",
      binary
    ]);
  }

  // Local symbols only: the exported FFI entry points must survive. Done here with
  // the Xcode tools rather than through the cargo profile, whose rustc-driven strip
  // yields a LINKEDIT layout the Xcode 27 linker rejects (see Cargo.toml).
  run("strip", ["-x", binary]);

  // Rust emits an install name of the raw dylib path. dyld resolves the framework
  // through the embedding app's rpath, so it has to say so.
  run("install_name_tool", ["-id", `@rpath/${build.name}.framework/${build.name}`, binary]);

  copyFileSync(join(headersDir, build.header), join(framework, "Headers", build.header));
  writeFileSync(
    join(framework, "Modules", "module.modulemap"),
    `framework module ${build.name} {\n    umbrella header "${build.header}"\n    export *\n}\n`
  );
  writeFileSync(join(framework, "Info.plist"), infoPlist(build, slice));
  return framework;
}

/**
 * True when the XCFramework on disk is newer than every library cargo just
 * produced and newer than the packaged header -- i.e. nothing it was built from
 * has changed since.
 */
function xcframeworkIsCurrent(build) {
  const xcframework = build.xcframeworkPath;
  if (!existsSync(xcframework)) {
    return false;
  }
  const builtAt = statSync(join(xcframework, "Info.plist")).mtimeMs;
  const inputs = [
    ...rustTargets.map((target) => libraryFor(build, target)),
    join(headersDir, build.header)
  ];
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

const force = process.argv.includes("--force");

for (const build of builds) {
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
        rustTarget,
        "--target-dir",
        build.targetDir,
        ...build.cargoArgs
      ],
      { env }
    );
  }

  // --force is what CI uses: skipping on an mtime comparison is a convenience for
  // local iteration, not a statement about what the artifact contains, and a
  // verification run must never be handed a package it did not just produce.
  if (!force && xcframeworkIsCurrent(build)) {
    console.log(
      `[build-route-core-apple] ${build.name}.xcframework already matches the built libraries; skipping packaging.`
    );
    continue;
  }

  const createArgs = ["-create-xcframework"];
  for (const slice of slices) {
    createArgs.push("-framework", buildFramework(build, slice));
  }

  // xcodebuild refuses to write over an existing XCFramework.
  rmSync(build.xcframeworkPath, { recursive: true, force: true });
  mkdirSync(dirname(build.xcframeworkPath), { recursive: true });
  createArgs.push("-output", build.xcframeworkPath);
  run("xcodebuild", createArgs);

  // The manifest is what makes the committed binary checkable: it records the exact
  // compiler plus content hashes of every source the artifact was built from, so CI
  // can prove the executable being shipped belongs to the source under review
  // without needing byte-reproducible builds. See scripts/verify-route-core-apple.mjs.
  writeManifest(
    build,
    provenanceManifest(build, { rustcVersion, toolchain, cargoFeatures: build.cargoFeatures })
  );

  console.log(`[build-route-core-apple] Wrote ${build.xcframeworkPath}`);
  console.log(`[build-route-core-apple] Wrote ${build.manifestPath}`);
}
