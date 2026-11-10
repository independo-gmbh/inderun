# ADR 024 — Documentation architecture

## Status

Accepted. Recorded for the inderun.dev website. It sets where documentation lives, how the site reads it, and which
checks keep the repository, the site and the Capacitor plugin repository from drifting apart.

## Context

The repository's documentation is read in two places: on GitHub, by contributors, and on [inderun.dev](https://inderun.dev),
by developers who want to adopt IndeRun. The two audiences need different things. Contributors need ADRs, conformance
records, CI notes and plans. Adopters need a short path from install to a first result, a precise account of the privacy
rules and the platform limits, and an API reference.

Three failure modes motivate this decision:

- **Copies drift.** A site that keeps its own copy of the docs is wrong the day a contract changes.
- **Examples rot.** Code samples that nothing compiles stop matching the released packages.
- **Internal material leaks.** A site that publishes "everything under `docs/`" puts plans, ADRs and verification
  records in front of adopters and into search results.

The site is a separate Astro + Starlight project in `website/`. The docs stay where contributors already edit them.

## Decision

### Folder equals audience

`docs/index.md` and the pages under `docs/{getting-started,concepts,guides,platforms,api}/` are **published**. Every
other file under `docs/` (`architecture/`, `architecture/decisions/`, `superpowers/`, `verification/`, `ci.md`,
`release.md`, the conformance and migration files, and so on) is **internal**: it renders on GitHub and never reaches the
site. To publish a page, create or move it into a published folder and give it front matter. To unpublish, move it out.
The rule lives in one module, `website/docs-architecture.mjs`; the content loader, the link rewriter and the CI checks all
import it, so "which docs are on the site" has one answer.

### Loader: the content layer reads `../docs` (option a)

The site's `docs` collection uses a `glob({ base: '..' })` loader over the published patterns, with Starlight's
`docsSchema()` extended with an optional `description` capped at 155 characters (generated API pages have none and get
one in route middleware). The collection schema does not make `slug` or `description` mandatory; `check:docs` does, for
every published doc. Internal docs must carry no `slug`. The docs stay in `docs/`; the site has no copy.

Spike evidence (an isolated project on Astro 7.4.8 and Starlight 0.42.10):

- The glob over `../docs` built the expected URLs with the internal files absent.
- The remark rewriter turned `../contracts/…` into `blob/<tag>/…`.
- `starlight-links-validator` works for out-of-tree files only when each page sets a front-matter `slug` (otherwise it
  derives page ids from `src/content/docs`). With the slug it caught a bad `#hash`. Generated ids had to be lowercased.
- Two `starlight-typedoc` instances ran from the published `.d.ts` files: 165 pages, all links valid.
- Astro 7 needs `@astrojs/markdown-remark` installed for remark plugins to run.
- `starlight-typedoc` always emits trailing slashes; the rewriter normalises them.
- Starlight's aside transform runs before user remark plugins, so GitHub alerts are rendered to aside markup directly by
  `website/plugins/remark-github-alerts.mjs`.

Rejected alternatives:

- **(b) Symlink `website/src/content/docs` to `docs/`.** It is fragile on Windows and in some CI checkouts, git handles
  symlinks inconsistently across platforms, and the validator still needs the slug.
- **(c) Copy-sync the docs into the site at build time.** It creates the second copy this architecture exists to
  prevent, and a stale copy is committed or silently rebuilt.

### The slug is the URL

Each published page carries `slug: docs/…`. The URL therefore does not depend on where the file sits, a page can be
moved within the published folders without changing its address, and `website/published-urls.txt` lists the public
destinations that the sitemap, `llms.txt` and the SEO verifier share. The site uses `trailingSlash: 'never'`: no URL ends
in a slash.

### Sitemap

`/sitemap-index.xml` (also reachable as `/sitemap.xml`, a 301 in `firebase.json`) points to two sitemaps:
`sitemap-website-0.xml` for the landing and legal pages, and `sitemap-docs-0.xml` for the docs destinations. Each
`<lastmod>` is the time the page's _content_ last changed, as on independo.app: the build hashes what a reader sees of
each page and keeps the date from the previous deploy's `sitemap-lastmod-manifest.json`, fetched from the live site,
while the hash is unchanged (`website/plugins/sitemap-lastmod.mjs`). A rebuild, a dependency update or a style change
therefore does not move the dates; an edited sentence, heading or link does. When the live manifest cannot be fetched,
every page gets the build time, which is still a valid date, only less precise.

### Links and pinned tags

