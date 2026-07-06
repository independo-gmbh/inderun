---
name: entrypoint
description: entrypoint for coding agents working in this repository
---

## 1) Project Intent (Read First)

IndeRun is an open-source (MIT) AI execution framework. It provides one unified app-facing API while routing execution across local, edge, and cloud providers.

Core product truths:

- IndeRun is an execution abstraction layer, not a model-training project.
- Policy-driven provider routing is the main differentiator.
- Cross-platform consistency and deterministic fallback behavior are critical.
- Developer experience and predictable behavior are first-class goals.

## 2) Source-of-Truth Docs

Before changing code or docs, read these files:

1. `docs/architecture/technical-brief.md`
2. `docs/architecture/architecture.md`
3. `docs/architecture/providers.md`

Treat them as the architecture baseline.

## 3) Scope Boundaries (Current Phase)

In scope now (Milestone 1 — Text→Text MVP):

- Mode 1: `run()` for `text_to_text`

Future (Milestone 2), not yet implemented:

- Mode 2: `stream()` + cancellation semantics
- Mode 3: `openSession()` / realtime session model

Out of scope now:

- Mode 4 submit/jobs infrastructure
- Durable queues/job stores/schedulers
- Full MLOps concerns

Design seams for streaming, sessions, and Mode 4 can exist in the contracts
(e.g. descriptor capability flags), but do not build or optimize implementation
around them yet.

## 4) Architecture Rules You Must Preserve

1. Keep layering clear:
   - App/API surface
   - Engine core (routing/orchestration/events)
   - Host services (platform/OS access)
   - Provider adapters (backend-specific)
2. Do not leak provider-specific behavior through public APIs when a normalized IndeRun shape exists.
3. Preserve standardized cancellation guarantees:
   - no events delivered after cancel/interrupt
   - terminal cancellation outcome
4. Keep routing deterministic and inspectable.
5. Never put raw secrets in request payloads; use secure credential references (`authContextRef` pattern).
6. Keep privacy constraints enforceable both at route selection and pre-attempt checks.

## 5) Provider Contract Expectations

Any provider integration should explicitly define:

- static descriptor (`describe`)
- dynamic capability check (`capabilities(host)`)
- supported interaction modes (`run` is the only implemented mode; `stream` and `openSession` are forward-looking descriptor seams, not yet implemented — see §3)
- cancellation behavior (`hard` / `soft` / `none`)
- mapped error taxonomy and normalized telemetry

Do not bypass these contract boundaries for short-term convenience.

## 6) Repository Reality (Do Not Invent Tooling)

This repo is currently architecture-first. Only commands checked into package manifests are authoritative.

Rules:

1. Do not fabricate commands or claim tests passed if no test harness exists.
2. Prefer small, reviewable edits.
3. If you add new tooling, document exact commands in `README.md` and update this `AGENTS.md`.

Checked-in JavaScript commands:

- `pnpm install`
- `pnpm build`
- `pnpm test`
- `pnpm generate`
- `pnpm lint`
- `pnpm format` / `pnpm format:check`
- `pnpm run upgrade`
- `pnpm --filter @independo/inderun-contracts build`
- `pnpm --filter @independo/inderun-contracts test`
- `pnpm --filter @independo/inderun-demo-proxy dev`
- `pnpm --filter @independo/inderun-demo-proxy start`
- `pnpm --filter @independo/inderun-demo-proxy build`
- `pnpm --filter @independo/inderun-demo-proxy test`
- `pnpm --filter @independo/inderun-web-demo dev`
- `pnpm --filter @independo/inderun-web-demo build`
- `pnpm --filter @independo/inderun-web-demo preview`
- `pnpm --filter @independo/inderun-web-demo test`

Checked-in Swift commands:

- `cd ios/IndeRun && swift build`
- `cd ios/IndeRun && swift test`
- `cd ios/IndeRun && swiftlint lint --strict`

Checked-in Android commands:

- `cd android && ./gradlew build`
- `cd android && ./gradlew test`
- `cd android && ./gradlew spotlessCheck` (`spotlessApply` to auto-format)

Checked-in Rust commands:

- `cargo build -p inderun_route_core`
- `cargo test -p inderun_route_core`
- `cargo fmt -p inderun_route_core -- --check`
- `cargo clippy -p inderun_route_core --all-targets -- -D warnings`
- `RUSTC="$(rustup which rustc --toolchain stable)" rustup run stable cargo build -p inderun_route_core --target wasm32-unknown-unknown`
- `wasm-bindgen target/wasm32-unknown-unknown/debug/inderun_route_core.wasm --target web --out-dir packages/inderun-route-core-wasm/generated --out-name inderun_route_core`
- `pnpm --filter @independo/inderun-route-core-wasm test`

JavaScript baseline:

- Node `24.x`
- pnpm `11.9.0`

Useful discovery commands:

- `rg --files`
- `find . -maxdepth 3 -type f | sort`

## 7) How Agents Should Work Here

1. Read the three architecture docs first.
2. Restate constraints relevant to the requested task.
3. Propose/implement the smallest change that satisfies the request.
4. Document assumptions and unresolved decisions.
5. Keep changes aligned with cross-platform parity goals (TS/Web, iOS/Swift, Android/Kotlin, Capacitor bridge behavior).

## 8) Documentation Requirements

When behavior or contracts change, update docs in the same task:

- architecture semantics: `docs/architecture/architecture.md`
- provider semantics/capabilities: `docs/architecture/providers.md`
- project framing/scope: `docs/architecture/technical-brief.md`
- CI/process behavior: `docs/ci.md`

If the change is material and docs are not updated, the task is incomplete.

## 9) Definition of Done for Agent Tasks

A task is done only when:

1. The change respects architecture boundaries above.
2. Any new behavior is documented in the correct source-of-truth file.
3. Claims about validation are truthful (run commands only if they exist).
4. Risks, tradeoffs, and follow-ups are clearly listed.

## 10) If You Are Unsure

Prefer explicitness over assumptions:

- state ambiguity
- offer 1-2 concrete options with tradeoffs
- proceed with the safest architecture-consistent default

Avoid hidden assumptions that create future migration work.
