# ADR 018 — Speech application API

## Status

Accepted. Recorded for Milestone 5 (issue #246). It settles what [ADR 016](./016-modality-extensible-task-contracts.md)
left to #246: the names of the speech entry points, voice discovery, and how an application selects one voice.

## Context

ADR 016 promises one primary entry point for managed playback, returning a handle with completion and cancellation,
and one that synthesizes an artifact. Two constraints shape the rest:

- `run()` has no cancellation channel on any SDK, and a provider's `RunContext` has no cancellation token. A playback
  handle whose `cancel` cannot reach the provider would be a lie.
- Voice catalogs differ per device, per installed engine and over time. An identifier that works on one device means
  nothing on the next, and no two providers share a namespace. Applications still need to offer a person one specific
  voice: a device has many voices per locale, and most report no gender, so traits alone cannot tell them apart.

## Decision

### 1. Three entry points

| Entry point        | Compiles to                | Returns                                        |
| ------------------ | -------------------------- | ---------------------------------------------- |
| `speak()`          | `stream()` with `playback` | A handle: `runId`, `result`, `cancel()`        |
| `generateSpeech()` | `run()` with `artifact`    | The artifact reference, used voice, provenance |
| `listVoices()`     | `checkCapabilities()`      | The voices of the registered providers         |

Each speaking call compiles to exactly one canonical request, and nothing in the facade routes, falls back or branches
on a provider. The names follow the `generateText` / `streamText` family and the wider ecosystem's `generateSpeech`;
`speak` names the effect, because it produces no content.

### 2. `speak()` runs on `stream()`

A stream is the one execution a caller can cancel, so managed playback uses it. A provider that serves playback
therefore implements the streaming adapter, commits no later than the first possible audible effect, and ends with a
`result` event; it emits no content events. A provider that only offers `run()` is refused for `speak()` by the planner
with the ordinary interaction-mode reason.

This does not make audio a stream. No media crosses events ([ADR 017](./017-media-artifacts.md)); the stream is only the
lifecycle of the run. Calling `run()` directly with `playback` delivery stays valid, and stays uncancellable.

Stopping playback ends the run as cancelled, so `result` resolves with `finishReason: "cancelled"`. It is an ending, not
an error, exactly as in `streamText()`.

`generateSpeech()` is not cancellable, for the same reason `generateText()` is not. It is silent and bounded by the
artifact limits.

### 3. A voice is a scoped handle with traits

`listVoices()` returns every voice, one entry per voice, each with an `id`, a display `name`, its traits and its
`providerId`. A request selects a voice in one of two ways:

- By traits (`gender`), which works on any provider.
- By handle: `providerId` plus `id`, normally by passing a catalog entry as `voice`. `id` requires `providerId`, because
  an id compared across providers could match a different voice.

An id is opaque and meaningful only on its provider on that device. It is read from the catalog at runtime and may be
stored, but it is never a literal in source. The requirement level decides what happens when it cannot be met:

- `preferred` (default) binds the voice, and ranks its provider ahead of others after every explicit priority. When the
  voice is gone, or another provider serves the run, the traits stored with the handle choose instead. `output.speech`
  reports what actually spoke, so the substitution is visible.
- `required` pins the provider and refuses with `voice_not_available`, as for any other requirement.

The handle is typed, not a passthrough option, because the planner must see it: privacy has to hold at route selection
and before the attempt, and provenance has to know the voice that spoke. `local_required` refuses a network voice even
when it was picked by id, and `local_preferred` binds an on-device voice ahead of a preferred id.

A provider re-finds the platform voice from the id the plan bound, at the turn that will use it, because a call can wait
for an earlier utterance. When that voice has disappeared since planning, the provider refuses with `CapabilityMismatch`
before commit, so fallback stays possible.

Listing order matters: the planner breaks ties by it, so it decides who speaks when an application picks no voice.
Adapters list the platform's own choice ahead of its equals and novelty voices last.

### 3a. Vendor tuning stays off the request

Settings with no shared meaning across providers (stability, style, a seed) belong to the provider instance, which is
already "a target bound to one model". A profile of provider instances also gives each fallback target its own fixed
voice. There is no per-request passthrough: nothing needs one yet, it can be added later, namespaced by provider id, and
it could not be removed once applications depend on it. A normalized speaking rate is a separate decision.

### 4. Locality follows the voice

A provider's `type` says where the adapter runs, not where synthesis happens. A `local` adapter around a system engine
may use a network voice. Execution provenance therefore reports `on_device` only as far as the bound voice allows: a
voice with `networkRequired: true`, or with no value under a task whose privacy declares `dataLeavesDevice: true`,
reports `unknown`, and so does a speech run with no bound voice, because an engine that lists no voices chooses one
itself. Provenance does not report `cloud` for it, because the engine knows only that the text may leave
the device, not where it goes. `contracts/fixtures/execution/voice-locality.json` pins the rule on all three engines.

Routing follows the same rule. `local_preferred` and `optimizeFor: privacy` rank a provider that lists voices by the
voice it would be bound to, and bind an on-device voice ahead of softer voice preferences, so a network voice never
shares the privacy rank of an on-device one. A voice can only narrow what the provider declares: `dataLeavesDevice: true`
still fails `local_required` whatever its voices say.

### 5. System speech is opt-in

The router probes every registered provider on every request, text included, and a system speech engine is not free to
probe. Default registries stay as they are: an application registers a speech provider when it wants speech.

## Consequences

- Every SDK has the same three concepts over the generated `IndeRunApi`, so a bridge gets them without reimplementing
  them.
- A playback provider implements `stream()` even though it has no content to stream.
- Where a platform exposes no gender, a required gender cannot be met and routing says so with `voice_not_available`.
- A stored voice id can go stale. A preferred one degrades to its traits, and a required one refuses.
- Catalogs are larger, up to about 190 voices on a desktop, and they reach the planner on every request. ADR 018
  section 5 keeps that cost with applications that register speech.
- `ProviderVoice.locale` is one required tag, which does not fit cloud voices that speak many languages or declare none.
  The first cloud speech provider has to widen it.
- A cancelled playback run reports no duration, because the engine stops reading the provider on cancel. The contract
  allows the field; filling it needs a provider hook that does not exist yet.
