# @independo/inderun-contracts

Canonical Milestone-1 contracts for IndeRun text-to-text `run()` requests.

JSON Schema files under `schemas/` are the source of truth. TypeScript types and schema constants under `src/generated/`
are generated from those files.

The generated schema-backed contracts cover serializable payloads, including task requests/results/errors, normalized
HTTP request/response payloads, and telemetry events. Runtime service boundaries such as `HostServices`,
`SecureStorageService`, and `HttpClientService` are hand-written TypeScript interfaces because they model async host
behavior rather than JSON payloads.

## Commands

```sh
pnpm --filter @independo/inderun-contracts generate
pnpm --filter @independo/inderun-contracts build
pnpm --filter @independo/inderun-contracts test
```
