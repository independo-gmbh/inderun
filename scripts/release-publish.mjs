// Publishes the three public npm packages during semantic-release's `publish`
// step (@semantic-release/exec `publishCmd`). Runs only in CI on a real release.
//
// Why pnpm pack + npm publish (instead of `pnpm publish` or `npm publish` alone):
//   - `pnpm pack` rewrites the `workspace:^` inter-package deps to the concrete
//     `^<version>` in the packed tarball's package.json.
//   - `npm publish <tarball>` uses the npm CLI, which supports OIDC Trusted
//     Publishing (tokenless) and provenance attestation. Plain `pnpm publish`
//     does not reliably support tokenless OIDC.
// Packages are published in dependency order so a dependent never lands before
// its dependency exists on the registry.
import { execFileSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Dependency order: contracts <- route-core-wasm <- web.
const packages = ["packages/contracts", "packages/inderun-route-core-wasm", "packages/inderun-web"];

// npm rejects publishing a prerelease version to the default `latest` dist-tag,
// so derive the tag from the version: `0.1.1-dev.1` -> `dev`, `0.1.1` -> `latest`.
// This mirrors semantic-release's channel-based dist-tags for prerelease branches.
function distTag(version) {
  const prerelease = version.split("-")[1];
  return prerelease ? prerelease.split(".")[0] : "latest";
}

function run(cmd, args, cwd) {
  console.log(`$ ${cmd} ${args.join(" ")}${cwd ? ` (cwd=${cwd})` : ""}`);
  execFileSync(cmd, args, { stdio: "inherit", cwd });
}

for (const dir of packages) {
  const { version } = JSON.parse(readFileSync(join(dir, "package.json"), "utf8"));
  const tag = distTag(version);
  const dest = mkdtempSync(join(tmpdir(), "inderun-pack-"));
  // pnpm pack rewrites workspace:^ deps into the tarball.
  run("pnpm", ["pack", "--pack-destination", dest], dir);
  const tarball = readdirSync(dest).find((f) => f.endsWith(".tgz"));
  if (!tarball) throw new Error(`No tarball produced for ${dir}`);
  // npm publish so OIDC trusted publishing + provenance apply. --tag is required
  // for prerelease versions and harmless (defaults to latest) for stable ones.
  run("npm", ["publish", join(dest, tarball), "--access", "public", "--provenance", "--tag", tag]);
}
