# IndeRun Contracts

This directory contains the canonical JSON Schema sources for serializable IndeRun contracts.

`contracts/schemas/*.schema.json` is the source of truth for schema-backed payloads across TypeScript, Swift, Kotlin,
and bridge layers. Run `pnpm generate` to regenerate language-specific artifacts.

The repo-level generator lives at `contracts/scripts/generate-contracts.mjs`. It emits TypeScript artifacts for
`@independo/inderun-contracts` and Swift models for `IndeRunContracts`.
