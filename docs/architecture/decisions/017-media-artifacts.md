# ADR 017 — Media artifact transport and lifecycle

## Status

Accepted. Recorded for Milestone 5 (issue #244). It fills in the `artifact` output delivery that
[ADR 016](./016-modality-extensible-task-contracts.md) reserved; the request, result and terminal shapes it plugs into
land with #245.

## Context

ADR 016 separates three output deliveries: `inline` text, managed `playback`, and a retrievable `artifact`. The first
two need no new transport — text is already JSON, and playback produces an audible effect and a completion, not
content. A retrievable artifact is different: it is bytes the application wants to hold, and IndeRun has no place to
put them.

Three places are deliberately unsuitable:

- **The result JSON.** `TaskResult` crosses the Capacitor bridge as JSON. Inlining audio as base64 makes every result
  size a function of the audio length, and a cross-process hop pays for it twice.
- **Stream events.** Events are small, frequent, ordered and replayed by the bridge. A base64 chunk event would put
  unbounded material into the one channel whose ordering and single-terminal guarantees the engines enforce.
- **A platform-native object on the result.** It works in-process, but it is not part of the contract: the bridge would
  need its own translation, and the three SDKs would each invent a different shape.

What the application needs is a reference it can hold in JSON and resolve to bytes on demand, with a defined owner and
a defined end of life.

## Decision

### 1. A media-neutral reference, not an audio type

A `MediaArtifact` (`contracts/schemas/media-artifact.schema.json`) names media the engine holds or has delivered:

| Field            | Meaning                                                                                                                                                                                    |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `id`             | Required. Opaque, engine-issued (`art_<random>`). Never a path, URL or provider identifier.                                                                                                |
| `mediaType`      | Required. The IANA media type of the bytes, for example `audio/wav`. Encoding parameters ride on it (`audio/L16;rate=22050`).                                                              |
| `owner`          | Required. `engine` — the engine holds the bytes and the application reads them by `id`; `application` — the bytes were written to an application destination and the engine holds nothing. |
| `lifetime`       | Required. `until_disposed` in this version. An enum so a time-bounded lifetime can be added without changing the meaning of the existing value.                                            |
| `byteLength`     | Size in bytes. The engine always sets it for artifacts it materialized.                                                                                                                    |
| `durationMs`     | Media duration where the producer knows it.                                                                                                                                                |
| `destinationRef` | The application destination the bytes were written to, echoed back when `owner` is `application`.                                                                                          |

Nothing about audio is special in the reference. An image-producing task would return a `MediaArtifact` with
`mediaType: "image/png"` through the same output branch and the same read and dispose calls; a video task would do the
same. `contracts/fixtures/artifacts/` keeps an image fixture next to the audio ones to hold the shape to that.

### 2. Ownership and lifetime

An engine-owned artifact belongs to the `IndeRun` instance that produced it. It **outlives the run**: a completed
run's result can be stored and read later. It ends when the application disposes it or the process ends.

The engine disposes on its own initiative only what the application never received: artifacts created by an attempt
that failed, was cancelled, or lost to fallback, and artifacts a winning attempt created but did not return. A
returned artifact is never disposed behind the application's back.

The store is in memory in this version, on all three platforms, with no temporary files. That bounds what one artifact
can be, but it makes abnormal termination trivially clean: a crash leaves nothing on disk, and no handle can survive
the process that issued it. A store backed by temporary files can replace it behind the same API when a task needs
larger media.

### 3. Getting the bytes

Two operations join `run`, `stream` and `checkCapabilities` on the generated `IndeRunApi`:

- `readArtifact({ artifactId, offset?, maxBytes? })` returns one chunk: the bytes in the platform's native byte type,
  with `offset`, `totalBytes` and `done`. Reads are repeatable and ranged; reading the same range twice returns the same
  bytes. Each call returns at most a configured maximum, which bounds what a single call — and a single bridge message —
  can carry.
- `disposeArtifact(artifact)` releases the bytes. It is idempotent.

Reading an unknown, disposed or application-owned artifact fails with `Unavailable`, `retryable: false`, and
`details.code: "artifact_not_found"`. The engine's limits (`maxArtifactBytes`, `maxStoreBytes`, `maxReadBytes`) are
engine options with conservative defaults. Exceeding a size limit while a provider writes fails that attempt before it
hands the artifact over, so it is still eligible for fallback.

### 4. Application destinations

An application that wants the bytes somewhere specific — a file it will hand to a media player, a cache it manages —
sets `delivery.destinationRef` on an artifact request. Like `authContextRef`, it is an opaque reference the application
resolves through a host service (`artifactDestinations`), never a raw path in the request: a request may come from a
webview, and it must not be able to name arbitrary files.

Providers do not see destinations. A provider always writes into the engine's store; after the winning attempt hands
its artifact over, the engine writes it to the destination, drops its own copy, and returns the artifact with
`owner: "application"`. One write path per engine, nothing for a provider to get wrong, and no planner change.

A host without a destination service — the default browser host — refuses a request with a `destinationRef` before
routing, with `CapabilityMismatch` (`details.code: "artifact_destination_unsupported"`). A failed destination write
happens after the run committed, so it is a terminal error and never a fallback. Cancellation never starts a
destination write and does not interrupt one in progress; a stream cancelled during the write ends `cancelled`, and
because the bytes are then at the destination, its outcome carries the application-owned artifact.

### 5. Commit

An artifact attempt commits when the provider hands the finished artifact to the engine. Before that, a failure — a
provider error, a size limit — is eligible for fallback and the partial artifact is discarded. After it, no other
provider is tried. This is the artifact case of the single commit rule that #245 implements.

### 6. Playback is not an artifact

Managed playback produces an audible effect and a completion (`output.type: "playback"`). It never returns a
`MediaArtifact`, and a provider that can only play audio never declares `artifact` delivery (ADR 016 §3). A provider
that can do both declares both and produces exactly the one the request asked for.

### 7. No streamed media in this version

Media chunks are not streamed in v0.5: no stream event carries media bytes, base64 or otherwise. An artifact stream
ends with the same terminal `output` a `run()` returns, and the application reads the artifact afterwards. Admitting
chunked delivery later would need its own decision on chunk identity, ordering against `sequence`, format and
finalization; nothing here precludes it.

### 8. Privacy

Artifact bytes are request-derived content. They never appear in telemetry, provenance or error details; the
reference carries no content and no location. Disposal drops the engine's last reference to the bytes.

## Consequences

- The result JSON and every stream event stay small and bounded regardless of media size, so the Capacitor bridge
  carries artifacts as ids and reads bytes through ordinary calls.
- `IndeRunApi` gains two operations, so every implementer — including the bridge — must add them.
- The in-memory store limits artifact size. Larger media needs the file-backed store, which this decision leaves room
  for but does not build.
- Applications that never dispose leak memory until the instance is released. The lifetime is explicit so that this is
  a visible choice, not a surprise.
- Image and video tasks reuse the reference, the store and both operations unchanged; they need only their own task
  kind and payload under ADR 016.
