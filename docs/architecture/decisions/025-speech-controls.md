# ADR 025 — Speech controls and schema version 1.1

## Status

Accepted (2026-11-26, review of #312). Recorded for issue #311, before any planner or provider change. It amends
[ADR 018](./018-speech-application-api.md) section 3a, which left "a normalized speaking rate" to a separate decision,
and [ADR 016](./016-modality-extensible-task-contracts.md) section 6, which kept every change inside schema version 1.0.
It leaves ADRs 019 to 022 unchanged: discovering controls prepares, downloads and loads nothing, and the neural speech
runtimes gain no per-utterance setting. The Capacitor bridge follows in #250.

## Context

Applications that speak to people with different needs offer a speech-settings screen: slower, higher, quieter. Today a
request has no way to say that. A consumer has to switch providers, keep its own per-platform settings, or call the
platform directly, and each of those bypasses routing and provenance.

Three constraints shape the answer:

- The platforms do not share units. Apple maps rate to a 0..1 scale with a default of 0.5, Android and the Web multiply
  a voice's normal rate, and none of them reports words per minute or pitch in hertz. Some voices ignore a setting that
  the API accepts. A shared control can only promise a relative intent and that the platform accepted it.
- Support is per voice, not per provider. A browser's network voices and an Android engine's voices can differ from the
  provider's local voices. A required setting that the bound voice cannot honour is a lie, however capable the provider.
- Every field so far was additive, and older consumers drop unknown fields without an error: Swift's `Codable`, the
  Kotlin bridge's hand-written parser, and Ajv with `additionalProperties: true`. A required rate that an old bridge
  drops speaks at full speed and reports success. Additive is not safe for a hard requirement.

## Decision

### 1. Three shared controls

| Control id            | Request field                    | Meaning                                                                 | Domain       |
| --------------------- | -------------------------------- | ----------------------------------------------------------------------- | ------------ |
| `speech.speakingRate` | `speech.controls.speakingRate`   | Relative pace. 1.0 is the bound voice's normal rate.                    | finite, > 0  |
| `speech.pitch`        | `speech.controls.pitch`          | Relative baseline pitch. 1.0 is the voice's normal pitch.               | finite, > 0  |
| `playback.volume`     | `delivery.playback.volume`       | Attenuation of this utterance only. Never device volume, never gain on an artifact. | 0..1 |

Each is `{ "value": number, "requirement"?: "preferred" | "required" }`: a `RequestedNumber` for rate and pitch, a
`RequestedUnitNumber` for volume, two names only because the generated types carry the domain in their name. An absent
requirement is `preferred`. An absent control means the provider's normal behaviour, not an implicit required 1.0.

```json
{
  "schemaVersion": "1.1",
  "task": { "kind": "text_to_speech" },
  "speech": {
    "text": "Guten Morgen!",
    "locale": "de-AT",
    "controls": {
      "speakingRate": { "value": 0.85, "requirement": "required" },
      "pitch": { "value": 1.05 }
    }
  },
  "delivery": { "mode": "playback", "playback": { "volume": { "value": 0.7 } } }
}
```

Synthesis controls sit in `speech`, because they shape the audio. Volume sits in `delivery.playback`, because it shapes
only how a playback run is heard, and the schema forbids `delivery.playback` unless `delivery.mode` is `playback`. So an
artifact request cannot carry a volume.

The facades follow the same split on every SDK. `SpeechOptions` holds what every speech call takes: text, locale,
voice, `controls` and the execution policy. `SpeakOptions` adds `playback`, and `GenerateSpeechOptions` adds the
artifact's `mediaTypes` and `destinationRef`. Swift and Kotlin compose them (`SpeakOptions(speech:playback:)`,
`GenerateSpeechOptions(speech:…)`, with the flat initializer kept for the usual call), so an artifact call cannot hold
a volume at all. TypeScript extends one interface; there `GenerateSpeechOptions.playback` is typed `never`, and a
JavaScript caller that passes one anyway has it forwarded into the request, where validation refuses it. A supplied
playback control is never dropped.

The schema rejects an unknown control, an unknown requirement string and a value outside the domain:
`controls`, `playback` and `RequestedNumber` are the first request objects with `additionalProperties: false`, because a
misspelled control silently ignored is exactly the failure this ADR exists to prevent. The SDKs reject non-finite
numbers, which JSON cannot carry but native callers can.

