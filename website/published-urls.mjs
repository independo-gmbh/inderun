/**
 * The URLs that are the site's public surface: the landing page, the nine docs destinations in
 * published-urls.txt (one path per line, no trailing slash), the imprint, the privacy notice and the notices page. The sitemap, llms.txt
 * and the SEO verifier all read this one list. Generated API sub-pages and /privacy are not in it.
 *
 * `parseDocsPaths` is pure so the llms.txt endpoint can use it on the `?raw` import of the file
 * (the build bundles endpoints, so they cannot read the file system relative to this module).
 */
import fs from "node:fs";
import path from "node:path";
import { WEBSITE_DIR } from "./docs-architecture.mjs";

export const LANDING_PATH = "/";
export const IMPRINT_PATH = "/imprint";
export const NOTICES_PATH = "/notices";
export const PRIVACY_PATH = "/privacy";

export function parseDocsPaths(text) {
  return text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("#"));
}

export function readDocsPaths() {
  return parseDocsPaths(fs.readFileSync(path.join(WEBSITE_DIR, "published-urls.txt"), "utf8"));
}

/** Every path that belongs in the sitemap, in sitemap order. */
export function readSitemapPaths() {
  return [LANDING_PATH, ...readDocsPaths(), IMPRINT_PATH, PRIVACY_PATH, NOTICES_PATH];
}
