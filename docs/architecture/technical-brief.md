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

The current product scope is Mode 1 `run()` execution. Streaming and realtime sessions are part of the architecture, but they are not the main shipped surface for the current phase.

## Source Of Truth

This brief is only a project orientation document. Detailed behavior should come from code, schemas, and public API comments.
