#!/usr/bin/env node
/**
 * Builds the Rust route core for Android.
 *
 * Two modes, because the Kotlin SDK reaches the shared planner two different
 * ways and both have to be real:
 *
 * - default: cross-compiles the four Android ABIs and stages them where
 *   `android/inderun-core/build.gradle.kts` registers them as a `jniLibs` source
 *   directory, so they land in the published AAR.
 * - `--host`: builds the same library for the machine running the build, for the
 *   JVM unit tests. Those tests call `System.loadLibrary` exactly like the
 *   Android runtime does; Gradle only puts the staging directory on
 *   `java.library.path`.
 *
 * Unlike the Apple XCFramework these artifacts are NOT committed. Android
 * consumers resolve `app.independo.inderun:inderun-core` from Maven Central,
 * where the AAR is built by CI from this script -- there is no equivalent of
 * SwiftPM's "the git tag is the artifact", so nothing is gained by tracking
 * binaries and the ~1.6 MB of churn per planner change is avoided.
 *
 * The JNI entry point is behind the crate's `jni-bindings` feature rather than a
 * `cfg(target_os = "android")` gate; see rust/inderun-route-core/Cargo.toml. That
 * is what lets the host build export the same symbol.
 *
 * Freshness is delegated to cargo, for the same reason as the WASM and Apple
 * builds: cargo fingerprints every effective input, and re-deriving that list
 * here would skip rebuilds after, say, a dependency bump.
 */
import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { pinnedRustcPath, pinnedToolchain } from "./rust-toolchain.mjs";

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));

const host = process.argv.includes("--host");

// Must match `minSdk` in android/inderun-core/build.gradle.kts: the NDK's clang
// wrappers are per-API-level, and linking against a newer one than the manifest
// declares fails at install time on older devices rather than at build time.
const MIN_SDK = 26;

const LIBRARY = "libinderun_route_core.so";
const NDK_VERSION = "27.2.12479018";

/**
 * `abi` is the jniLibs directory name Android expects; `clang` is the NDK
 * wrapper's prefix, which is not always the Rust target triple (armv7 gains an
 * `a`).
 */
const abis = [
  { abi: "arm64-v8a", rustTarget: "aarch64-linux-android", clang: "aarch64-linux-android" },
  { abi: "armeabi-v7a", rustTarget: "armv7-linux-androideabi", clang: "armv7a-linux-androideabi" },
  { abi: "x86_64", rustTarget: "x86_64-linux-android", clang: "x86_64-linux-android" },
  { abi: "x86", rustTarget: "i686-linux-android", clang: "i686-linux-android" }
];

/**
 * Where the ABI directories are written. Gradle passes `--out` so AGP owns the
 * location (it registers the directory as a generated jniLibs source); the
 * default only exists so the script is runnable by hand.
 */
const outFlag = process.argv.indexOf("--out");
const jniLibsDir =
  outFlag === -1 ? join(repoRoot, "target", "route-core-jnilibs") : process.argv[outFlag + 1];
const hostLibDir = join(repoRoot, "target", "route-core-host");

const toolchain = pinnedToolchain();

const TOOLCHAIN_HINT =
  "The route core is required to build and test the Android SDK; there is no second planner\n" +
  "behind it. Install the pinned Rust toolchain and its Android targets, then retry:\n" +
  `  rustup toolchain install ${toolchain}\n` +
  `  rustup target add --toolchain ${toolchain} ${abis.map((entry) => entry.rustTarget).join(" ")}\n` +
  "See android/README.md.";

const NDK_HINT =
  `The Android ABIs need NDK ${NDK_VERSION}. Set ANDROID_NDK_HOME, or install it into the SDK:\n` +
  `  sdkmanager "ndk;${NDK_VERSION}"`;

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { cwd: repoRoot, stdio: "inherit", ...options });
  if (result.error?.code === "ENOENT") {
    console.error(
      `\n[build-route-core-android] '${command}' was not found on PATH.\n${TOOLCHAIN_HINT}`
    );
    process.exit(1);
  }
  if (result.status !== 0) {
    console.error(
      `\n[build-route-core-android] '${command} ${args.join(" ")}' failed.\n${TOOLCHAIN_HINT}`
    );
    process.exit(result.status ?? 1);
  }
}

