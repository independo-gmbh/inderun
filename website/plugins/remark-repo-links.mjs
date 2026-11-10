/**
 * Rewrites relative links in docs Markdown at build time, so one file works on GitHub and on
 * inderun.dev:
 *
 * - a link to another published doc becomes that page's site path (from its `slug`);
 * - a link to any other repository file (contracts/, packages/, an internal doc, ...) becomes a
 *   GitHub URL pinned to the core release tag in versions.json, never a branch.
 *
 * Absolute URLs and same-page anchors are left alone. Site-absolute paths lose a trailing slash,
 * because the site uses `trailingSlash: 'never'` and starlight-typedoc always emits one.
 */
import fs from "node:fs";
import path from "node:path";
import { visit } from "unist-util-visit";
import { REPO_ROOT, isPublishedDoc, pinnedRepoUrl, sitePathForDoc } from "../docs-architecture.mjs";

const SCHEME = /^[a-z][a-z0-9+.-]*:/i;

export default function remarkRepoLinks({ tag } = {}) {
  return (tree, file) => {
    const from = file.path ?? file.history?.[0];
    if (!from) return;
    const fromRepo = path.relative(REPO_ROOT, from).split(path.sep).join("/");

    visit(tree, ["link", "definition"], (node) => {
      const url = node.url;
      if (!url || SCHEME.test(url) || url.startsWith("#")) return;
      if (url.startsWith("/")) {
        node.url = url.replace(/(.)\/(#|$)/, "$1$2");
        return;
      }
      // Only docs/ sources are written for GitHub; generated pages already use site paths.
      if (!fromRepo.startsWith("docs/")) return;
      const hashIndex = url.indexOf("#");
      const target = hashIndex === -1 ? url : url.slice(0, hashIndex);
      const hash = hashIndex === -1 ? "" : url.slice(hashIndex);
      const absolute = path.resolve(path.dirname(from), decodeURI(target));
      const repoPath = path.relative(REPO_ROOT, absolute).split(path.sep).join("/");
      if (repoPath.startsWith("..")) {
        file.fail(`Link "${url}" leaves the repository`, node);
      }
      if (isPublishedDoc(repoPath)) {
        node.url = sitePathForDoc(repoPath) + hash;
        return;
      }
      // A pinned GitHub URL to a file that does not exist would 404, and the links validator only
      // checks site paths, so a wrong relative path would otherwise ship silently.
      if (!fs.existsSync(absolute)) {
        file.fail(
          `Link "${url}" points to "${repoPath}", which does not exist in the repository`,
          node
        );
      }
      const isDirectory = fs.statSync(absolute).isDirectory();
      node.url = pinnedRepoUrl(repoPath.replace(/\/$/, ""), { tag, directory: isDirectory }) + hash;
    });
  };
}
