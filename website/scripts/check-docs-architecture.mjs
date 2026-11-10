/**
 * Enforces the documentation architecture (docs/architecture/decisions/024-documentation-architecture.md).
 *
 * Source checks (no build needed):
 *   a. every published doc has front matter `slug` (unique, under `docs`), `title` and a
 *      `description` of at most 155 characters;
 *   b. published-urls.txt and the published docs agree, both ways;
 *   c. no doc outside the published folders declares a `slug:`.
 *
 * Build checks (need `pnpm build`; skipped with a notice when the build directory is missing,
 * unless --require-build is passed):
 *   d. no internal doc leaks: neither its H1 title (as a page title, heading or link text) nor
 *      the URL derived from its path appears in the HTML, sitemap or llms.txt;
 *   e. no GitHub blob/tree link to dev or main, no /edit/main/, and /edit/dev/ only in the
 *      edit-page link Starlight renders for a published doc;
 *   f. every blob/tree link to inderun uses the core tag of versions.json and every one to
 *      capacitor-inderun the plugin tag.
 *
 *   node scripts/check-docs-architecture.mjs [--dir <build dir>] [--require-build]
 */
import fs from "node:fs";
import path from "node:path";
import { REPO_ROOT, WEBSITE_DIR, isPublishedDoc, readVersions } from "../docs-architecture.mjs";
import { readDocsPaths } from "../published-urls.mjs";

const args = process.argv.slice(2);
const dirArg = args.indexOf("--dir");
const DIST = path.resolve(WEBSITE_DIR, dirArg >= 0 ? args[dirArg + 1] : "dist");
const requireBuild = args.includes("--require-build");

const errors = [];
const fail = (where, message) => errors.push(`${where}: ${message}`);

function* walk(dir, skip = () => false) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (skip(entry)) continue;
    if (entry.isDirectory()) yield* walk(full, skip);
    else yield full;
  }
}

const toRepoPath = (file) => path.relative(REPO_ROOT, file).split(path.sep).join("/");

function frontMatter(text) {
  const match = /^---\r?\n([\s\S]*?)\r?\n---/.exec(text);
  if (!match) return undefined;
  const value = (key) => {
    const m = new RegExp(`^${key}:[ \\t]*(.*)$`, "m").exec(match[1]);
    if (!m) return undefined;
    const raw = m[1].trim();
    const quoted = /^"((?:[^"\\]|\\.)*)"$/.exec(raw) ?? /^'((?:[^']|'')*)'$/.exec(raw);
    return quoted ? quoted[1].replace(/\\"/g, '"').replace(/''/g, "'") : raw;
  };
  return { slug: value("slug"), title: value("title"), description: value("description") };
}

const docsDir = path.join(REPO_ROOT, "docs");
const allDocs = [...walk(docsDir)].filter((f) => f.endsWith(".md")).map(toRepoPath);
const published = allDocs.filter(isPublishedDoc);
const internal = allDocs.filter((p) => !isPublishedDoc(p));

// a. front matter of published docs
const slugs = new Map();
for (const doc of published) {
  const fm = frontMatter(fs.readFileSync(path.join(REPO_ROOT, doc), "utf8"));
  if (!fm) {
    fail(doc, "published doc has no front matter");
    continue;
  }
  if (!fm.slug) fail(doc, "front matter has no slug");
  else {
    if (fm.slug !== "docs" && !fm.slug.startsWith("docs/"))
      fail(doc, `slug "${fm.slug}" must start with "docs"`);
    if (/^\/|\/$/.test(fm.slug))
      fail(doc, `slug "${fm.slug}" must have no leading or trailing slash`);
    if (slugs.has(fm.slug)) fail(doc, `slug "${fm.slug}" is also used by ${slugs.get(fm.slug)}`);
    slugs.set(fm.slug, doc);
  }
  if (!fm.title) fail(doc, "front matter has no title");
  if (!fm.description) fail(doc, "front matter has no description");
  else if (fm.description.length > 155)
    fail(doc, `description is ${fm.description.length} characters (limit 155)`);
}

// b. published-urls.txt <-> published docs
const listed = new Set(readDocsPaths());
for (const [slug, doc] of slugs)
  if (!listed.has(`/${slug}`)) fail(doc, `/${slug} is not in published-urls.txt`);
for (const url of listed)
  if (!slugs.has(url.slice(1)))
    fail("published-urls.txt", `${url} has no published doc with that slug`);

// c. internal docs declare no slug
for (const doc of internal) {
  const fm = frontMatter(fs.readFileSync(path.join(REPO_ROOT, doc), "utf8"));
  if (fm?.slug !== undefined)
    fail(
      doc,
      `internal doc declares slug "${fm.slug}"; move it to a published folder or drop the key`
    );
}

