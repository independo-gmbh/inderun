/**
 * Verifies the built site's SEO surface: one title and description per page, absolute canonical
 * on https://inderun.dev without a trailing slash, parsable JSON-LD whose @id references resolve,
 * a sitemap index with one website and one docs sitemap, limited to published-urls.txt and dated
 * from the lastmod manifest (plugins/sitemap-lastmod.mjs), robots and llms.txt, and no unfinished
 * `TODO(` placeholder on any page. Ported and trimmed from
 * independo.app's verify-seo-output.mjs.
 *
 *   node scripts/verify-seo-output.mjs              check dist/ (production)
 *   node scripts/verify-seo-output.mjs --preview    check dist-preview/ (every page noindex)
 *   node scripts/verify-seo-output.mjs --dir <dir>  check another build directory
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { readSitemapPaths, readDocsPaths } from "../published-urls.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const ORIGIN = "https://inderun.dev";
const args = process.argv.slice(2);
const preview = args.includes("--preview");
const dirArg = args.indexOf("--dir");
const DIST = path.resolve(ROOT, dirArg >= 0 ? args[dirArg + 1] : preview ? "dist-preview" : "dist");
/** Global entity ids that other sites and pages may reference without defining them. */
const GLOBAL_IDS = new Set([
  "https://www.independo.app#organization",
  `${ORIGIN}#website`,
  `${ORIGIN}#software`,
  `${ORIGIN}#webpage`
]);

const errors = [];
const fail = (where, message) => errors.push(`${where}: ${message}`);
const rel = (file) => path.relative(DIST, file);

if (!fs.existsSync(DIST)) {
  console.error(`verify-seo: ${DIST} does not exist; build first.`);
  process.exit(1);
}

function* htmlFiles(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === "pagefind" || entry.name === "_astro") continue;
      yield* htmlFiles(full);
    } else if (entry.name.endsWith(".html")) yield full;
  }
}

const decode = (value) =>
  value
    .replaceAll("&quot;", '"')
    .replaceAll("&#39;", "'")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&amp;", "&");
const tags = (html, re) => [...html.matchAll(re)];

/** Site path of a built file: dist/docs/x/index.html -> /docs/x, dist/index.html -> /. */
function sitePath(file) {
  const r = rel(file).replaceAll(path.sep, "/");
  if (r === "index.html") return "/";
  return `/${r.replace(/\/index\.html$/, "").replace(/\.html$/, "")}`;
}

function collectIds(node, ids, refs) {
  if (Array.isArray(node)) return node.forEach((n) => collectIds(n, ids, refs));
  if (!node || typeof node !== "object") return;
  const keys = Object.keys(node);
  if (keys.length === 1 && keys[0] === "@id") refs.push(node["@id"]);
  else if (typeof node["@id"] === "string") ids.add(node["@id"]);
  for (const key of keys) if (key !== "@id") collectIds(node[key], ids, refs);
}