**Raw JSON boundaries.** The Swift and Kotlin typed APIs cannot express an unknown key or an unknown enum string, and
the decoders that build them lose such input silently: `Codable` and a hand-written parser drop unknown keys, so a
misspelled required control would decode as no control. Every supported entry point that turns raw JSON into a request
therefore checks the raw payload before decoding it, and refuses it on any issue:

| Entry point                                | Check                                                                    |
| ------------------------------------------ | ------------------------------------------------------------------------ |
| Web engine `run()` / `stream()`            | The full schema (Ajv), as for every request.                             |
| A Swift JSON entry point (a bridge)        | `RawTaskRequestValidation.issues(_:)` on the parsed JSON, then `Codable`. |
| A Kotlin JSON entry point (a bridge)       | `rawTaskRequestIssues(JSONObject)`, then the parser.                     |
| Capacitor bridge, JavaScript layer (#250)  | The contracts package's validator before dispatching to native code.    |

The native checks are targeted, not a schema engine: they cover `schemaVersion` and the closed control objects, the
only places where a lost key changes what executes. The Swift and Kotlin SDKs themselves accept typed values only and
expose no raw-JSON request API, so their generated decoders are never a validating boundary. The shared fixture
`contracts/fixtures/task-contracts/text-to-speech.json` lists the payloads only a raw check can see under
`invalidPayloads`, apart from the `invalidRequests` every SDK's own validation rejects; the Swift and Kotlin suites run
their raw check against it, and the bridge's conformance suite must too (#250). Support and per-voice ranges are
checked by routing, never by the schema. Rejections use the existing request-validation path (`Internal` with `details.validationIssues`); there is
no second error taxonomy.

A provider never clamps, approximates or substitutes time stretching or gain. An unsupported preferred control is
omitted and reported. An unsupported required control is never ignored.

### 2. Capabilities extend the snapshot

Controls are declared in the existing per-task structures, not in a second registry.

- **Static**: `ProviderDescriptor.taskCapabilities[].controls[]`, one `SpeechControlDeclaration` per control:
  `id`, `valueKind` (`number`, `choice`, `boolean`), `phase` (`synthesis` or `playback`), `lifetime` (`utterance` or
  `provider_instance`) and `deliveries` (`playback`, `artifact`; text output has no speech controls). The shared ids
  fix kind and phase, and the schema enforces it: `speech.speakingRate` and `speech.pitch` are `number` and
  `synthesis`; `playback.volume` is `number` and `playback`, and lists only the `playback` delivery. A synthesis
  control lists each delivery whose path applies it.
- **Dynamic**: `ProviderDynamicCapabilities.taskCapabilities[].controlStates[]`, one `SpeechControlState` per id **and
  delivery**: `id`, `delivery`, `available`, `reason`, and for a number a `range` of `min`, `max`, `default` and
  `step`. A provider whose playback and artifact paths differ, say rate 0.5 to 2.0 when playing and 0.8 to 1.2 when
  rendering, states each. `playback.volume` only ever has a `playback` state. `step` is a hint for a UI slider, not a
  quantization rule.
- **Per voice**: `ProviderVoice.controlStates[]`, sparse, keyed the same way. A voice entry overrides the task entry
  with the same id and delivery, field by field: an explicit `available: false` disables the control for that voice on
  that delivery, and a voice `range` supersedes the task `range` for that delivery. A pair with no voice entry inherits
  the task state for that pair; nothing is inherited across deliveries.

Absent `available` means unknown, and unknown is never support. A control satisfies a request only when it is declared
for the requested delivery with `lifetime: utterance`, its merged state for that delivery is `available: true`, and its
merged range is known and contains the value. A number control with `available: true` and no range cannot satisfy a
required control.

**Contradictory declarations are refused, never resolved.** What the schema cannot express, routing treats as a
declaration error: an id declared twice for one task, or two states for one id and delivery at the same level, make
that control unsupported for that provider, so a required control rejects it with `speech_control_unsupported`. A state
for a delivery the control does not declare is ignored. Losing optional capability metadata only ever reads as unknown
support.

`SpeechControlId` is a closed enum of the three ids above. A future provider-owned control is a new, namespaced enum
value with a typed request field, added by a later decision; there is no open options map. `lifetime: provider_instance`
lets a provider document a fixed instance setting, such as Articulino's `speed`; such a control never satisfies a
request. `choice` and `boolean` exist on the discriminator for later controls; no shared control uses them yet, so the
request has no shape for them and the state has no `choices` field yet.

### 3. One planner, strict requirements

Every SDK projects the controls into the planner's `task.controls[]`, `{ id, value, requirement }`, in the fixed order
rate, pitch, volume. The shared Rust planner evaluates them on the voice it binds:

- **Hard filters first, never widened.** Task, delivery, locale, model profile, privacy, placement, readiness and
  locality keep their meaning. A control never makes an otherwise rejected target eligible.
- **Required controls bind with the voice.** The planner binds a voice that satisfies the locale, the required voice
  traits, privacy and every required control together, for the requested delivery. A required voice id is never
  substituted for one that supports the control. A provider that lists no voices is checked against its task state
  alone.
- **Ranking reads the bound voice.** Everything the planner ranks a provider by that depends on a voice, the exact
  locale region and the privacy placement under `local_preferred` or `optimizeFor: privacy` included, is read from the
  voice it would bind: one that meets every hard requirement, controls included. Another voice of the same provider
  that offers the exact region but fails a required control does not raise the provider's rank.
- **Stable reasons.** A provider with no such voice is rejected with `speech_control_out_of_range` when a candidate
  voice supports the control but not the value, and with `speech_control_unsupported` otherwise. When nothing remains,
  routing fails with `CapabilityMismatch` and the per-provider reasons, as for any other requirement.
- **Preferences rank, never reject.** Ranking keeps placement, model profile and `optimizeFor` first. Within the same
  rank, a provider that can bind the requested voice id comes first, then the one satisfying more preferred controls,
  then the exact locale region. Inside one provider the voice order is privacy, preferred id, preferred gender, then the
  number of preferred controls satisfied, then the existing order. Without controls every new rank is equal, so existing
  plans do not change.
- **A control plan travels with the candidate.** `RoutePlan.candidates[].controls[]` holds, per requested control,
  `decision: apply` or `decision: omit` with a `reason` (`unsupported`, `out_of_range`, `range_unknown`,
  `availability_unknown`). The engine hands it to the attempt with the bound voice.

**A missing plan is not an empty request.** Capability metadata may be lost safely, because losing it reads as unknown
support. An execution instruction may not: the planner boundary carries no version, so a route core or binding built
without plans would return candidates with none, and a required control would vanish. After planning and before the
first attempt, the engine therefore checks the plan of every candidate, fallbacks included, against the request. Each
requested control appears exactly once, in request order, with the request's id, value and requirement. Every required
one has `decision: apply`. No entry names a control the request did not. A plan that fails any of these, including an
absent or empty one, fails the run with `Internal` (`details.code: control_plan_mismatch`) and no attempt is made.
`contracts/fixtures/execution/control-plan-integrity.json` holds the cases.

Before commit, the provider rechecks its live voice and applies the plan. Privacy is rechecked there too, as today:
the bound voice must still satisfy the request's privacy policy, and a control never relaxes it. A required control the platform refuses at
that point fails the attempt with `CapabilityMismatch` (`details.code: speech_control_unsupported`), which is
fallback-eligible along the existing chain. After commit a failure ends the run; nothing is replayed. Cancellation
keeps its guarantees: no further attempt and no late callback.

"Required" means that support was validated and the provider accepted the mapped value through the platform's
documented path. It is not an acoustic measurement. A provider does not declare support for a combination known to be
ignored or that it cannot verify.

### 4. Honest outcomes

`TaskOutput.speech.controls[]` holds one `SpeechControlOutcome` per requested control, and none for others:

| Field       | Meaning                                                                                              |
| ----------- | ---------------------------------------------------------------------------------------------------- |
| `id`        | The control id.                                                                                      |
| `requested` | The requested value.                                                                                 |
| `effective` | The value the platform accepted, in the shared control's units. Absent when unknown. Not a measurement. |
| `status`    | `applied` or `not_applied`.                                                                          |
| `method`    | `platform_synthesis` or `playback_attenuation`, for an applied control.                              |
| `reason`    | For `not_applied`: a plan reason, `provider_rejected`, or `not_reported`.                            |

Application is never inferred from the request. The engine validates and completes the records before the output
leaves it:

- One record per requested control, in request order, with the request's id and value. A duplicate record, a record
  for a control the request did not name, a different requested value, or a method that does not match the control's
  phase (`playback.volume` is applied by `playback_attenuation`, the others by `platform_synthesis`) fails the run.
- A preferred control the provider reported nothing for is recorded as `not_applied` with `not_reported`.
- A completed run whose required control is missing or `not_applied` fails. Such a failure comes after commit, so it
  is `Internal` (`details.code: output_mismatch`) and nothing is replayed.
- A cancelled terminal outcome keeps what was reported before the stop, and records the rest as `not_reported`;
  cancellation stays an ending, not a failure.

An error carries no output, and so no records; provenance and the route reasons explain it.
`contracts/fixtures/execution/control-outcomes.json` holds the cases.

The facades expose these records unchanged through `output.speech`, with the voice, locale and provenance already there.

### 5. Version 1.1, one version at a time

Every run-scoped document moves from `schemaVersion` `"1.0"` to `"1.1"`: `TaskRequest`, `TaskResult`,
`StreamRunHandle`, `StreamEvent`, `StreamTerminalOutcome`, `IndeRunError` and `ExecutionProvenance`. An SDK at 1.1
accepts and emits only 1.1. A request with `"1.0"`, any other value or none fails validation before routing, with the
existing `Internal` error.

This is a coordinated rollout, not a dual-version window. The packages are pre-1.0, so the SDKs and the bridge move
together, and a second accepted version would only add a branch to every engine. It is also what makes old binaries
fail closed. Every released engine and bridge already rejects an unknown version before execution:

| Endpoint (0.5.x)        | What it does with `"1.1"`                                                |
| ----------------------- | ------------------------------------------------------------------------ |
| Web engine              | Ajv rejects `/schemaVersion` as not equal to the constant.               |
| Swift engine and bridge | Decoding `SchemaVersion` throws, so the request never reaches routing.   |
| Kotlin bridge           | `parseSchemaVersion` throws `Unsupported schemaVersion '1.1'.`           |
| Kotlin engine           | Cannot construct a 1.1 request: its `SchemaVersion` has no such value.   |

So a control can never be stripped on the way to an old engine: the request is refused first. The Swift convenience
initializers that turned an unknown version string into 1.0 take a typed `SchemaVersion` instead, so the new SDK cannot
reintroduce that path. Nothing is promised for binaries already released beyond the refusal above.

**Package boundary.** A contract version change ships in a new SDK minor, never in a patch: pre-1.0 a breaking change
is a minor release (`release.config.js`). Supported combinations are an SDK and a bridge release built for the same
minor line. The bridge holds its core dependency to that line: an exact version on npm and Maven, and
`.upToNextMinor(from:)` on SwiftPM, which already admits patches only. A bridge built for 0.5 therefore cannot resolve
an SDK with contract 1.1, and the bridge release that adopts 1.1 moves all three to the new minor together (#250).

The capability and output schemas carry no version of their own. Their new fields are optional, and losing them is
safe: a consumer that drops `controls` or `controlStates` sees no support, which is the unknown state. The planner
schemas carry none either, but their control fields are execution instructions, not metadata; section 3 makes a lost
plan fail closed.

The `$id` path segment stays `/1.0/`. It names the 1.x schema family; only a breaking change of shape moves it.

### 6. Amendments

- **ADR 018 §3a.** The normalized speaking rate is decided here, together with pitch and playback volume. The rest of
  §3a stands: settings with no shared meaning, such as stability, style or a seed, belong to the provider instance and
  are typed there; there is still no per-request passthrough or vendor map.
- **ADR 016 §6.** Additions that only add information stay inside the current version. An addition whose silent loss
  changes what executes, such as a hard requirement, raises the minor `schemaVersion` so that older consumers refuse it.
  `contracts/README.md` states the rule.

## Consequences

- An application builds one settings screen from `listVoices({ includeControls: true })`, which reads the same
  `checkCapabilities()` snapshot as routing, and uses the same options for a preview and for speech.
- Every request, result and stream document changes its version string, so every hand-built 1.0 payload must be
  updated. The facades do it themselves.
- Support is reported per voice, so a voice list is larger, and a provider must state support for each voice it
  cannot vouch for at task level.
- The planner gains a third requirement family next to locale and voice. Its ranking stays unchanged for requests that
  carry no controls.
- The Kotlin planner serializer and the Kotlin bridge serializer are hand-written, so each new field has to be added
  there by hand; their coverage tests fail otherwise.
- Neural speech providers declare no utterance controls. A per-utterance Articulino speed needs evidence and its own
  decision.
- Out of scope: SSML, lexicons, words per minute, loudness or timbre normalization, device volume, audio DSP, vendor
  parameter maps, new providers and OS floor changes.