Docs use relative Markdown links, so they work on GitHub unchanged. `website/plugins/remark-repo-links.mjs` rewrites them at build time: a link to
a published page becomes its site path; a link to any other repository file becomes
`github.com/independo-gmbh/inderun/blob/<tag>/…` (`tree` for directories), with the tag taken from `website/versions.json`
(`core.tag`). Links into the Capacitor plugin repository are written with the plugin tag (`capacitorPlugin.tag`).
**No published page links to a branch** (`dev` or `main`): a branch link changes meaning on the next merge.

The single exception, an owner decision, is Starlight's "Edit page" link, which points at
`github.com/independo-gmbh/inderun/edit/dev/docs/…`. Edits are made on `dev`, so that is the correct target, and the
link says what it does. No other `/edit/dev/` link and no `/edit/main/` link is allowed.

### Snippets and version markers

Every code sample on the site is a file in `website/snippets/`, type-checked with `tsc --noEmit` against the exact npm
versions in `versions.json`. A block `<!-- snippet:NAME -->` … `<!-- /snippet -->` in a doc or README is filled from
its file by `website/scripts/sync-markers.mjs`, and `--check` fails when a block differs. Version facts use
`<!-- version:NAME -->` … `<!-- /version -->` blocks rendered from `versions.json`. Prose never hard-codes a version. A
snippet that depends on an API that has not shipped carries `TODO(verify)`, is excluded from the type-check and is
reported as pending. `check:snippets:release` (`check-snippets.mjs --release`) fails while any pending snippet remains;
passing it is the precondition for a production deploy, which CI does not yet run.

### `versions.json` is the single source

The core version and tag, the three npm package versions, the plugin version and tag (and the core it pins), and the
Swift and Kotlin coordinates live in `website/versions.json`. The tested set, the install lines, the snippet type-check
and the link tags all derive from it. `check:versions` compares it with `website/package.json` and, against the npm
registry, with the dependencies the plugin version declares. In prerelease mode a mismatch warns (the plugin may pin an
older core); in release mode it fails.

`pnpm-workspace.yaml` exempts `@independo/*` from the `minimumReleaseAge` gate, so the site can pin a release published
the same day. The trade-off: a compromised first-party publish would not be held back by the age gate.

### API reference from the published types

The API pages are generated by `starlight-typedoc` from the `dist/*.d.ts` files of the published npm packages
(`@independo/capacitor-inderun` and `@independo/inderun-web`), not from the repository sources, so the reference
describes what developers install. Output goes to `website/src/content/docs/docs/api/typescript/{capacitor,web}`, which
is gitignored. `website/api-snapshot/` records the export list; `check:api` fails when a version bump changes it without
the snapshot being regenerated (`update:api`).

### Generated pages are not committed

Generated pages (the TypeDoc output) are build artefacts. Only the hand-written entry page `docs/api/typescript.md` is
in version control.

### Privacy notice

`/privacy` (`website/src/pages/privacy.astro`) was published on 10 November 2026 after legal review. It is one of the
three legal pages in the sitemap, the footer and `llms.txt`. It describes exactly what the hosting and the analytics
code do, so a change to either updates the notice and its date in the same change.

### Analytics with a consent banner

The site measures page views with Google Analytics 4 (the web stream of the Firebase project `inderun-landingpage`) in
Google's advanced Consent Mode, by owner decision. The tag loads on every visit with analytics storage denied: before
the visitor chooses, and after declining, it sets no cookies and sends cookieless pings without a client id. Accepting in
the consent banner (`website/src/components/Consent.astro`) grants analytics storage, which adds the `_ga` cookies.
Advertising storage, ad user data and ad personalisation stay denied. Accept and Decline carry the same weight, and a
"Cookie settings" button in the footer reopens the banner. A browser that sends Global Privacy Control objects to the
cookieless pings: the tag is not loaded at all until that visitor accepts cookies. The cookieless pings rest on
legitimate interest, with Global Privacy Control as the objection route; legal review approved this before the privacy
notice was published. The tag loads only on `inderun.dev`, so preview channels and local builds never send data.

### Hosting

The site is static output (`website/dist`) served by Firebase Hosting with `cleanUrls: true` and
`trailingSlash: false` (`website/firebase.json`). Every response is revalidated on every request by default; content-hashed assets are
immutable: `/_astro/`, and Pagefind's `fragment/`, `index/` and `pagefind.<hash>.pf_meta`. Pagefind's fixed-name files
(`pagefind.js`, `pagefind-ui.*`, `pagefind-entry.json`, `wasm.*.pagefind`) keep the revalidating default so a deploy
never serves a stale search index. The redirect of `inderun.com` and `www.inderun.com` to `https://inderun.dev`
(301) is **a domain setting in the hosting console, not a rule in `firebase.json`**: it belongs to the domain
registration and does not change with a deploy.

