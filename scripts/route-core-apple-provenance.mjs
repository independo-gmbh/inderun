/**
 * Provenance for the committed route-core XCFramework.
 *
 * `ios/IndeRun/Frameworks/InderunRouteCoreFFI.xcframework` is an executable in
 * git: it is what SwiftPM consumers run, and reviewing the Rust source says
 * nothing about whether that binary came from it. Rust builds are not
 * byte-reproducible, so rebuilding and diffing cannot close the gap. What can is
 * recording, next to the artifact, the exact compiler plus content hashes of
 * every input it was built from, and checking both in CI:
 *
 *   - the source hashes prove the committed binary belongs to *this* revision of
 *     the crate, the lockfile, the C header, and the build scripts;
 *   - the per-slice hashes prove the binary in the tree is the one those hashes
 *     were computed over, i.e. nobody swapped a slice;
 *   - CI additionally rebuilds from source and re-runs the Swift suite against
 *     the result, which is the behavioural half of the same question.
 *
 * Hashing content rather than recording a commit SHA is deliberate: the artifact
 * is produced before the commit that carries it exists, and content hashes stay
 * checkable at any later commit.
 */
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));

export const frameworksDir = join(repoRoot, "ios", "IndeRun", "Frameworks");
export const xcframeworkPath = join(frameworksDir, "InderunRouteCoreFFI.xcframework");
export const manifestPath = join(frameworksDir, "InderunRouteCoreFFI.provenance.json");

/**
 * Every input that can change the produced binary. A file missing from this list
 * is a file whose change CI would not notice, so keep it exhaustive rather than
 * convenient: the crate sources and manifest, the workspace manifest and lockfile
 * (a dependency bump changes the compiled core), the toolchain pin, the C header
 * packaged into the framework, and the scripts that do the packaging.
 */
const SOURCE_INPUTS = [
  "rust/inderun-route-core/src",
  "rust/inderun-route-core/include",
  "rust/inderun-route-core/Cargo.toml",
  "Cargo.toml",
  "Cargo.lock",
  "rust-toolchain.toml",
  "scripts/build-route-core-apple.mjs",
  "scripts/route-core-apple-provenance.mjs",
  "scripts/rust-toolchain.mjs"
];

function sha256(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function walk(absolute) {
  if (!statSync(absolute).isDirectory()) {
    return [absolute];
  }
  return readdirSync(absolute)
    .sort()
    .flatMap((entry) => walk(join(absolute, entry)));
}

/** Repo-relative POSIX path, so manifests match across platforms. */
function key(absolute) {
  return relative(repoRoot, absolute).split(sep).join("/");
}

/**
 * Every path in `SOURCE_INPUTS` must be tracked by git, or the manifest records a
 * hash of a file that only exists on the machine that built the artifact -- and
 * verification then crashes on a fresh checkout instead of proving anything. That
 * is exactly what an ignored `Cargo.lock` did, so it is checked rather than
 * assumed.
 */
function assertTracked(files) {
  const result = spawnSync("git", ["ls-files", "--", ...files.map(key)], {
    cwd: repoRoot,
    encoding: "utf8"
  });
  if (result.error || result.status !== 0) {
    // Not in a git checkout (a release tarball, say). The hashes are still
    // computable; only this cross-check is unavailable.
    return;
  }
  const tracked = new Set(result.stdout.split("\n").filter(Boolean));
  const untracked = files.map(key).filter((path) => !tracked.has(path));
  if (untracked.length > 0) {
    throw new Error(
      `These provenance inputs are not tracked by git, so the manifest would describe ` +
        `files nobody else has: ${untracked.join(", ")}`
    );
  }
}

/** `{ "<repo-relative path>": "<sha256>" }` over every declared source input. */
export function sourceHashes() {
  const files = SOURCE_INPUTS.flatMap((input) => walk(join(repoRoot, input))).sort();
  assertTracked(files);
  return Object.fromEntries(files.map((absolute) => [key(absolute), sha256(absolute)]));
}

/** `{ "<path inside the xcframework>": "<sha256>" }` over every packaged file. */
export function artifactHashes() {
  const entries = walk(xcframeworkPath)
    .sort()
    .map((absolute) => [
      relative(xcframeworkPath, absolute).split(sep).join("/"),
      sha256(absolute)
    ]);
  return Object.fromEntries(entries);
}

export function provenanceManifest({ rustcVersion, toolchain }) {
  return {
    // Bump when the manifest's own shape changes, so a verifier can refuse a
    // format it does not understand rather than silently checking less.
    manifestVersion: 1,
    artifact: relative(repoRoot, xcframeworkPath).split(sep).join("/"),
    buildCommand: "pnpm build:route-core-apple",
    cargoProfile: "apple",
    toolchain,
    rustcVersion,
    sources: sourceHashes(),
    files: artifactHashes()
  };
}

export function writeManifest(manifest) {
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
}

export function readManifest() {
  return JSON.parse(readFileSync(manifestPath, "utf8"));
}
