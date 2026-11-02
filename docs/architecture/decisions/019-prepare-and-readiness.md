# ADR 019 — Prepare and readiness

## Status

Accepted.

## Context

Voices and on-device models are often present but not ready. Applications saw this as "not available":

- An Android voice whose data is not installed reports `KEY_FEATURE_NOT_INSTALLED`. Its download starts at `setVoice`,
  and until it ends a request fails or uses another voice.
- A browser can list its voices late. Chrome and ML Kit can see `downloadable` and `downloading`, but the contracts could
  only say `available: false` with a reason string.
- An Apple voice takes over a second to load the first time it speaks after launch.

An application could not tell "not yet" from "never", and could not warm anything ahead of the first call.

## Decision

### 1. Readiness is a state

`readiness` on a task capability and on a voice has four values. Absent means `ready`.

| Value          | `available` | Meaning                     |
| -------------- | ----------- | --------------------------- |
| `ready`        | true        | Runs now at full speed      |
| `cold`         | true        | Runs now, first run is slow |
| `not_prepared` | false       | Cannot run until prepared   |
| `preparing`    | false       | Being prepared now          |

`available: false` without `readiness` means "not on this device". A run refused for a state of "not yet" reports
`not_ready`, not `capability_unavailable` or `voice_not_available`. A voice that is not prepared is never bound for a run,
but it stays in the catalog.

### 2. `prepare()` is optional and general

`prepare()` takes no required arguments and covers every registered provider and task. Scope is optional. It runs each
provider in turn, one failing does not stop the rest, and the terminal outcome lists each item. It returns a `StreamRun`,
so progress, cancellation and the single terminal outcome are the ones streaming already guarantees. What is ready is
skipped, so calling it again is cheap.

### 3. The first run does the rest

An application that never calls `prepare()` still gets a ready provider where that does not need its say. The first run
of a task prepares it once for that locale and voice, because having prepared one voice says nothing about another.
Concurrent first runs share one preparation and its outcome. What an explicit `prepare()` made ready is skipped, while a
skipped or failed item gets another chance.

The first run leaves `cold` items alone. A cold run warms itself, and warming first would be slower: on an iPhone a
warm-up took about 815 ms and the following first word about 360 ms, against about 1115 ms for a cold run. So only an
explicit early `prepare()` makes a first call faster.

The wait is bounded by `constraints.timeoutMs`, else 30 s. At the bound the engine stops waiting and normal routing
decides, so fallback still works. The platform's own download may go on.

### 4. Whether prepare may download is the application's decision

`autoDownload` at registration allows a provider's platform download, per provider, off by default: a voice and Gemini
Nano need different consent. `prepare({ allowDownload: true })` allows one for a single call, for a consent screen.
Without either, a `not_prepared` item is reported as `skipped`, and the provider is never called.

The engine enforces this, so a provider's `prepare` means "go".

### 5. IndeRun still owns no downloads

IndeRun stores no files and fetches nothing. A provider only makes the call its platform documents as the trigger, and
the platform owns the data. Developer-supplied models stay host-managed, as
[onnx-runtime-provider-family.md](../onnx-runtime-provider-family.md) describes: IndeRun "is not a hosted MLOps platform".

## Consequences

- `run()` and `stream()` gain a step on every engine, which costs nothing when no provider declares `interaction.prepare`
  for the task.
- With `autoDownload`, a first call can wait up to the bound on each launch until the download finishes.
- `stream()` returns its handle after routing, so `speak()` cannot be cancelled during a first-run wait.
- `ready` on Apple voices is the provider's memory of this launch. The system can evict a voice.
- An Android engine may substitute another voice while one downloads, and `output.speech` cannot detect that.
- ONNX reports `cold` until its model loads. A capability check no longer loads it, so a corrupt model is found at load,
  and the failure is remembered for the provider instance.
