<p align="center">
  <a href="https://inderun.dev">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://inderun.dev/brand/inderun-logo-dark.svg">
      <img alt="IndeRun" src="https://inderun.dev/brand/inderun-logo-light.svg" width="360">
    </picture>
  </a>
</p>

<p align="center">
  <a href="https://www.npmjs.com/package/@independo/inderun-contracts"><img alt="npm: @independo/inderun-contracts" src="https://img.shields.io/npm/v/@independo/inderun-contracts?logo=npm"></a>
  <a href="https://github.com/independo-gmbh/inderun/actions/workflows/javascript.yml"><img alt="JavaScript" src="https://github.com/independo-gmbh/inderun/actions/workflows/javascript.yml/badge.svg?branch=dev"></a>
  <a href="https://github.com/independo-gmbh/inderun/blob/main/LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue"></a>
  <a href="https://inderun.dev/docs"><img alt="Docs: inderun.dev" src="https://img.shields.io/badge/docs-inderun.dev-A0B3FF"></a>
</p>

# @independo/inderun-contracts

> Part of **[IndeRun](https://github.com/independo-gmbh/inderun)** — runs AI on the device when a model
> is available, and in the cloud only when the app configures a cloud target and the request allows it.
> New here? Start with the [documentation](https://inderun.dev/docs).

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
