/**
 * Shared logic for the two marker kinds that keep copies of code and version facts in sync:
 *
 *   <!-- snippet:NAME -->      filled from website/snippets/NAME.ts
 *   <!-- /snippet -->
 *
 *   <!-- version:NAME -->      rendered from website/versions.json by VERSION_BLOCKS[NAME]
 *   <!-- /version -->
 *
 * Both render on GitHub (the comments are invisible) and on the site. Only the text between
 * the markers is generated; everything around it is hand-written.
 */
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { REPO_ROOT, WEBSITE_DIR, readVersions } from "../docs-architecture.mjs";

export const SNIPPETS_DIR = path.join(WEBSITE_DIR, "snippets");
export const PENDING_MARKER = "TODO(verify)";

const BLOCK = /(<!-- (snippet|version):([a-z0-9-]+) -->)([\s\S]*?)(<!-- \/\2 -->)/g;

/** Every tracked Markdown file in the repository (READMEs and docs alike). */
export function markdownFiles() {
  return execFileSync("git", ["ls-files", "--cached", "--others", "--exclude-standard", "*.md"], {
    cwd: REPO_ROOT,
    encoding: "utf8"
  })
    .split("\n")
    .filter(
      (file) => file && !file.includes("node_modules/") && fs.existsSync(path.join(REPO_ROOT, file))
    );
}

export function snippetPath(name) {
  return path.join(SNIPPETS_DIR, `${name}.ts`);
}

export function readSnippet(name) {
  const file = snippetPath(name);
  if (!fs.existsSync(file))
    throw new Error(`Unknown snippet "${name}" (expected ${path.relative(REPO_ROOT, file)})`);
  return fs.readFileSync(file, "utf8");
}

const fence = (lang, body) =>
  `\n\`\`\`${lang}\n${body.endsWith("\n") ? body : `${body}\n`}\`\`\`\n`;

/** Version blocks: each returns the Markdown that goes between its markers. */
export const VERSION_BLOCKS = {
  "capacitor-install": (v) =>
    fence(
      "sh",
      `npm install ${v.capacitorPlugin.package}@${v.capacitorPlugin.version} @capacitor/core@${v.capacitorPlugin.capacitor}`
    ),
  "capacitor-clone": (v) =>
    fence("sh", `git clone --branch ${v.capacitorPlugin.tag} ${v.capacitorPlugin.repository}.git`),
  "web-install": (v) =>
    fence("sh", `pnpm add @independo/inderun-web@${v.packages["@independo/inderun-web"]}`),
  "swiftpm-install": (v) =>
    fence("swift", `.package(url: "${v.swift.url}", exact: "${v.swift.version}")`),
  "gradle-install": (v) =>
    fence("kotlin", `implementation("${v.kotlin.group}:${v.kotlin.artifact}:${v.kotlin.version}")`),
  "tested-set": (v) =>
    `\nTested set: IndeRun **${v.core.version}** (\`@independo/inderun-web\`, SwiftPM, Maven) and ` +
    `\`${v.capacitorPlugin.package}\` **${v.capacitorPlugin.version}**, which wraps IndeRun ${v.capacitorPlugin.pinsCore}. ` +
    `Examples type-checked against these on ${v.testedAt}.\n`,
  // Capacitor pages name only the package a Capacitor developer installs and the core it includes.
  "capacitor-version": (v) =>
    `\nVersion: \`${v.capacitorPlugin.package}\` **${v.capacitorPlugin.version}**, which includes IndeRun ${v.capacitorPlugin.pinsCore}. ` +
    `The examples on this page are type-checked against it (${v.testedAt}).\n`,
  "platforms-table": (v) =>
    "\n| You build with | Package (tested set) | Installs on | On-device model, checked at runtime |\n| --- | --- | --- | --- |\n" +
    `| Capacitor ${v.capacitorPlugin.capacitor} | \`${v.capacitorPlugin.package}\` ${v.capacitorPlugin.version} (wraps IndeRun ${v.capacitorPlugin.pinsCore}) | iOS 16+, Android 8.0 (API 26)+, modern browsers | iOS 26+ on an Apple Intelligence device with it turned on; Android devices with AICore/Gemini Nano; Chrome Prompt API on desktop Chrome when \`systemModel\` is configured |\n` +
    `| Web / TypeScript | \`@independo/inderun-web\` ${v.packages["@independo/inderun-web"]} | ES2022 + WebAssembly (Node 24+ for tooling) | Chrome Prompt API; ONNX Runtime Web with a model you supply |\n` +
    `| Swift | \`IndeRun\` ${v.swift.version} (SwiftPM) | iOS 16+, macOS 14+, Swift 5.9+ | Apple Foundation Models (iOS/macOS 26+) |\n` +
    `| Kotlin | \`${v.kotlin.group}:${v.kotlin.artifact}\` ${v.kotlin.version} | Android 8.0 (API 26)+, JDK 17 | ML Kit GenAI / Gemini Nano |\n`,
  "install-table": (v) =>
    "\n| You build with | Install (tested set) |\n| --- | --- |\n" +
    `| Capacitor ${v.capacitorPlugin.capacitor} | \`npm install ${v.capacitorPlugin.package}@${v.capacitorPlugin.version}\` |\n` +
    `| Web / TypeScript | \`pnpm add @independo/inderun-web@${v.packages["@independo/inderun-web"]}\` |\n` +
    `| Swift (SwiftPM) | \`.package(url: "${v.swift.url}", exact: "${v.swift.version}")\` |\n` +
    `| Kotlin (Maven Central) | \`implementation("${v.kotlin.group}:${v.kotlin.artifact}:${v.kotlin.version}")\` |\n`
};

const PLUGIN_TAG_URL =
  /(github\.com\/independo-gmbh\/capacitor-inderun\/(?:blob|tree)\/)v\d[\w.-]*/g;
const PLUGIN_TAG_PROSE = /((?:pinned to |\) at |section \()\s*)v\d+\.\d+\.\d+(?:-[\w.]+)?/g;

/**
 * Keeps every pinned link to the plugin repository, and the "pinned to vX" wording beside it,
 * on `capacitorPlugin.tag`. Only lines that link to the plugin repository are touched.
 */
function pinPluginTag(text, versions) {
  const tag = versions.capacitorPlugin.tag;
  return text
    .split("\n")
    .map((line) =>
      line.includes("github.com/independo-gmbh/capacitor-inderun/")
        ? line.replace(PLUGIN_TAG_URL, `$1${tag}`).replace(PLUGIN_TAG_PROSE, `$1${tag}`)
        : line
    )
    .join("\n");
}

/** Renders every block in `text`. Returns the new text and the names it touched. */
export function renderBlocks(input, versions = readVersions()) {
  const used = [];
  const text = pinPluginTag(input, versions);
  const output = text.replace(BLOCK, (_match, open, kind, name, _body, close) => {
    used.push({ kind, name });
    if (kind === "snippet") return `${open}${fence("ts", readSnippet(name))}${close}`;
    const block = VERSION_BLOCKS[name];
    if (!block) throw new Error(`Unknown version block "${name}"`);
    return `${open}${block(versions)}${close}`;
  });
  return { output, used };
}

export function isPending(name) {
  return readSnippet(name).includes(PENDING_MARKER);
}
