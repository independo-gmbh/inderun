#!/usr/bin/env node
/**
 * Fills or checks snippet and version markers in every tracked Markdown file.
 *
 *   node scripts/sync-markers.mjs --write   regenerate the marked blocks in place
 *   node scripts/sync-markers.mjs --check   exit 1 when any marked block differs from its source
 */
import fs from "node:fs";
import path from "node:path";
import { REPO_ROOT } from "../docs-architecture.mjs";
import { markdownFiles, renderBlocks } from "./markers.mjs";

const mode = process.argv.includes("--write") ? "write" : "check";
const stale = [];
let blocks = 0;

for (const file of markdownFiles()) {
  const absolute = path.join(REPO_ROOT, file);
  const text = fs.readFileSync(absolute, "utf8");
  const { output, used } = renderBlocks(text);
  blocks += used.length;
  if (output === text) continue;
  if (mode === "write") {
    fs.writeFileSync(absolute, output);
    console.log(`updated ${file}`);
  } else {
    stale.push(file);
  }
}

if (stale.length > 0) {
  console.error("Marked blocks differ from website/snippets/ or website/versions.json:");
  for (const file of stale) console.error(`  ${file}`);
  console.error("Run `pnpm --filter website sync:markers` and commit the result.");
  process.exit(1);
}
console.log(`${mode === "write" ? "Synced" : "Checked"} ${blocks} marked blocks.`);
