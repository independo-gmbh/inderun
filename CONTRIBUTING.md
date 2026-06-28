# Contributing

IndeRun is a code-first repository. External markdown should explain concepts and usage, but implementation detail should live in code comments, schemas, and generated public types whenever possible.

## Before You Start

- Read `AGENTS.md`.
- Read the architecture brief, architecture overview, provider overview, and CI notes.
- Check the existing package or platform README before changing a public surface.

## Commands

Repository-root commands:

```sh
pnpm install
pnpm build
pnpm test
pnpm generate
```

Platform-specific commands:

```sh
cd ios/IndeRun && swift build
cd ios/IndeRun && swift test
cd android && ./gradlew build
cd android && ./gradlew test
cargo build -p inderun_route_core
cargo test -p inderun_route_core
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
