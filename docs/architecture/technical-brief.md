# Technical Brief

IndeRun is an MIT-licensed AI execution framework for applications that need one consistent API across local, edge, and cloud execution.

It is intended for developers who want:

- one app-facing execution surface
- deterministic provider routing
- normalized fallback and cancellation behavior
- platform parity across Web, iOS, Android, and shared cores

## What IndeRun Is

IndeRun is an execution abstraction layer. It is not a model-training project and it is not a hosted MLOps platform.

The core problem it solves is provider fragmentation: apps should not need separate execution code paths for every runtime, SDK, or cloud API.

## Current Focus

The current product scope is Mode 1 `run()` execution plus Mode 2 `stream()`. All three engines implement the Mode 2 orchestrator against the canonical streaming event/outcome contracts, and the OpenAI-compatible provider streams on Web, iOS, and Android (see `docs/architecture/architecture.md`). Realtime sessions remain part of the architecture but are not implemented.

## Source Of Truth

This brief is only a project orientation document. Detailed behavior should come from code, schemas, and public API comments.
