#!/usr/bin/env node
/**
 * Size gate for the two shipped WASM modules (`pnpm build:wasm` first). Prints
 * `<module> raw=<bytes> gzip=<bytes> budget=<raw>/<gzip>` per module and exits 1
 * when either number is over its budget.
 *
 * Budgets are the release-profile size measured when the gate was added, plus 15 %,
 * rounded up to 10 KiB. Raise one deliberately, in the change that grows the module.
 *
 * Raised since: `inderun_route_core` by 26 KiB raw / 11 KiB gzip (the measured growth,
 * rounded up to the next KiB) when serde_json's `float_roundtrip` went in, so a
 * control value comes back from the planner bit for bit (#311).
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const generated = join(repoRoot, "packages", "inderun-route-core-wasm", "generated");

const budgets = [
  { name: "inderun_route_core", raw: 425_984, gzip: 134_144 },
  { name: "inderun_speech_text", raw: 2_048_000, gzip: 634_880 }
];

let failed = false;
for (const { name, raw: rawBudget, gzip: gzipBudget } of budgets) {
  const bytes = readFileSync(join(generated, `${name}_bg.wasm`));
  const raw = bytes.length;
  const gzip = gzipSync(bytes, { level: 9 }).length;
  console.log(`${name} raw=${raw} gzip=${gzip} budget=${rawBudget}/${gzipBudget}`);
  if (raw > rawBudget || gzip > gzipBudget) {
    console.error(`[check-wasm-size] ${name} is over budget.`);
    failed = true;
  }
}
process.exit(failed ? 1 : 0);
