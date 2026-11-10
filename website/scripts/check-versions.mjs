#!/usr/bin/env node
/**
 * Keeps version facts consistent with website/versions.json, the only place pins are edited:
 *
 * 1. website/package.json installs exactly the versions in versions.json `packages`.
 * 2. The pinned Capacitor plugin, as published on npm, wraps the IndeRun version recorded in
 *    `capacitorPlugin.pinsCore`.
 * 3. In `release` mode, the plugin wraps the same core version the site documents. In
 *    `prerelease` mode (before the launch pair is published) a mismatch is only a warning.
 *
 * README and docs copies of these versions are checked by sync-markers.mjs --check.
 * Pass --offline to skip the npm registry lookup.
 */
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { WEBSITE_DIR, readVersions } from "../docs-architecture.mjs";

const versions = readVersions();
const pkg = JSON.parse(fs.readFileSync(path.join(WEBSITE_DIR, "package.json"), "utf8"));
const installed = { ...pkg.dependencies, ...pkg.devDependencies };
const errors = [];
const warnings = [];

for (const [name, version] of Object.entries(versions.packages)) {
  if (installed[name] !== version) {
    errors.push(
      `website/package.json has ${name}@${installed[name] ?? "(missing)"}, versions.json pins ${version}`
    );
  }
}
if (versions.packages["@independo/inderun-web"] !== versions.core.version) {
  errors.push(
    `versions.json: packages["@independo/inderun-web"] must equal core.version (${versions.core.version})`
  );
}
if (versions.packages[versions.capacitorPlugin.package] !== versions.capacitorPlugin.version) {
  errors.push("versions.json: packages and capacitorPlugin disagree on the plugin version");
}
if (`v${versions.core.version}` !== versions.core.tag) {
  errors.push(`versions.json: core.tag must be v${versions.core.version}`);
}

if (!process.argv.includes("--offline")) {
  const spec = `${versions.capacitorPlugin.package}@${versions.capacitorPlugin.version}`;
  const deps = JSON.parse(
    execFileSync("npm", ["view", spec, "dependencies", "--json"], { encoding: "utf8" })
  );
  const wrapped = deps["@independo/inderun-web"];
  if (wrapped !== versions.capacitorPlugin.pinsCore) {
    errors.push(
      `${spec} depends on @independo/inderun-web ${wrapped}, versions.json records pinsCore ${versions.capacitorPlugin.pinsCore}`
    );
  }
}

if (versions.capacitorPlugin.pinsCore !== versions.core.version) {
  const message = `The Capacitor plugin ${versions.capacitorPlugin.version} wraps IndeRun ${versions.capacitorPlugin.pinsCore}, the site documents ${versions.core.version}`;
  (versions.mode === "release" ? errors : warnings).push(message);
}

for (const warning of warnings) {
  console.log(`WARNING ${warning}`);
  if (process.env.GITHUB_ACTIONS) console.log(`::warning file=website/versions.json::${warning}`);
}
if (errors.length > 0) {
  for (const error of errors) console.error(`ERROR ${error}`);
  process.exit(1);
}
console.log(`Versions consistent (mode: ${versions.mode}).`);
