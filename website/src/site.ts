/**
 * Site-wide constants for the hand-built pages (landing, imprint, notices, privacy). Docs pages get their
 * links from Starlight and the remark plugins instead. Every site path has no trailing slash
 * (`trailingSlash: 'never'`).
 */
import versions from "../versions.json";
import { pinnedRepoUrl } from "../docs-architecture.mjs";

/** `SITE_ENV=preview` builds (PRs, dev) carry draft pages and are noindex. */
export const isPreview = process.env.SITE_ENV === "preview";

/**
 * Google Analytics 4: the web stream "inderun.dev" of the Firebase project inderun-landingpage.
 * It runs cookieless until the visitor accepts cookies (src/components/Consent.astro) and only on
 * `host`, so preview channels and local builds never send data.
 */
export const ANALYTICS = { measurementId: "G-MZ8Y963XQZ", host: "inderun.dev" } as const;

const plugin = versions.capacitorPlugin;
const REPOSITORY = "https://github.com/independo-gmbh/inderun";

export const LINKS = {
  home: "/",
  docs: "/docs",
  quickstart: "/docs/getting-started/capacitor",
  routing: "/docs/concepts/routing-and-privacy",
  compatibility: "/docs/platforms/compatibility",
  speech: "/docs/guides/speech",
  imprint: "/imprint",
  notices: "/notices",
  privacy: "/privacy",
  repository: REPOSITORY,
  /** The MIT licence, pinned to the core release tag like the docs sidebar's "License (MIT)". */
  license: pinnedRepoUrl("LICENSE", { tag: versions.core.tag }),
  capacitorRepository: plugin.repository,
  npmCapacitor: `https://www.npmjs.com/package/${plugin.package}`,
  independo: "https://www.independo.app/",
  independoOpenSource: "https://www.independo.app/open-source",
  independoImprint: "https://www.independo.app/legal/imprint",
  independoContact: "https://www.independo.app/contact",
  netidee: "https://www.netidee.at/inderun"
} as const;

/**
 * The pair the landing snippet is type-checked against (`pnpm check:snippets`): the released
 * Capacitor plugin and the IndeRun core it bundles. Read from versions.json, never typed here.
 */
export const HERO_SNIPPET_PAIR = {
  pluginPackage: plugin.package,
  pluginVersion: plugin.version,
  pluginSourceUrl: `${plugin.repository}/blob/${plugin.tag}/src/index.ts`,
  coreVersion: plugin.pinsCore,
  coreReleaseUrl: `${REPOSITORY}/releases/tag/v${plugin.pinsCore}`
} as const;
