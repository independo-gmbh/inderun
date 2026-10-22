# Architecture Decision Records

An ADR records one architectural decision: the problem it answers, what was decided, and what that makes easier or
harder. It is written once and then only superseded, never rewritten, so the reasoning behind a contract survives
the code that implements it.

ADRs 001–015 predate this directory and live in the project's planning workspace. They cover the interaction modes,
the Capacitor bridge as a thin facade, JSON Schema as the canonical format, the shared Rust route core, the provider
capability model, cancellation semantics, strategic scope, the provider admission rule, outbound compatibility
surfaces, the capability-oriented canonical contract, and execution provenance. Their outcomes are already reflected
in [architecture.md](../architecture.md), [providers.md](../providers.md) and [api-layering.md](../api-layering.md).
New ADRs continue the numbering here.

| ADR                                                | Title                                  | Status   |
| -------------------------------------------------- | -------------------------------------- | -------- |
| [016](./016-modality-extensible-task-contracts.md) | Modality-extensible task contracts     | Accepted |
| [017](./017-media-artifacts.md)                    | Media artifact transport and lifecycle | Accepted |

## Template

```markdown
# ADR NNN — Title

## Status

Proposed / Accepted / Superseded by ADR NNN / Rejected

## Context

What problem or uncertainty is this decision addressing?

## Decision

What are we deciding?

## Consequences

What becomes easier, harder, or constrained by this decision?
```