Production builds from the stable line (`main`); previews build from `dev` and pull requests. Until v0.5.0 is released
the site goes live from `dev` instead, by owner decision, so it is public before the first stable release; the release
change moves the live deploy to `main`. The `deploy` job of `website.yml` publishes them (see CI checks). Responses carry security headers (Firebase Hosting sets `Strict-Transport-Security` itself;
`firebase.json` adds `X-Content-Type-Options`, `Referrer-Policy`, `Permissions-Policy`, `X-Frame-Options` and a `Content-Security-Policy`
limited to `frame-ancestors`, `base-uri`, `form-action`, `object-src` and `upgrade-insecure-requests`). A script policy
is not set: Starlight's inline scripts and the Google Analytics tag would need hashes or nonces kept in step with every
build.

### CI checks

`.github/workflows/website.yml` runs on pull requests and pushes that touch the site, the docs, the READMEs, the
contracts or the Web SDK entry point. Its `website` job runs these steps, in order:

1. `astro check`.
2. `check:markers` — snippet and version blocks match their sources.
3. `check:snippets` — snippets type-check against the pinned packages.
4. `check:api` — the export list matches the committed snapshot.
5. `check:versions` — `versions.json` agrees with the package pins and the npm registry (warnings allowed).
6. `build` — includes `starlight-links-validator`, which fails on a broken link or anchor.
7. `check:docs` (`website/scripts/check-docs-architecture.mjs`):
   - every published doc has front matter with a unique `slug` under `docs`, a `title` and a `description` of at most 155
     characters;
   - published docs and `published-urls.txt` agree in both directions;
   - no file outside the published folders declares a `slug`;
   - no internal doc leaks into `dist/` (neither its H1 title as a page title or heading, nor the URL derived from its
     path), the sitemap or `llms.txt`;
   - no `blob` or `tree` link to `dev` or `main` and no `/edit/main/`; `/edit/dev/` appears only in Starlight's edit link
     for a published doc;
   - every `blob`/`tree` link to this repository uses `core.tag`, and every one to `capacitor-inderun` uses
     `capacitorPlugin.tag`.
8. `verify:seo` — one title, description, canonical (no trailing slash) and robots meta per page, JSON-LD whose
   references resolve, the sitemap index with its website and docs sitemaps limited to `published-urls.txt`, every
   entry dated from the lastmod manifest, and `llms.txt`.
9. `build:preview` and `verify-seo-output.mjs --preview` — every preview page is `noindex` and `robots.txt` disallows all.

The `deploy` job then publishes the checked build to Firebase Hosting: a push to the live branch (`dev` until v0.5.0,
then `main`) deploys the production build live, a push to the other long-lived branch deploys the preview build to a
channel named after it, and a pull request from this repository gets its own preview channel, linked in a comment. Pull requests from forks and Dependabot are skipped, and so is every run until
the `FIREBASE_SERVICE_ACCOUNT_INDERUN_LANDINGPAGE` secret is configured.

CI cannot check real-device behaviour. Device results are dated records in `docs/verification/`, written from
[the template](../../verification/website-launch-template.md); the site makes no device-verified claim without one.

### READMEs stay entry points

The repository and package READMEs remain short entry points that name the install line and link to the site. Their
install lines and code blocks are snippet and version markers, so they cannot differ from the site. Per-platform pages
could later pull a package README through the same loader; that is not built.

### Cross-repository: `capacitor-inderun`

The plugin repository's README stays authoritative for bridge setup. The site links to it at the pinned plugin tag
(`capacitorPlugin.tag`) and repeats only the exact build-failure strings, so a reader who searches for an error finds the
cause. Proposal, **not implemented**: the plugin repository adopts the same snippet and marker mechanism, so its README
examples are compiled against its own pins and the site can reuse them. That needs a decision in that repository.

## Consequences

- One copy of each document. Contributors edit `docs/` as before; the site cannot disagree with it.
- Moving a file between published and internal folders is the whole publish decision, and a leak is a failing check
  rather than a review catch.
- Examples and versions cannot silently rot: they are compiled against, and generated from, the pinned releases. The
  cost is that a release bump is a deliberate change to `versions.json` and, if the API moved, to the snapshot.
- Linking to a tag means a link to a file added after the last release points at a path that does not exist at that tag
  until the next release. During a prerelease that is visible; it is the price of never linking to a moving branch.
- The slug requirement and the lowercase-id rule are properties of the validator, not of the docs. Authors must set a
  slug on every published page.
- Docs for released-but-unversioned behaviour live on one URL. Versioned docs are a later decision, to be made if a
  breaking release makes two versions current at once.
