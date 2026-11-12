/**
 * The URLs that are the site's public surface: the landing page, the nine docs destinations in
 * published-urls.txt (one path per line, no trailing slash), the imprint, the privacy notice and the notices page. The sitemap, llms.txt
 * and the SEO verifier all read this one list. The generated API reference pages are not in it: they
 * exist only after the build, so the sitemap finds them in the output (`findApiReferencePaths`) and
 * lists them in a sitemap of their own; llms.txt leaves them out.
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

/** The TypeDoc output directories under /docs/api/typescript, one per package. */
const API_REFERENCE_DIRS = ["docs/api/typescript/capacitor", "docs/api/typescript/web"];

/** True for a path inside the generated API reference (not the /docs/api/typescript overview). */
export function isApiReferencePath(pathname) {
  return API_REFERENCE_DIRS.some(
    (dir) => pathname === `/${dir}` || pathname.startsWith(`/${dir}/`)
  );
}

/** Every generated API reference page in a build's output directory, sorted, no trailing slash. */
export function findApiReferencePaths(outDir) {
  return API_REFERENCE_DIRS.flatMap((dir) => {
    const root = path.join(outDir, dir);
    if (!fs.existsSync(root)) return [];
    return fs
      .readdirSync(root, { recursive: true })
      .filter((file) => path.basename(file) === "index.html")
      .map((file) => `/${path.posix.join(dir, path.dirname(file).split(path.sep).join("/"))}`);
  }).sort();
}

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
