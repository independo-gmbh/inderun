// Propagates the semantic-release-computed version to every artifact that ships
// with a repo-wide version: the publishable npm packages and the Android/Maven
// coordinates. Invoked by semantic-release's @semantic-release/exec `prepareCmd`
// as: `node scripts/set-version.mjs <version>`. The bumped files are then
// committed by @semantic-release/git.
import { readFileSync, writeFileSync, existsSync } from "node:fs";

const version = process.argv[2];
if (!version) {
  console.error("Usage: node scripts/set-version.mjs <version>");
  process.exit(1);
}

// Publishable npm packages (single repo-wide version).
const npmPackages = [
  "packages/contracts/package.json",
  "packages/inderun-route-core-wasm/package.json",
  "packages/inderun-web/package.json"
];

for (const file of npmPackages) {
  const pkg = JSON.parse(readFileSync(file, "utf8"));
  pkg.version = version;
  writeFileSync(file, `${JSON.stringify(pkg, null, 2)}\n`);
  console.log(`set ${file} -> ${version}`);
}

// Android/Maven coordinates share the same repo-wide version via gradle.properties.
const gradleProps = "android/gradle.properties";
if (existsSync(gradleProps)) {
  const contents = readFileSync(gradleProps, "utf8");
  const key = "inderunVersion";
  const line = `${key}=${version}`;
  const next = new RegExp(`^${key}=.*$`, "m").test(contents)
    ? contents.replace(new RegExp(`^${key}=.*$`, "m"), line)
    : `${contents.replace(/\n?$/, "\n")}${line}\n`;
  writeFileSync(gradleProps, next);
  console.log(`set ${gradleProps} ${key} -> ${version}`);
} else {
  console.warn(`skip ${gradleProps} (not found)`);
}
