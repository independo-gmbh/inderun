# @independo/inderun-contracts

Canonical JSON Schema-backed contracts for IndeRun.

The JSON Schema files in `contracts/schemas/` are the source of truth. TypeScript types and validators in this package,
and the generated Swift contract models, are produced from those schemas.

Use this package when you need the generated request, result, error, HTTP, route-planning, or telemetry contract types.

## Commands

```sh
pnpm generate
pnpm --filter @independo/inderun-contracts build
pnpm --filter @independo/inderun-contracts test
```
