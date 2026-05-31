# @independo/inderun-contracts

Canonical Milestone-1 contracts for IndeRun text-to-text `run()` requests.

JSON Schema files under the repository-level `contracts/schemas/` directory are the only source of truth. TypeScript
types and schema constants under `src/generated/`, and the Swift contract models under
`ios/IndeRun/Sources/IndeRunContracts/Contracts.swift`, are generated from those files.

The generated schema-backed contracts cover serializable payloads, including task requests/results/errors, normalized
HTTP request/response payloads, and telemetry events. Runtime service boundaries such as `HostServices`,
`SecureStorageService`, and `HttpClientService` are hand-written TypeScript interfaces because they model async host
behavior rather than JSON payloads.

Consumers that need schemas should import the generated schema constants from `@independo/inderun-contracts`.

## Commands

```sh
pnpm generate
pnpm --filter @independo/inderun-contracts build
pnpm --filter @independo/inderun-contracts test
```
