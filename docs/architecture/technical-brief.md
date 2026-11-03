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

Text-to-speech is the first non-text task: `speak()`, `generateSpeech()` and `listVoices()` over the system speech
providers on all three platforms, with playback and retrievable audio as separate deliveries.

Out of scope for now: speech-to-text, embeddings and image tasks, video, voice cloning, a general model registry, hosted
services, realtime sessions, and job queues.

## Source Of Truth

This brief is only a project orientation document. Detailed behavior should come from code, schemas, and public API comments.
