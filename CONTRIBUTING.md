# Contributing

IndeRun is a code-first repository. External markdown should explain concepts and usage, but implementation detail
should live in code comments, schemas, and generated public types whenever possible.

## Before You Start

- Read `AGENTS.md`.
- Read the architecture brief, architecture overview, provider overview, and CI notes.
- Check the existing package or platform README before changing a public surface.

## Setup

- Use the checked-in commands below rather than inventing new workflow steps.
- Keep any new tooling documented in this file and `AGENTS.md`.

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

## Change Expectations

- Keep edits small and reviewable.
- Do not add new commands to docs unless they are checked into the repository.
- When behavior changes, update the relevant README or architecture page in the same change.

## Review Checklist

- The docs match the current code.
- The examples compile against the public API.
- No markdown page claims support for a surface that is not implemented.
- No page repeats contract detail that already lives in schemas or generated types.
