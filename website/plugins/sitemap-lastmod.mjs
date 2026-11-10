/**
 * Sitemap `<lastmod>` dates that change only when a page's content changes, not on every build.
 * Ported from the independo.app website (Scripts/update-sitemap-lastmod.mjs there).
 *
 * After the build, every sitemap page's HTML is reduced to a content record: the text of `<main>`
 * without its header, footer, nav, scripts and styles, plus its headings, links, images and the
 * page's JSON-LD. The record's SHA-256 is compared with the manifest of the previous deploy,
 * fetched from the live site (`/sitemap-lastmod-manifest.json`). An unchanged hash keeps the
 * previous date; a new or changed one gets the build time. Asset hashes, theme scripts and other
 * markup churn therefore do not move the date, but a changed sentence, heading or link does.
 *
 * The baseline comes from `SITEMAP_LASTMOD_BASELINE` (a URL or a file path) when set, else from the
 * live manifest, else from the copy the last local build left in Astro's cache directory. With none,
 * every page gets the build time. `SITEMAP_LASTMOD_BUILD_AT` pins the build time (ISO 8601).
 *
 * Use the returned `integration` before `@astrojs/sitemap` in `integrations` (hooks run in order)
 * and pass `serialize` to the sitemap integration.
 */
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { fromHtml } from "hast-util-from-html";
import { select, selectAll } from "hast-util-select";
import { toString } from "hast-util-to-string";

export const MANIFEST_FILE = "sitemap-lastmod-manifest.json";
const FETCH_TIMEOUT_MS = 5000;
const IGNORED = new Set(["footer", "header", "nav", "script", "style", "template", "noscript"]);

const text = (node) => (node ? toString(node) : "").replace(/\s+/g, " ").trim();

function prune(node) {
  if (!node.children) return;
  node.children = node.children.filter(
    (child) => child.type !== "element" || !IGNORED.has(child.tagName)
  );
  node.children.forEach(prune);
}

function sortKeys(value) {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value !== null && typeof value === "object")
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, sortKeys(value[key])])
    );
  return value;
}

/** What a reader or a search engine sees of the page; everything else is left out of the hash. */
export function contentRecord(html) {
  const tree = fromHtml(html);
  const structuredData = selectAll('script[type="application/ld+json"]', tree).map((script) =>
    sortKeys(JSON.parse(toString(script)))
  );
  const main = select("main", tree);
  if (!main) throw new Error("cannot hash a page without a <main> element");
  prune(main);

  const figureOf = new Map();
  for (const figure of selectAll("figure", main))
    for (const image of selectAll("img", figure)) figureOf.set(image, figure);
  const linkOf = new Map();
  for (const link of selectAll("a", main))
    for (const image of selectAll("img", link)) linkOf.set(image, link);

  return {
    mainText: text(main),
    headings: selectAll("h1, h2, h3, h4, h5, h6", main).map((heading) => ({
      level: heading.tagName,
      text: text(heading)
    })),
    links: selectAll("a", main).map((link) => ({
      label:
        [link.properties.ariaLabel, text(link), link.properties.title]
          .map((label) => String(label ?? "").trim())
          .find(Boolean) ?? "",
      href: String(link.properties.href ?? "")
    })),
    images: selectAll("img", main).map((image) => ({
      alt: String(image.properties.alt ?? "").trim(),
      title: String(image.properties.title ?? "").trim(),
      caption: text(figureOf.has(image) ? select("figcaption", figureOf.get(image)) : undefined),
      linkHref: String(linkOf.get(image)?.properties.href ?? "")
    })),
    structuredData
  };
}

export function contentHash(html) {
  return crypto
    .createHash("sha256")
    .update(JSON.stringify(contentRecord(html)))
    .digest("hex");
}

/** The previous date survives only while the content hash is the same. */
export function resolveLastmod(baselinePage, hash, buildAt) {
  return baselinePage?.contentHash === hash && typeof baselinePage.lastmod === "string"
    ? baselinePage.lastmod
    : buildAt;
}

const isManifest = (value) => Boolean(value?.pages && typeof value.pages === "object");

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

async function fetchJson(url) {
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) });
    return response.ok ? await response.json() : null;
  } catch {
    return null;
  }
}

async function loadBaseline(site, cacheFile) {
  const override = process.env.SITEMAP_LASTMOD_BASELINE;
  const candidates = override ? [override] : [new URL(`/${MANIFEST_FILE}`, site).href, cacheFile];
  for (const source of candidates) {
    const manifest = /^https?:/.test(source) ? await fetchJson(source) : readJson(source);
    if (isManifest(manifest)) return { manifest, source };
  }
  return { manifest: { pages: {} }, source: "none" };
}

/**
 * @param {{ site: string, paths: string[] }} options The site origin and the sitemap's paths
 *   (no trailing slash; "/" for the landing page).
 */
export function sitemapLastmod({ site, paths }) {
  const lastmods = new Map();
  let cacheFile;

  return {
    integration: {
      name: "inderun:sitemap-lastmod",
      hooks: {
        "astro:config:done": ({ config }) => {
          cacheFile = path.join(fileURLToPath(config.cacheDir), MANIFEST_FILE);
        },
        "astro:build:done": async ({ dir, logger }) => {
          const outDir = fileURLToPath(dir);
          const { manifest: baseline, source } = await loadBaseline(site, cacheFile);
          const buildAt = process.env.SITEMAP_LASTMOD_BUILD_AT ?? new Date().toISOString();
          const pages = {};
          let kept = 0;
          for (const pagePath of paths) {
            const url = new URL(pagePath, site).href;
            const file = path.join(outDir, pagePath === "/" ? "" : pagePath, "index.html");
            if (!fs.existsSync(file)) throw new Error(`sitemap-lastmod: no built page for ${url}`);
            const hash = contentHash(fs.readFileSync(file, "utf8"));
            const lastmod = resolveLastmod(baseline.pages[url], hash, buildAt);
            if (baseline.pages[url]?.contentHash === hash) kept++;
            pages[url] = { contentHash: hash, lastmod };
            lastmods.set(url, lastmod);
          }
          const manifest = `${JSON.stringify({ version: 1, site, buildAt, baselineSource: source, pages }, null, 2)}\n`;
          fs.writeFileSync(path.join(outDir, MANIFEST_FILE), manifest);
          fs.mkdirSync(path.dirname(cacheFile), { recursive: true });
          fs.writeFileSync(cacheFile, manifest);
          logger.info(
            `${paths.length} pages, ${kept} dates kept from the baseline (${source}), ${paths.length - kept} set to ${buildAt}`
          );
        }
      }
    },
    serialize: (item) => {
      const lastmod = lastmods.get(item.url);
      if (!lastmod) throw new Error(`sitemap-lastmod: no date for ${item.url}`);
      return { ...item, lastmod };
    }
  };
}
