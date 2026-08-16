# Releases & Publishing

IndeRun releases are fully automated with [semantic-release](https://semantic-release.gitbook.io/).
Versioning, changelog, GitHub releases, git tags, and package publishing are driven by
[Conventional Commits](https://www.conventionalcommits.org/) — **do not bump versions by hand.**

## What gets published

A single repository-wide version is applied to every artifact on each release.

| Channel | Artifacts | Registry |
| --- | --- | --- |
| npm | `@independo/inderun-contracts`, `@independo/inderun-route-core-wasm`, `@independo/inderun-web` | npmjs.com (public, provenance) |
| Swift Package Manager | `IndeRun` (products: `IndeRun`, `IndeRunCore`, `IndeRunContracts`, `IndeRunAppleProviders`, `IndeRunOpenAIProviders`) | git tag `vX.Y.Z` on this repo |
| Maven Central | `app.independo.inderun:inderun-contracts` / `-core` / `-kotlin` / `-mlkit-providers` / `-openai-providers` | Maven Central (Sonatype Central Portal) |

**Published separately:** `@independo/capacitor-inderun`. CocoaPods is being deprecated and
Capacitor 8 defaults to SwiftPM, and a repo can only expose one SwiftPM package at its root
(already the IndeRun Swift SDK here). The Capacitor bridge therefore lives in its own,
SwiftPM-only repository — [independo-gmbh/inderun-capacitor](https://github.com/independo-gmbh/inderun-capacitor) —
which runs its own release pipeline and consumes the artifacts published here.

## Branch strategy

- `main` — stable releases (`X.Y.Z`).
- `dev` — prereleases (`X.Y.Z-dev.N`). Use `dev` to smoke-test the pipeline before a stable cut.
- After a stable release, `main` is automatically back-merged into `dev`.

> ⚠️ **Before the first stable release:** `main` must actually contain the implementation.
> The codebase currently lives on `dev`; merge `dev → main` before expecting the `Release`
> workflow to publish a stable `v0.1.0`. Prereleases from `dev` work immediately.

## How a release runs

1. Commits land on `main`/`dev` using Conventional Commits.
2. `.github/workflows/release.yml` runs `pnpm generate` first so the generated Kotlin contract
   remains Spotless-formatted, then builds the workspace (including the Rust→WASM bindings) and
   runs `npx semantic-release`.
3. semantic-release computes the next version from the commits and:
   - runs `scripts/set-version.mjs <version>` to write the version into the three npm
     `package.json` files and `android/gradle.properties` (`inderunVersion`);
   - writes `CHANGELOG.md`;
   - publishes the npm packages via `scripts/release-publish.mjs` (`pnpm pack` rewrites the
     `workspace:^` links, then `npm publish <tarball> --provenance` uses OIDC Trusted
     Publishing — no `NPM_TOKEN`);
   - commits the version/changelog files, tags `vX.Y.Z`, and creates the GitHub release.
4. The published GitHub release triggers `.github/workflows/maven-publish.yml`, which runs
   `./gradlew publishToMavenCentral` for the library modules (stable releases only).
5. Swift consumers use the new git tag directly — no separate publish step.

## Versioning (Conventional Commits)

`feat:` → minor, `fix:` → patch, `BREAKING CHANGE:` (or `!`) → major. Chore/docs/refactor/
test/build/ci/perf/style all produce a patch (see `.releaserc` for the exact `releaseRules`).

## Consuming the packages

**npm**

```sh
pnpm add @independo/inderun-web   # pulls in contracts + route-core-wasm
```

**Swift Package Manager**

```swift
.package(url: "https://github.com/independo-gmbh/inderun.git", from: "0.1.0")
```

**Gradle (Maven Central)** — `latest.release` resolves to the newest version; pin a version for reproducible builds:

```kotlin
implementation("app.independo.inderun:inderun-kotlin:latest.release")
```

## Registry configuration requirements (one-time setup)

- **npm** — the `@independo` org must own the three package names, each configured for
  **Trusted Publishing (OIDC)**: publisher = GitHub Actions, repo `independo-gmbh/inderun`,
  workflow `release.yml`. Trusted Publishing can only be configured after a package name
  exists, so pre-create the (empty) names.
- **Maven Central** — register the `app.independo.inderun` namespace on the Sonatype Central
  Portal and verify domain ownership (DNS TXT on `independo.app`). Generate a GPG key and
  publish it to a keyserver. Add GitHub secrets: `MAVEN_CENTRAL_USERNAME`,
  `MAVEN_CENTRAL_PASSWORD` (Central Portal token), `SIGNING_KEY` (armored private key),
  `SIGNING_PASSWORD`.
- **GitHub** — semantic-release pushes the version/changelog commit + tag to `main` and
  back-merges `main → dev`. The default `GITHUB_TOKEN` cannot push to a branch that requires
  PRs, so add a **`GH_TOKEN`** secret (a fine-grained PAT or GitHub App token with
  `contents: write`) — `release.yml` uses it and falls back to `GITHUB_TOKEN` if unset. Add
  that identity to the **branch-protection bypass** list on `main` and `dev`. Create the `dev`
  branch. The keyserver upload for the GPG public key can be flaky over plain HKP — prefer
  `hkps://` (port 443) or the keyserver web upload form.

## Rollback procedures

- **npm** — you cannot re-publish the same version. Fix forward with a new patch. Within npm's
  72-hour window a mistaken version can be unpublished (`npm unpublish <pkg>@<version>`);
  otherwise deprecate it (`npm deprecate <pkg>@<version> "message"`).
- **Maven Central** — artifacts are **immutable and cannot be removed** once released. Fix
  forward with a new version. If a broken upload is still in the Portal staging state (not yet
  released), it can be dropped there.
- **Swift** — delete the bad git tag and GitHub release (`git push --delete origin vX.Y.Z`) and
  cut a new tag. Consumers pinned to a range move to the next good version.
- **GitHub release / changelog** — since semantic-release commits and tags, a bad release is
  best corrected by a follow-up release rather than history rewrites on `main`.
