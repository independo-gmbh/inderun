# Contributing

IndeRun is a code-first repository. External markdown should explain concepts and usage, but implementation detail
should live in code comments, schemas, and generated public types whenever possible.

## Before You Start

- Read `AGENTS.md`.
- Read the architecture brief, architecture overview, provider overview, and CI notes.
- Check the existing package or platform README before changing a public surface.

## Prerequisites

The repository spans four toolchains. Install only the ones you need: each language's commands, tests, and
CI workflow are independent, so you can contribute to the TypeScript packages without a Swift or Android
toolchain installed.

| Area                | Requirement                                                                     |
| ------------------- | ------------------------------------------------------------------------------- |
| TypeScript packages | Node `24.x` (see `.nvmrc`), pnpm `11.9.0` (`corepack enable`)                   |
| Rust core           | Rust stable via `rustup`                                                        |
| Web route planner   | `wasm32-unknown-unknown` target and `wasm-bindgen-cli` (version-matched, below) |
| Android library     | JDK 21, Android SDK platforms 36 and 37 (demo app), `ANDROID_HOME` exported     |
| Swift SDK           | Swift 5.9+ toolchain; SwiftLint for `pnpm format:swift` / lint                  |

### Rust and the WASM route planner

`pnpm build` builds `@independo/inderun-web-demo`, which bundles the route planner compiled to WebAssembly.
The bindings under `packages/inderun-route-core-wasm/generated/` are build artifacts and are not checked in,
so a fresh clone must generate them once before the first `pnpm build`, otherwise the bundler fails with
`Could not resolve '../generated/inderun_route_core.js'`.

Install the toolchain. The `wasm-bindgen-cli` version must match the `wasm-bindgen` version in `Cargo.lock`,
or the generated bindings will be rejected at runtime, so take it from the lockfile rather than pinning a
copy that a dependency bump can leave behind:

```sh
rustup target add wasm32-unknown-unknown
cargo install wasm-bindgen-cli --version "$(node scripts/wasm-bindgen-version.mjs)" --locked
```

Then generate the bindings. `pnpm build:wasm` is the shipped build: it uses the size-optimised `wasm` cargo profile
(a release build) for both modules. The manual commands below are plain debug builds for local iteration; their output
exceeds the size gate and is not what ships.

```sh
RUSTC="$(rustup which rustc --toolchain stable)" rustup run stable \
  cargo build -p inderun_route_core --target wasm32-unknown-unknown --no-default-features
wasm-bindgen target/wasm32-unknown-unknown/debug/inderun_route_core.wasm \
  --target web --out-dir packages/inderun-route-core-wasm/generated \
  --out-name inderun_route_core

RUSTC="$(rustup which rustc --toolchain stable)" rustup run stable \
  cargo build -p inderun_route_core --target wasm32-unknown-unknown \
  --no-default-features --features speech-text --target-dir target/wasm-speech-text
wasm-bindgen target/wasm-speech-text/wasm32-unknown-unknown/debug/inderun_route_core.wasm \
  --target web --out-dir packages/inderun-route-core-wasm/generated \
  --out-name inderun_speech_text
```

Re-run these commands (or `pnpm build:wasm`, which does both as release builds) whenever the Rust core changes.

After `pnpm build:wasm`, run `pnpm check:wasm-size`. It reads both `*_bg.wasm` modules, prints
`<module> raw=<bytes> gzip=<bytes> budget=<raw>/<gzip>` for each and exits 1 when either number is over its budget.
The budgets live in `scripts/check-wasm-size.mjs`; raise one only in the change that grows the module. CI runs the
check after the build.

`wasm-bindgen` also overwrites `generated/inderun_route_core.d.ts` and `inderun_speech_text.d.ts`, which are checked in as stubs so `tsc` resolves without the Rust toolchain. The regenerated file drops that stub's explanatory
header, so revert it before committing unless the route-core API actually changed:

```sh
git checkout -- packages/inderun-route-core-wasm/generated/inderun_route_core.d.ts \
  packages/inderun-route-core-wasm/generated/inderun_speech_text.d.ts
```

### Android

Gradle needs the Android SDK location. Either export `ANDROID_HOME` (for example
`export ANDROID_HOME="$HOME/Android/Sdk"`) or create `android/local.properties` with `sdk.dir=/path/to/Sdk`.
Unit tests run on a pinned Java 21 toolchain regardless of your default JDK, so Gradle must be able to
resolve a JDK 21 installation.

## Setup

- Use the checked-in commands below rather than inventing new workflow steps.
- Keep any new tooling documented in this file and `AGENTS.md`.
- Opt into the commit-message template, which encodes the Conventional Commits footer
  order this repository's release automation depends on (`BREAKING CHANGE:` last):

  ```sh
  git config commit.template .gitmessage
  ```

  Git stores `commit.template` per clone, so this is a one-time step and cannot be
  checked in for you. See [docs/release.md](docs/release.md) for why the order matters.

## Commands

Repository-root commands:

```sh
pnpm install
pnpm build
pnpm test
pnpm generate
swift build
swift test
cd android && ./gradlew build
cd android && ./gradlew test
cargo build -p inderun_route_core
cargo test -p inderun_route_core
```

Lint and format (run before pushing; CI gates on these):

```sh
pnpm lint                                                    # ESLint (TypeScript)
pnpm format                                                  # Prettier write (format:check to verify)
cd ios/IndeRun && swiftlint lint --strict                    # Swift
cd android && ./gradlew spotlessApply                        # Kotlin (spotlessCheck to verify)
cargo fmt -p inderun_route_core                              # Rust (add -- --check to verify)
cargo clippy -p inderun_route_core --all-targets -- -D warnings
```

