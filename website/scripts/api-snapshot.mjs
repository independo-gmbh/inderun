#!/usr/bin/env node
/**
 * Snapshot of the public TypeScript API the reference is generated from: every export of the
 * pinned Capacitor plugin and Web SDK, with its kind. A version bump or a new export changes the
 * snapshot, so it shows up in review instead of slipping into the site.
 *
 *   node scripts/api-snapshot.mjs --write   regenerate api-snapshot/*.json
 *   node scripts/api-snapshot.mjs --check   exit 1 when the installed packages differ
 */
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { WEBSITE_DIR, readVersions } from "../docs-architecture.mjs";

const versions = readVersions();
const ENTRIES = {
  capacitor: {
    package: "@independo/capacitor-inderun",
    entry: "node_modules/@independo/capacitor-inderun/dist/index.d.ts"
  },
  web: {
    package: "@independo/inderun-web",
    entry: "node_modules/@independo/inderun-web/dist/index.d.ts"
  }
};
const KINDS = {
  4: "namespace",
  8: "enum",
  32: "variable",
  64: "function",
  128: "class",
  256: "interface",
  2097152: "type",
  4194304: "reference"
};

function snapshot(name, { package: packageName, entry }) {
  const out = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "inderun-api-")), `${name}.json`);
  execFileSync(
    path.join(WEBSITE_DIR, "node_modules/.bin/typedoc"),
    [
      "--json",
      out,
      "--entryPoints",
      entry,
      "--tsconfig",
      "tsconfig.typedoc.json",
      "--skipErrorChecking",
      "--logLevel",
      "Error"
    ],
    { cwd: WEBSITE_DIR, stdio: ["ignore", "ignore", "inherit"] }
  );
  const project = JSON.parse(fs.readFileSync(out, "utf8"));
  const exports = (project.children ?? [])
    .map((child) => `${KINDS[child.kind] ?? child.kind} ${child.name}`)
    .sort();
  return { package: packageName, version: versions.packages[packageName], exports };
}

const write = process.argv.includes("--write");
let failed = false;
for (const [name, config] of Object.entries(ENTRIES)) {
  const file = path.join(WEBSITE_DIR, "api-snapshot", `${name}.json`);
  const next = `${JSON.stringify(snapshot(name, config), null, 2)}\n`;
  if (write) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, next);
    console.log(`wrote api-snapshot/${name}.json`);
  } else if (!fs.existsSync(file) || fs.readFileSync(file, "utf8") !== next) {
    console.error(
      `api-snapshot/${name}.json does not match ${config.package}@${versions.packages[config.package]}.`
    );
    failed = true;
  }
}
if (failed) {
  console.error("Run `pnpm --filter website update:api`, review the export diff, and commit it.");
  process.exit(1);
}
if (!write) console.log("API snapshot matches the pinned packages.");
