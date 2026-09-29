/**
 * Checks the committed Kotlin and Swift contracts against each other: every generated
 * Kotlin enum must expose its schema wire value, and the two languages must spell the
 * same wire values for the same schema enum.
 *
 * generate-contracts.mjs asserts the same thing on the sources it is about to write, so
 * this script exists for the case that assertion cannot see: a hand-edit of the
 * committed output. `javascript.yml`'s regenerate-and-diff step deliberately excludes
 * the Kotlin contract (it runs `generate:code`, without the Gradle Spotless pass the
 * committed file needs), which would otherwise leave that file unguarded on a PR.
 *
 * Usage: node contracts/scripts/verify-enum-wire-parity.mjs
 */

import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { collectEnumWireParityProblems } from "./kotlin-enum-wire-values.mjs";

const contractsRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const repoRoot = dirname(contractsRoot);

const kotlinContractsPath = join(
  repoRoot,
  "android",
  "inderun-contracts",
  "src",
  "main",
  "kotlin",
  "app",
  "independo",
  "inderun",
  "contracts",
  "Contracts.kt"
);
const swiftContractsPath = join(
  repoRoot,
  "ios",
  "IndeRun",
  "Sources",
  "IndeRunContracts",
  "Contracts.swift"
);

const [kotlinSource, swiftSource] = await Promise.all([
  readFile(kotlinContractsPath, "utf8"),
  readFile(swiftContractsPath, "utf8")
]);

const problems = collectEnumWireParityProblems(kotlinSource, swiftSource);
if (problems.length > 0) {
  console.error("Generated enum wire values disagree between Kotlin and Swift:\n");
  for (const problem of problems) {
    console.error(`  - ${problem}`);
  }
  console.error("\nRegenerate both with `pnpm generate` rather than editing either file by hand.");
  process.exit(1);
}

console.log("Kotlin and Swift agree on the wire value of every generated contract enum.");
