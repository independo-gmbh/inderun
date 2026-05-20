# @independo/inderun-web

This is the JS/TS Engine Core and Web SDK package for the IndeRun framework.

It implements:
- `ProviderRegistry` for registering execution adapters.
- `Router` for deterministic routing based on policy and host capability snapshots.
- Standard error taxonomy (`IndeRunException`) and error mapping.
- Core orchestrator flow with timing and telemetry measurements.

## Commands

```sh
# Build the package
pnpm --filter @independo/inderun-web build

# Run unit tests
pnpm --filter @independo/inderun-web test
```
