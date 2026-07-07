# @independo/inderun-contracts

[![npm](https://img.shields.io/npm/v/@independo/inderun-contracts?logo=npm)](https://www.npmjs.com/package/@independo/inderun-contracts)

> Part of **[IndeRun](https://github.com/independo-gmbh/inderun)** — an open-source AI execution
> framework that gives applications one unified API for running tasks across on-device, edge, and
> cloud providers. New here? Start with the [IndeRun README](https://github.com/independo-gmbh/inderun#readme).

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

## About IndeRun

This package is developed and published from the
[independo-gmbh/inderun](https://github.com/independo-gmbh/inderun) monorepo. For the
architecture overview, provider model, and getting-started guides, see the
[IndeRun documentation](https://github.com/independo-gmbh/inderun#readme). Built by
[Independo GmbH](https://www.independo.app) · Licensed MIT.
