#!/usr/bin/env node
/**
 * Type-checks website/snippets/*.ts against the exact package versions installed from
 * website/package.json (which check-versions.mjs keeps equal to versions.json).
 *
 * A snippet containing TODO(verify) is a placeholder for an API that is not released yet. It is
 * excluded from the type-check and reported as PENDING (a GitHub warning annotation), never as
 * passing. With --release, any pending snippet fails the check.
 */
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { REPO_ROOT, WEBSITE_DIR } from "../docs-architecture.mjs";
import { PENDING_MARKER, SNIPPETS_DIR, markdownFiles } from "./markers.mjs";

const release = process.argv.includes("--release");
const snippets = fs.readdirSync(SNIPPETS_DIR).filter((file) => file.endsWith(".ts"));
const pending = snippets.filter((file) =>
  fs.readFileSync(path.join(SNIPPETS_DIR, file), "utf8").includes(PENDING_MARKER)
);
const checked = snippets.filter((file) => !pending.includes(file));

const tsconfig = path.join(SNIPPETS_DIR, ".tsconfig.check.json");
fs.writeFileSync(
  tsconfig,
  JSON.stringify({ extends: "./tsconfig.json", include: [], files: checked }, null, 2)
);
try {
  execFileSync(path.join(WEBSITE_DIR, "node_modules/.bin/tsc"), ["-p", tsconfig], {
    stdio: "inherit"
  });
} catch {
  console.error("Snippet type-check failed.");
  process.exit(1);
} finally {
  fs.rmSync(tsconfig, { force: true });
}
console.log(`Type-checked ${checked.length} snippets.`);

if (pending.length > 0) {
  const embeddedIn = (name) =>
    markdownFiles().filter((file) =>
      fs.readFileSync(path.join(REPO_ROOT, file), "utf8").includes(`<!-- snippet:${name} -->`)
    );
  for (const file of pending) {
    const name = file.replace(/\.ts$/, "");
    const where = embeddedIn(name);
    const message = `PENDING ${file}: ${PENDING_MARKER} placeholder, not type-checked${where.length ? ` (embedded in ${where.join(", ")})` : ""}`;
    console.log(message);
    if (process.env.GITHUB_ACTIONS)
      console.log(`::warning file=website/snippets/${file}::${message}`);
  }
  if (release) {
    console.error(`${pending.length} pending snippet(s) block a release build.`);
    process.exit(1);
  }
}