let pages = 0;
for (const file of htmlFiles(DIST)) {
  const where = rel(file);
  const html = fs.readFileSync(file, "utf8");
  pages += 1;
  const is404 = where === "404.html";
  // A pending snippet (website/snippets/*.ts with TODO(verify)) must never be embedded in a page.
  if (html.includes("TODO(")) fail(where, "contains a TODO( placeholder");

  // Redirect stubs (Astro `redirects`) are not pages.
  if (/<meta http-equiv="refresh"/i.test(html) && !/<title>/i.test(html)) continue;

  const titles = tags(html, /<title>([\s\S]*?)<\/title>/g);
  if (titles.length !== 1 || !titles[0][1].trim())
    fail(where, `expected exactly one non-empty <title>, found ${titles.length}`);
  const descriptions = tags(html, /<meta\s+name="description"\s+content="([^"]*)"/g);
  if (descriptions.length !== 1 || !descriptions[0][1].trim())
    fail(where, `expected exactly one non-empty meta description, found ${descriptions.length}`);

  const canonicals = tags(html, /<link\s+rel="canonical"\s+href="([^"]*)"/g);
  if (canonicals.length !== 1)
    fail(where, `expected exactly one canonical, found ${canonicals.length}`);
  else {
    const href = decode(canonicals[0][1]);
    const expected = sitePath(file) === "/" ? `${ORIGIN}/` : `${ORIGIN}${sitePath(file)}`;
    if (!href.startsWith(`${ORIGIN}/`) && href !== ORIGIN)
      fail(where, `canonical ${href} is not on ${ORIGIN}`);
    else if (href !== `${ORIGIN}/` && href.endsWith("/"))
      fail(where, `canonical ${href} has a trailing slash`);
    else if (!is404 && href !== expected)
      fail(where, `canonical ${href} does not match the page URL ${expected}`);
  }

  const robots = tags(html, /<meta\s+name="robots"\s+content="([^"]*)"/g).map((m) => m[1]);
  if (robots.length !== 1) fail(where, `expected exactly one robots meta, found ${robots.length}`);
  const noindex = robots.some((r) => /noindex/i.test(r));
  if (preview && !noindex) fail(where, "preview page is missing noindex");
  if (!preview && noindex && !is404) fail(where, "production page carries noindex");
  if (!preview && !noindex && !robots.some((r) => /max-image-preview:large/.test(r)))
    fail(where, "robots meta lacks max-image-preview:large");

  for (const prop of ["og:image", "twitter:image"]) {
    const m = html.match(new RegExp(`<meta\\s+(?:property|name)="${prop}"\\s+content="([^"]*)"`));
    if (!m || m[1] !== `${ORIGIN}/og/default.jpg`)
      fail(where, `${prop} must be ${ORIGIN}/og/default.jpg`);
  }

  // JSON-LD: parses, and every {"@id"} reference resolves on the page or to a global id.
  const ids = new Set();
  const refs = [];
  for (const [, body] of tags(
    html,
    /<script[^>]*type="application\/ld\+json"[^>]*>([\s\S]*?)<\/script>/g
  )) {
    try {
      collectIds(JSON.parse(body), ids, refs);
    } catch (error) {
      fail(where, `JSON-LD does not parse: ${error.message}`);
    }
  }
  for (const ref of refs)
    if (!ids.has(ref) && !GLOBAL_IDS.has(ref))
      fail(where, `JSON-LD @id reference ${ref} does not resolve`);
  for (const id of ids)
    if (id.includes("/#") || /^https:\/\/inderun\.dev\/[^#]*\/#/.test(id))
      fail(where, `@id ${id} has a trailing slash`);
  if (
    !is404 &&
    ids.size === 0 &&
    where !== "privacy.html" &&
    !where.startsWith("privacy/") &&
    where !== "imprint.html" &&
    !where.startsWith("imprint/") &&
    where !== "notices.html" &&
    !where.startsWith("notices/")
  )
    fail(where, "no JSON-LD entity found");
}

// Landing graph carries the four global entities.
{
  const html = fs.readFileSync(path.join(DIST, "index.html"), "utf8");
  for (const id of GLOBAL_IDS)
    if (!html.includes(`"@id":"${id}"`)) fail("index.html", `landing graph is missing ${id}`);
}

// Sitemap: the index points to exactly one website and one docs sitemap; every entry is dated.
const SITEMAPS = { "sitemap-website-0.xml": false, "sitemap-docs-0.xml": true };
const read = (f) =>
  fs.existsSync(path.join(DIST, f)) ? fs.readFileSync(path.join(DIST, f), "utf8") : "";
const entries = (xml, tag) =>
  [
    ...xml.matchAll(new RegExp(`<${tag}><loc>([^<]*)</loc>(?:<lastmod>([^<]*)</lastmod>)?`, "g"))
  ].map((m) => ({ loc: m[1], lastmod: m[2] }));
const wanted = new Set(readSitemapPaths().map((p) => `${ORIGIN}${p === "/" ? "/" : p}`));
const sitemapFiles = fs.readdirSync(DIST).filter((f) => /^sitemap-.*\.xml$/.test(f));
const expectedFiles = ["sitemap-index.xml", ...Object.keys(SITEMAPS)];
if (sitemapFiles.sort().join() !== [...expectedFiles].sort().join())
  fail("sitemap", `expected ${expectedFiles.join(", ")}, found ${sitemapFiles.join(", ")}`);
const indexed = entries(read("sitemap-index.xml"), "sitemap");
if (
  indexed.map((e) => e.loc).join() !==
  Object.keys(SITEMAPS)
    .map((f) => `${ORIGIN}/${f}`)
    .join()
)
  fail("sitemap-index.xml", `must list ${Object.keys(SITEMAPS).join(" and ")}`);
for (const e of indexed) if (!e.lastmod) fail("sitemap-index.xml", `${e.loc} has no <lastmod>`);
const lastmodManifest = JSON.parse(read("sitemap-lastmod-manifest.json") || '{"pages":{}}');
const locs = [];
for (const [file, docs] of Object.entries(SITEMAPS))
  for (const { loc, lastmod } of entries(read(file), "url")) {
    locs.push(loc);
    if (/^\/docs(\/|$)/.test(new URL(loc).pathname) !== docs)
      fail(file, `${loc} belongs in the ${docs ? "website" : "docs"} sitemap`);
    if (!lastmod) fail(file, `${loc} has no <lastmod>`);
    else if (lastmodManifest.pages[loc]?.lastmod !== lastmod)
      fail(file, `${loc} <lastmod> differs from sitemap-lastmod-manifest.json`);
  }
for (const loc of locs)
  if (!wanted.has(loc)) fail("sitemap", `${loc} is not in published-urls.txt`);
for (const loc of wanted) if (!locs.includes(loc)) fail("sitemap", `${loc} is missing`);
if (new Set(locs).size !== locs.length) fail("sitemap", "duplicate URLs");

// robots.txt.
{
  const robots = fs.readFileSync(path.join(DIST, "robots.txt"), "utf8");
  if (preview) {
    if (!/^Disallow: \/$/m.test(robots)) fail("robots.txt", "preview must Disallow: /");
  } else {
    if (!/^Allow: \/$/m.test(robots)) fail("robots.txt", "production must Allow: /");
    if (/^Disallow: \/\s*$/m.test(robots)) fail("robots.txt", "production must not Disallow: /");
    if (!robots.includes(`Sitemap: ${ORIGIN}/sitemap-index.xml`))
      fail("robots.txt", "missing Sitemap line");
  }
}

// llms.txt: H1, blockquote, only built published pages.
{
  const llms = fs.readFileSync(path.join(DIST, "llms.txt"), "utf8");
  if (!llms.startsWith("# IndeRun\n")) fail("llms.txt", 'must start with "# IndeRun"');
  if (!/^> .+/m.test(llms)) fail("llms.txt", "missing blockquote summary");
  const allowed = new Set(readSitemapPaths().map((p) => `${ORIGIN}${p}`));
  const linked = [...llms.matchAll(/\]\((https?:[^)]+)\)/g)].map((m) => m[1]);
  for (const url of linked) {
    if (!allowed.has(url)) fail("llms.txt", `${url} is not a published URL`);
    const p = url.slice(ORIGIN.length) || "/";
    const built = p === "/" ? "index.html" : `${p.slice(1)}/index.html`;
    if (
      !fs.existsSync(path.join(DIST, built)) &&
      !fs.existsSync(path.join(DIST, `${p.slice(1)}.html`))
    )
      fail("llms.txt", `${url} is not a built page`);
  }
  for (const p of [...readDocsPaths(), "/"])
    if (!linked.includes(`${ORIGIN}${p}`)) fail("llms.txt", `missing ${p}`);
}

if (errors.length) {
  console.error(
    `verify-seo: ${errors.length} problem(s) in ${path.relative(process.cwd(), DIST) || "."}`
  );
  for (const e of errors.slice(0, 50)) console.error(`  - ${e}`);
  process.exit(1);
}
console.log(
  `verify-seo: ok (${pages} pages, ${locs.length} sitemap URLs, ${preview ? "preview" : "production"})`
);
