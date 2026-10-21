# ADR 016 — Modality-extensible task contracts

## Status

Accepted. Recorded for Milestone 5 (issue #242) before any schema, engine or provider change. The request, result and
stream schema changes it describes land with #245; the per-task provider capabilities with #243; media artifacts with
#244; the speech application API with #246.

## Context

IndeRun's canonical contract is task-oriented (ADR 012), but every payload in it was written for exactly one task.
Three constraints make that concrete rather than a naming issue:

- `TaskRequest.task.kind` is `const: "text_to_text"`, and the request root requires `prompt` or `messages`.
- `TaskResult.output` requires `{ "type": "text", "text": … }`.
- The `completed` stream terminal outcome requires `finalText`; the `cancelled` one requires `partialText`. The
  terminal `StreamEvent` repeats both.

Every schema sets `additionalProperties: true`, which lets an older consumer accept unknown fields. It does not make a
`const` accept a second value, and it does not make a required field optional. Adding `text_to_speech` therefore has
to change what those schemas accept, and the change has to be shaped so that the next task does not repeat it.

Speech adds a second difficulty: a text-to-speech provider may not produce anything the application can hold. A
system speech synthesizer that plays audio through the device's output has an audible effect and a completion, not a
file. Treating it as an audio producer would make it look capable of requests it cannot serve.

## Decision

### 1. Five independent axes

A request is described along five axes. Each has one owner and none is inferred from another.

| Axis                 | Carried by                                                        | Notes                                                                                                                                            |
| -------------------- | ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Task**             | `task.kind`                                                       | The operation: `text_to_text`, `text_to_speech`. The planner matches it against provider declarations.                                           |
| **Modalities**       | implied by the task; declared per task by providers (#243)        | The input and output media kinds. Never a free request field — a request names a task, not a combination of media.                               |
| **Interaction mode** | the API method (`run`, `stream`); the planner's `interactionMode` | `realtime` stays reserved for Mode 3.                                                                                                            |
| **Output delivery**  | `delivery.mode` on non-text requests                              | `inline` (content in the result, implicit for text), `playback` (a managed, audible effect on the device), `artifact` (retrievable media, #244). |
| **Execution policy** | `constraints`, `preferences`, `modelProfile`, `authContextRef`    | Unchanged and task-agnostic. A profile may list speech targets as it lists text targets.                                                         |

There is no voice or model registry and no vendor model or voice identifier at the request call site; model profiles
keep the meaning [api-layering.md](../api-layering.md#model-profiles) gives them.

### 2. Request envelope

The common envelope fields (`schemaVersion`, `requestId`, `task`, `modelProfile`, `constraints`, `preferences`,
`telemetry`, `authContextRef`) stay as they are. `task.kind` becomes an enum. Each non-text task family owns one
top-level payload object named after the family; `prompt` and `messages` remain the text payload. There is no
universal `text` field.

The schema expresses per-kind requirements with `allOf` of `if`/`then` branches:

- `text_to_text`: requires `prompt` or `messages`; forbids `speech` and `delivery`.
- `text_to_speech`: requires `speech` and `delivery`; forbids `prompt`, `messages` and `generation`. `generation` is
  forbidden rather than ignored, because a silently dropped sampling option is a lie about what ran.

A text-to-speech request:

```json
{
  "schemaVersion": "1.0",
  "task": { "kind": "text_to_speech" },
  "speech": {
    "text": "Der Bus kommt in fünf Minuten.",
    "locale": "de-AT",
    "localeMatch": "language",
    "voice": { "gender": "female", "requirement": "preferred" }
  },
  "delivery": { "mode": "playback" },
  "constraints": { "privacy": "local_required" },
  "modelProfile": "speech"
}
```

| Field                 | Meaning                                                                                                                                                                                               |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `speech.text`         | Required. Plain text; markup such as SSML is out of scope.                                                                                                                                            |
| `speech.locale`       | Required BCP 47 tag.                                                                                                                                                                                  |
| `speech.localeMatch`  | `language` (default): the primary language subtag is a hard requirement and the region is a preference. `exact`: the full tag is a hard requirement.                                                  |
| `speech.voice`        | Optional, provider-neutral traits only. `requirement` is `preferred` (default) or `required`. Whether applications may also pass a provider-local voice handle is decided with the voice API in #246. |
| `delivery.mode`       | Required for non-text tasks: `playback` or `artifact`.                                                                                                                                                |
| `delivery.mediaTypes` | Only valid with `artifact`. An acceptable set of media types, always a hard requirement. Absent means the provider chooses and the artifact reports what it produced.                                 |

Preferences and requirements are kept apart deliberately. A preference shapes ranking and provider behaviour; an unmet
preference is still a success. A requirement takes part in routing and is never relaxed silently.

### 3. Result

`output.type` becomes an enum describing the content representation, not the task:

- `text` — requires `text`, exactly as today.
- `playback` — requires `playback: { durationMs? }`. No bytes; the result is a completion.
- `artifact` — requires `artifact`, a media reference whose transport, ownership and lifecycle #244 defines.

An optional `output.speech: { locale, voice? }` reports the locale and voice traits actually used, so an unmet
preference is visible without being an error.

**Managed playback.** `run()` resolves when audible playback has finished, with `finishReason: "stop"`. Cancelling
stops the audio and ends the run as cancelled (`finishReason: "cancelled"` / the `cancelled` terminal outcome). A
playback run commits to its provider no later than its first possible audible effect: after sound may have reached
the user, falling back to another provider would play the text twice, so the run fails rather than retrying.

**Retrievable audio.** An `artifact` run resolves when the artifact is fully materialized and has no audible effect.
A provider that can only play audio never declares `artifact` delivery; one that can only synthesize never declares
`playback`. A playback-only provider is never described as an audio producer.

A third, contract-only example keeps the envelope honest: an `image_to_text` request carries an image reference and
an instruction, and its result reuses `output.type: "text"`. It exists as a test vector only (see Consequences).

### 4. Unsupported locale, voice, format or delivery

- **Detectable from capabilities** (#243): the planner rejects the provider with a stable reason code. If no
  provider remains, routing fails with `CapabilityMismatch` and the per-provider reasons in provenance.
- **Detected by the provider before commit**: the provider throws `CapabilityMismatch`, which is fallback-eligible.
- **Detected after commit**: a terminal error; no fallback.
- **Unmet preference**: success, with the actual values in `output.speech`.

A provider never substitutes a different locale, voice or format for a required one, and never substitutes
playback for an artifact or the reverse.

**Preferences are honoured by routing, never against policy.** A region under `language` matching is a preference:
among otherwise equal candidates, routing ranks one known to offer the exact tag first, after every explicit routing
priority (placement, model profile, `optimizeFor`). The voice that actually speaks is bound by the plan, not left to
the adapter: when the provider lists its voices, each route candidate carries the voice it must use — the best one
that satisfies the locale, the required traits and the privacy policy, ranked by preferred gender, then exact region,
then on-device before network. Under `local_required` that voice always keeps data on the device, so a preference
that only a network voice could meet stays unmet rather than becoming a reason to send text off the device. A
provider that cannot list its voices chooses itself under the same rule.

### 5. Streaming

Streaming is an optional per-task capability (#243), not a property every task inherits. `content_delta` and
`content_snapshot` stay text-only. Any non-text progress signal arrives as a new `StreamEvent.type`, which the open
catch-all already admits for older consumers. The terminal `completed` branch becomes "`finalText` or `output`" and
`cancelled` becomes "`partialText` or `output`", so a speech stream ends with the same normalized `output` a `run()`
returns. Media bytes do not travel in stream events unless #244 admits a chunk shape.

### 6. Compatibility: additive within schema version 1.0

The change stays inside `schemaVersion: "1.0"` and the `.../1.0/...` `$id`s. Widening a discriminator `const` to an
`enum` with per-value `if`/`then` branches is additive: every v0.4 payload stays valid byte for byte, and a consumer
built against the narrower schema rejects the new value through validation rather than misreading it.

What changes for v0.4 → v0.5 consumers:

| Surface                         | Change                                                                                                                                 |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| Request JSON                    | None for text. TTS requests add `speech` and `delivery`.                                                                               |
| Result / terminal JSON          | None for text. TTS results carry `output.type` `playback` or `artifact` instead of `text`.                                             |
| Generated `TaskKind`            | Gains a case; an exhaustive `switch` / `when` over it must handle it.                                                                  |
| Generated request types         | New optional `speech` and `delivery` properties.                                                                                       |
| Generated result / stream types | `output.text`, `finalText` and `partialText` become optional, because code generation cannot express "required when `type` is `text`". |
| Primary text API                | Unchanged: `generateText` / `streamText` keep returning a non-optional string.                                                         |

Unknown-task behaviour for older consumers:

- **TypeScript**: Ajv rejects the request at `/task/kind`.
- **Swift**: decoding an unknown `TaskKind` raw value throws `DecodingError`.
- **Kotlin**: there is no contract decoder; an older Kotlin SDK cannot construct or receive the kind.
- **Streams**: an older consumer ignores an unknown event type, as it must, and rejects a terminal outcome without
  `finalText`. It cannot issue a TTS request in the first place, so this only happens across a version-mismatched
  bridge — which is why the Capacitor bridge moves its core dependency in lockstep with IndeRun (#250).

A `2.0` contract family was considered and rejected: it would force every text caller across three SDKs and the
bridge through a migration for no change in behaviour. A separate `SpeechRequest` / `SpeechResult` family was also
rejected: every future task would add another parallel set of contracts, validators and API methods.

### 7. Typed API

`run`, `stream` and `checkCapabilities` remain the canonical, task-generic entry points. Because code generation
cannot turn `if`/`then` into a discriminated union, TypeScript gains hand-written narrowed aliases next to the
existing ones in `packages/contracts/src/types.ts` (a text request, a speech request, a result narrowed by kind).
The primary layer gains speech entry points alongside `generateText` — one for managed playback that returns a
handle with completion and cancellation, one that synthesizes an artifact. Their final names and the voice
discovery API are decided in #246. Swift and Kotlin get the facade functions only, without generic overloads.

### Implications reviewed

- **Type generation.** quicktype does not read `if`/`then`, so per-task requiredness exists in the validators (Ajv in
  TypeScript; the per-task request checks in `IndeRun.swift` and `IndeRun.kt`) and not in the generated types. Every
  task payload is a top-level optional property.
- **Engine routing.** The planner receives `task.kind` plus a projection of the task's requirements (input kinds,
  delivery, media types, locale, voice requirement), and returns the bound voice per candidate. Engines gain no
  task-specific branches beyond request validation, handing the bound voice to the attempt, and result
  normalization; there is no second engine and no provider-specific routing. Before an attempt, the engine
  re-checks that the voice it hands over satisfies the request's privacy policy, so privacy stays enforceable at
  route selection and immediately before use (#245).
- **Streaming.** As above: optional per task, open event vocabulary, closed terminal set with a generalized output.
- **Capacitor.** Everything crossing the bridge stays JSON. Artifacts cross as handles (#244). The capability
  snapshot type is imported from the contracts package rather than mirrored (#210). Stopping playback is the
  existing cancellation path.

## Consequences

- Adding a task means adding one `task.kind` value, one payload object and its `if`/`then` branch, and per-task
  provider declarations. No envelope field changes meaning.
- Generated Swift and Kotlin result types lose non-optional `text` accessors; the primary text API absorbs that for
  text callers.
- Playback and retrievable audio are separate capabilities with separate failure semantics, which makes routing
  honest at the cost of two declarations for a provider that can do both.
- This ADR commits to `text_to_speech` only. `image_to_text` exists as a contract-only test vector in
  `contracts/fixtures/task-contracts/`; it is not a planned feature and adding it would require its own decision.
- Realtime voice sessions, speech-to-text and conversational audio remain out of scope.