/**
 * The NDK ships one prebuilt toolchain directory per build host. Discovered
 * rather than assumed, because Apple Silicon still gets `darwin-x86_64`.
 */
function ndkToolchainBin() {
  const candidates = [
    process.env.ANDROID_NDK_HOME,
    process.env.ANDROID_NDK_ROOT,
    ...[
      process.env.ANDROID_HOME,
      process.env.ANDROID_SDK_ROOT,
      join(homeDir(), "Library", "Android", "sdk"),
      join(homeDir(), "Android", "Sdk")
    ]
      .filter(Boolean)
      .map((sdk) => join(sdk, "ndk", NDK_VERSION))
  ].filter(Boolean);

  const ndk = candidates.find((candidate) =>
    existsSync(join(candidate, "toolchains", "llvm", "prebuilt"))
  );
  if (!ndk) {
    console.error(`\n[build-route-core-android] Could not locate the Android NDK.\n${NDK_HINT}`);
    process.exit(1);
  }

  const prebuilt = join(ndk, "toolchains", "llvm", "prebuilt");
  const hostTag = readdirSync(prebuilt)[0];
  if (!hostTag) {
    console.error(
      `\n[build-route-core-android] ${prebuilt} has no prebuilt toolchain.\n${NDK_HINT}`
    );
    process.exit(1);
  }
  return join(prebuilt, hostTag, "bin");
}

function homeDir() {
  return process.env.HOME ?? "";
}

let rustcPath;
try {
  // Resolved explicitly so the build cannot pick up whatever rustc happens to be
  // first on PATH: a Homebrew rust install shadows rustup's shim.
  rustcPath = pinnedRustcPath(toolchain);
} catch (error) {
  console.error(`\n[build-route-core-android] ${error.message}\n${TOOLCHAIN_HINT}`);
  process.exit(1);
}

if (host) {
  // Debug profile: this library is only ever loaded by unit tests, and the
  // release profile's fat LTO would add minutes to every `./gradlew test`.
  run(
    "rustup",
    ["run", toolchain, "cargo", "build", "-p", "inderun_route_core", "--features", "jni-bindings"],
    { env: { ...process.env, RUSTC: rustcPath } }
  );

  const extension = process.platform === "darwin" ? "dylib" : "so";
  const built = join(repoRoot, "target", "debug", `libinderun_route_core.${extension}`);
  mkdirSync(hostLibDir, { recursive: true });
  // Copied to a directory of its own so Gradle can put exactly this on
  // java.library.path without also exposing the rest of target/debug.
  copyFileSync(built, join(hostLibDir, `libinderun_route_core.${extension}`));
  console.log(`[build-route-core-android] Wrote ${hostLibDir}`);
  process.exit(0);
}

const toolchainBin = ndkToolchainBin();
const env = { ...process.env, RUSTC: rustcPath };
for (const { clang, rustTarget } of abis) {
  const linker = join(toolchainBin, `${clang}${MIN_SDK}-clang`);
  if (!existsSync(linker)) {
    console.error(`\n[build-route-core-android] Missing NDK linker ${linker}.\n${NDK_HINT}`);
    process.exit(1);
  }
  // Cargo reads the linker from CARGO_TARGET_<TRIPLE>_LINKER. Set here rather
  // than in .cargo/config.toml because the path is machine-specific.
  env[`CARGO_TARGET_${rustTarget.toUpperCase().replaceAll("-", "_")}_LINKER`] = linker;
}

for (const { abi, rustTarget } of abis) {
  run(
    "rustup",
    [
      "run",
      toolchain,
      "cargo",
      "build",
      "-p",
      "inderun_route_core",
      "--features",
      "jni-bindings",
      "--profile",
      "android",
      "--target",
      rustTarget
    ],
    { env }
  );

  const destination = join(jniLibsDir, abi);
  mkdirSync(destination, { recursive: true });
  copyFileSync(
    join(repoRoot, "target", rustTarget, "android", LIBRARY),
    join(destination, LIBRARY)
  );
}

console.log(`[build-route-core-android] Wrote ${jniLibsDir}`);
