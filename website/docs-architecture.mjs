/**
 * The publication rule for the documentation, in one place. The content loader, the link
 * rewriter and the CI checks all import it, so "which docs are on inderun.dev" cannot be
 * answered differently by different tools. See
 * docs/architecture/decisions/024-documentation-architecture.md.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const WEBSITE_DIR = path.dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = path.resolve(WEBSITE_DIR, "..");

export const SITE = "https://inderun.dev";
export const REPOSITORY = "https://github.com/independo-gmbh/inderun";

/**
 * Published docs live in these folders under `docs/` (plus `docs/index.md`). Everything else
 * under `docs/` is internal: it renders on GitHub and never reaches the site.
 */
export const PUBLISHED_DIRS = ["getting-started", "concepts", "guides", "platforms", "api"];

/** Glob patterns, relative to the repository root, for the Starlight `docs` collection. */
export const PUBLISHED_GLOBS = [
  "docs/index.md",
  `docs/{${PUBLISHED_DIRS.join(",")}}/**/[^_]*.md`,
  // Generated TypeDoc output (gitignored); starlight-typedoc can only write here.
  "website/src/content/docs/**/[^_]*.md"
];

/** True when a repository-relative POSIX path is a published doc page. */
export function isPublishedDoc(repoRelativePath) {
  if (repoRelativePath === "docs/index.md") return true;
  const [top, dir, ...rest] = repoRelativePath.split("/");
  return (
    top === "docs" &&
    PUBLISHED_DIRS.includes(dir) &&
    rest.length > 0 &&
    repoRelativePath.endsWith(".md")
  );
}

/** Site path for a published doc, without a trailing slash (the site uses `trailingSlash: 'never'`). */
export function sitePathForDoc(repoRelativePath) {
  const slug = readFrontMatterSlug(path.join(REPO_ROOT, repoRelativePath));
  if (!slug)
    throw new Error(`${repoRelativePath} is in a published folder but has no front-matter slug`);
  return `/${slug}`;
}

const slugCache = new Map();
export function readFrontMatterSlug(absolutePath) {
  if (slugCache.has(absolutePath)) return slugCache.get(absolutePath);
  let slug;
  try {
    const text = fs.readFileSync(absolutePath, "utf8");
    const match = /^---\r?\n([\s\S]*?)\r?\n---/.exec(text);
    slug = match ? /^slug:\s*["']?([^"'\n]+?)["']?\s*$/m.exec(match[1])?.[1] : undefined;
  } catch {
    slug = undefined;
  }
  slugCache.set(absolutePath, slug);
  return slug;
}

export function readVersions() {
  return JSON.parse(fs.readFileSync(path.join(WEBSITE_DIR, "versions.json"), "utf8"));
}

/** GitHub URL for a repository file, pinned to the core release tag in versions.json. */
export function pinnedRepoUrl(
  repoRelativePath,
  { tag = readVersions().core.tag, directory = false } = {}
) {
  return `${REPOSITORY}/${directory ? "tree" : "blob"}/${tag}/${repoRelativePath}`;
}