Package commands:

```sh
pnpm --filter @independo/inderun-contracts build
pnpm --filter @independo/inderun-contracts test
pnpm --filter @independo/inderun-demo-proxy dev
pnpm --filter @independo/inderun-demo-proxy start
pnpm --filter @independo/inderun-demo-proxy build
pnpm --filter @independo/inderun-demo-proxy test
pnpm --filter @independo/inderun-web-demo dev
pnpm --filter @independo/inderun-web-demo build
pnpm --filter @independo/inderun-web-demo preview
pnpm --filter @independo/inderun-web-demo test
pnpm --filter @independo/inderun-web build
pnpm --filter @independo/inderun-web test
```

## Docs Policy

- Put field-level contract meaning in `contracts/schemas/*.schema.json`.
- Put public API behavior in source doc comments when the code owns the behavior.
- Keep markdown focused on concepts, onboarding, and operational guidance.
- Remove or rewrite markdown that duplicates generated types, schema descriptions, or source comments.
- Update external docs only when the public behavior or contributor workflow changes.
- Where a page belongs, and how the website reads it, is described in [Where documentation lives](#where-documentation-lives).

## Where documentation lives

The folder a Markdown file sits in decides who reads it ([ADR 024](docs/architecture/decisions/024-documentation-architecture.md)).

| Kind of document                                                                | Folder                                                                                  |
| ------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| User documentation published on [inderun.dev](https://inderun.dev/docs)         | `docs/index.md` and `docs/{getting-started,concepts,guides,platforms,api}/`             |
| Architecture, provider families, ADRs, CI and release notes, conformance, plans | the rest of `docs/` (GitHub only; the website never reads it)                           |
| Device and speech verification records                                          | `docs/verification/`, from [the template](docs/verification/website-launch-template.md) |
| Entry points that link to the site                                              | `README.md` and the package READMEs                                                     |

**Licence.** Documentation is licensed under CC BY-SA 4.0 ([`LICENSE-docs`](LICENSE-docs)); code, including the
samples in `website/snippets/`, under MIT ([`LICENSE`](LICENSE)). By contributing a documentation change you agree to
license it under CC BY-SA 4.0.

**Publish or unpublish.** Move the file into a published folder (or out of it). A published page needs front matter with
`slug` (starts with `docs/`, and is its URL), `title` and `description` (at most 155 characters), and optionally
`sidebar.order`. Add the slug to `website/published-urls.txt` for a new destination. Write plain Markdown that reads well on
GitHub: relative links to other docs and to repository files (the site rewrites them; never write a `/blob/dev/`,
`/blob/main/` or `/tree/` link by hand), and `> [!NOTE]`, `> [!TIP]`, `> [!WARNING]` or `> [!CAUTION]` for callouts.

**Snippets and versions.** Code samples are files in `website/snippets/`, embedded as `<!-- snippet:NAME -->` followed by a
blank line and `<!-- /snippet -->`, then filled by `pnpm --filter website sync:markers`. Version facts use
`<!-- version:NAME -->` … `<!-- /version -->`. Both come from `website/versions.json`, the single source of every version
the site names; never type a version number in prose. A release bump edits `versions.json`, then runs `sync:markers`
and `update:api`.

**Commands** (all from the repository root; see `website/package.json`):

```bash
pnpm --filter website dev                 # local site
pnpm --filter website sync:markers        # fill snippet and version blocks
pnpm --filter website check               # astro check
pnpm --filter website check:markers       # blocks match their sources
pnpm --filter website check:snippets      # snippets type-check against the pinned packages
pnpm --filter website check:snippets:release # fails on any pending TODO(verify) snippet; run before a production deploy
pnpm --filter website check:versions      # versions.json vs package pins and npm
pnpm --filter website check:api           # API export snapshot (update:api to refresh)
pnpm --filter website build               # validates internal links and anchors
pnpm --filter website check:docs          # documentation architecture, after build
pnpm --filter website verify:seo          # SEO output of the production build
pnpm --filter website build:preview       # noindex preview build
```

**In the same pull request as the code.** A change to public behavior, a contract or an install step updates the
published page that describes it (and the Provider Matrix row for a provider change). A change to a released package
version updates `website/versions.json`. A new published page updates `website/published-urls.txt` and the sidebar. CI
(`.github/workflows/website.yml`) catches some disagreements: snippets that no longer type-check, snippet and version
blocks out of sync with their sources, `versions.json` against the package pins, broken links and anchors, and the
publication rule (front matter, slugs, published URLs). Whether a page still describes the code's behavior is not
checked; that relies on review.

**Hosting.** The site is deployed to Firebase Hosting from `website/dist`. A production deploy requires
`pnpm --filter website check:snippets:release` to pass: it fails while any `TODO(verify)` placeholder snippet remains. The `inderun.com` and `www.inderun.com` to
`inderun.dev` 301 redirect is a domain setting in the hosting console, not part of `website/firebase.json`; change it there.

## Change Expectations

- Keep edits small and reviewable.
- Do not add new commands to docs unless they are checked into the repository.
- When behavior changes, update the relevant README or architecture page in the same change.

## Review Checklist

- The docs match the current code.
- The examples compile against the public API.
- No markdown page claims support for a surface that is not implemented.
- No page repeats contract detail that already lives in schemas or generated types.