// Build checks
let pages = 0;
let htmlChecked = 0;
if (!fs.existsSync(DIST)) {
  if (requireBuild)
    fail(path.relative(process.cwd(), DIST), "build directory is missing; run pnpm build first");
  else
    console.log(
      `check-docs: ${path.relative(process.cwd(), DIST)} not built; skipped the build checks (d-f)`
    );
} else {
  const versions = readVersions();
  const htmlFiles = [
    ...walk(DIST, (e) => e.isDirectory() && (e.name === "_astro" || e.name === "pagefind"))
  ].filter((f) => f.endsWith(".html"));
  const sitemaps = fs
    .readdirSync(DIST)
    .filter((f) => /^sitemap-.*\.xml$/.test(f))
    .map((f) => path.join(DIST, f));
  const llms = path.join(DIST, "llms.txt");
  const surfaces = [...htmlFiles, ...sitemaps, ...(fs.existsSync(llms) ? [llms] : [])];
  const text = new Map(surfaces.map((f) => [f, fs.readFileSync(f, "utf8")]));
  const rel = (f) => path.relative(DIST, f);
  const decode = (s) =>
    s
      .replaceAll("&quot;", '"')
      .replaceAll("&#39;", "'")
      .replaceAll("&lt;", "<")
      .replaceAll("&gt;", ">")
      .replaceAll("&amp;", "&");
  const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  // Repeat until stable so nested fragments such as "<<b>script>" cannot leave a tag behind.
  const stripTags = (s) => {
    let prev;
    do {
      prev = s;
      s = s.replace(/<[^>]+>/g, "");
    } while (s !== prev);
    return s;
  };

  // Titles that a published page also uses cannot identify an internal doc; those rely on the URL check.
  const publishedTitles = new Set();
  for (const [file, html] of text) {
    if (!file.endsWith(".html")) continue;
    const t = /<title>([\s\S]*?)<\/title>/.exec(html)?.[1];
    if (t)
      publishedTitles.add(
        decode(t)
          .replace(/\s*[|–-]\s*IndeRun\s*$/, "")
          .trim()
      );
    for (const h of html.matchAll(/<h1[^>]*>([\s\S]*?)<\/h1>/g))
      publishedTitles.add(decode(stripTags(h[1])).trim());
  }
  const ambiguousTitles = [];

  for (const doc of internal) {
    const body = fs
      .readFileSync(path.join(REPO_ROOT, doc), "utf8")
      .replace(/^---[\s\S]*?\r?\n---\r?\n/, "");
    const h1 = /^# (.+?)\s*$/m.exec(body)?.[1];
    const stem = `/${doc.replace(/\.md$/, "")}`;
    // The path as a site URL ("/docs/ci" or "https://inderun.dev/docs/ci"), not as part of a longer path or file name.
    const urlRe = new RegExp(
      `(?:(?<![\\w/.-])|(?<=inderun\\.dev))${escapeRe(stem)}(?![\\w/-]|\\.\\w)`
    );
    const checkTitle = h1 && !publishedTitles.has(h1);
    if (h1 && !checkTitle) ambiguousTitles.push(doc);
    // A page title, a page heading or an llms.txt link label; sidebar and external-link labels
    // may legitimately repeat a title (they point at GitHub), so they are not searched.
    const h1Esc = h1 ? escapeRe(h1.replaceAll("&", "&amp;")) : "";
    const titleRe = checkTitle
      ? new RegExp(
          `<title>\\s*${h1Esc}\\s*(?:<|\\s[|\\u2013-]\\s)|<h1[^>]*>\\s*${h1Esc}\\s*</h1>|^- \\[${h1Esc}\\]\\(`,
          "m"
        )
      : undefined;
    for (const [file, content] of text) {
      if (urlRe.test(content)) fail(rel(file), `contains the URL of internal doc ${doc} (${stem})`);
      if (titleRe?.test(content))
        fail(rel(file), `contains the title of internal doc ${doc} ("${h1}")`);
    }
  }

  const GH = "https://github.com/independo-gmbh";
  const editRe = new RegExp(
    `<a href="${escapeRe(GH)}/inderun/edit/dev/(docs/[^"#?]+\\.md)" class="sl-flex print:hidden[^"]*"`,
    "g"
  );
  const refTag = { inderun: versions.core.tag, "capacitor-inderun": versions.capacitorPlugin.tag };
  for (const [file, content] of text) {
    if (!file.endsWith(".html")) continue;
    htmlChecked += 1;
    const where = rel(file);
    if (/<meta http-equiv="refresh"/i.test(content) && !/<title>/i.test(content)) continue;
    pages += 1;
    // e. branch links
    for (const m of content.matchAll(
      /github\.com\/independo-gmbh\/(inderun|capacitor-inderun)\/(blob|tree)\/(dev|main)(?=[/"'#?<\s]|$)/g
    ))
      fail(where, `links to a branch instead of a tag: ${m[0]}`);
    for (const m of content.matchAll(/github\.com\/independo-gmbh\/[\w-]+\/edit\/main\//g))
      fail(where, `edit link to main: ${m[0]}`);
    const allowedEdits = new Set();
    for (const m of content.matchAll(editRe)) {
      allowedEdits.add(m.index);
      if (!isPublishedDoc(m[1]))
        fail(where, `edit link points at ${m[1]}, which is not a published doc`);
    }
    const editCount = (content.match(/github\.com\/independo-gmbh\/[\w-]+\/edit\/dev\//g) ?? [])
      .length;
    if (editCount !== allowedEdits.size)
      fail(
        where,
        `${editCount - allowedEdits.size} /edit/dev/ link(s) outside Starlight's edit-page link`
      );
    // f. pinned tags
    for (const m of content.matchAll(
      /github\.com\/independo-gmbh\/(inderun|capacitor-inderun)\/(blob|tree)\/([^/"'<>#?\s]+)(?=[/"'#?<\s]|$)/g
    ))
      if (!["dev", "main"].includes(m[3]) && m[3] !== refTag[m[1]])
        fail(where, `${m[1]} link uses ref ${m[3]}, expected ${refTag[m[1]]} (${m[0]})`);
  }
  if (ambiguousTitles.length)
    console.log(
      `check-docs: ${ambiguousTitles.length} internal doc title(s) equal a published title; the URL check covers them`
    );
}

if (errors.length) {
  console.error(`check-docs: ${errors.length} violation(s)`);
  for (const e of errors.slice(0, 60)) console.error(`  - ${e}`);
  if (errors.length > 60) console.error(`  ... and ${errors.length - 60} more`);
  process.exit(1);
}
console.log(
  `check-docs: ok (${published.length} published docs, ${internal.length} internal docs${
    htmlChecked ? `, ${pages} built pages checked` : ""
  })`
);
