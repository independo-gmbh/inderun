/** Types for the plain ESM module shared by astro.config.mjs, the content loader and the Node scripts. */
export const WEBSITE_DIR: string;
export const REPO_ROOT: string;
export const SITE: string;
export const REPOSITORY: string;
export const PUBLISHED_DIRS: string[];
export const PUBLISHED_GLOBS: string[];
export function isPublishedDoc(repoRelativePath: string): boolean;
export function sitePathForDoc(repoRelativePath: string): string;
export function readFrontMatterSlug(absolutePath: string): string | undefined;
export interface Versions {
  mode: string;
  testedAt: string;
  core: { version: string; tag: string; npmDistTag: string };
  packages: Record<string, string>;
  capacitorPlugin: {
    package: string;
    version: string;
    tag: string;
    repository: string;
    pinsCore: string;
    capacitor: string;
  };
  swift: { url: string; version: string };
  kotlin: { group: string; artifact: string; version: string };
}
export function readVersions(): Versions;
export function pinnedRepoUrl(
  repoRelativePath: string,
  options?: { tag?: string; directory?: boolean }
): string;
