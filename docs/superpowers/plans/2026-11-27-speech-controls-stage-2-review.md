# Speech Controls Stage 2 Review Fixes

Fixes for the five inline findings of PR #312 review 6075777217 (issue #311, ADR 025 Accepted).
Branch `feat/311-speech-controls`, draft PR #312 into `dev`. Spec: `docs/architecture/decisions/025-speech-controls.md`.

## Global Constraints

- ADR 025 stands; do not reopen it. Owner decisions (fixed): single schema version 1.1; strongly typed control ids;
  relative rate/pitch with 1.0 = voice baseline; playback-only volume; `required` = validated support + successful
  application; routing policy > control preferences; voice preference ranks before preferred-control satisfaction;
  unknown availability or unknown range never satisfies a required control; neural providers declare no controls.
- Keep `serde_json` `float_roundtrip` and exact control-plan value equality. No floating-point tolerances.
- Unknown is never support. Contradictions are refused, never resolved.
- Every refusal that must keep fallback available happens **before `commit()`** and is a `CapabilityMismatch`
  (TS `createCapabilityMismatch`, Kotlin `createCapabilityMismatch`), never after sound plays.
- Preserve privacy, locality, cancellation (no events after cancel, terminal cancelled outcome) and commit guarantees.
- A request without speech controls must plan exactly as before: every existing case in
  `contracts/fixtures/routing/planner-conformance.json` keeps its expected result unchanged.
- Shared fixtures are the cross-SDK contract: a new planner case goes into
  `contracts/fixtures/routing/planner-conformance.json` (read by Rust `tests.rs`, Web, Swift and Kotlin conformance
  tests); a new listVoices case goes into `contracts/fixtures/facade/list-voices.json`. Append cases textually; do not
  reformat existing content.
- When the Rust route core changes: `cargo fmt`, `cargo clippy -p inderun_route_core --all-targets -- -D warnings`,
  `cargo test -p inderun_route_core`, `pnpm build:wasm`, `pnpm check:wasm-size` (budget 425,984 raw / 134,144 gzip;
  raise only if this change grows it, in the same commit), `pnpm build:route-core-apple` and commit both XCFrameworks
  with both regenerated `*.provenance.json`, then `pnpm verify:route-core-apple`.
- Swift build/test needs the ONNX workaround (issue #313): seed `.build/repositories` from
  `~/Library/Caches/org.swift.swiftpm/repositories` if missing and run `swift build --skip-update` /
  `swift test --skip-update`.
- Commits: Conventional Commits, `fix(<scope>): ...`, no `BREAKING CHANGE`. End each message with the trailer
  `Co-Authored-By: Claude <model name> <noreply@anthropic.com>` naming the model that wrote it. Do not push.
- Docs: update a doc comment or architecture doc only where the changed behaviour is described.

## Task 1: Rust planner — declaration invariants and bound-voice locale rank (findings 1 and 2)

Files: `rust/inderun-route-core/src/controls.rs`, `rust/inderun-route-core/src/planner.rs`,
`rust/inderun-route-core/src/tests.rs`, `contracts/fixtures/routing/planner-conformance.json`,
`contracts/fixtures/facade/list-voices.json`, the three `listVoices` merges
(`packages/inderun-web/src/facade/speech.ts` `voiceControls`, and its Swift and Kotlin counterparts in
`ios/IndeRun/Sources/IndeRunSwift/` and `android/inderun-kotlin/src/main/kotlin/.../sdk/`; find them by the doc comment
"The merge is the route planner's"), rebuilt WASM/XCFramework artifacts.

**Finding 1 (review comment 4709707269).** `SpeechControlDeclaration` is a typed struct; Swift/Kotlin hand typed
declarations to the route core through serde, not JSON Schema, so a provider can declare `speech.speakingRate` as
`valueKind: choice` or `playback.volume` as `phase: synthesis` with an available range, and `control_support` accepts it.
Fix: in `control_support`, a declaration that breaks its id's invariant makes the control `Unsupported` for every
delivery. The invariant mirrors the schema's `allOf` in `contracts/schemas/provider-descriptor.schema.json`:
- `speech.speakingRate`, `speech.pitch`: `valueKind == number` and `phase == synthesis`.
- `playback.volume`: `valueKind == number` and `phase == playback`.
- `phase == playback` ⇒ `deliveries` contains only `playback`.
Put the invariant in one small function with a doc comment. Update the module invariants comment.
`listVoices` must agree: in all three facade merges, a declaration that breaks the invariant lists each of its
deliveries with `available: false, reason: "contradictory declaration"` (the same output the merge already gives a
duplicated id), regardless of states, and under the existing `includeUnavailable` filtering rules.
Tests: planner-conformance cases (representable, not schema-valid — the fixture runner must feed them to the planner
directly; check how existing runners load provider descriptors and confirm none of them schema-validates descriptors
first; if one does, mark these cases so that runner skips validation for them, and say how in the report):
`controls_contradictory_rate_choice_rejected` (required rate on a provider declaring rate `valueKind: choice` with an
available range ⇒ rejected with `speech_control_unsupported`, another conforming provider selected),
`controls_contradictory_volume_synthesis_rejected` (required volume declared `phase: synthesis`),
`controls_contradictory_volume_artifact_delivery` (volume `phase: playback` with `deliveries: [playback, artifact]` and a
required volume on playback ⇒ unsupported), and one preferred case showing the plan entry is `omit` with reason
`unsupported`. A list-voices fixture case for the contradictory declaration. Rust unit test for the invariant function.

**Finding 2 (review comment 4709707280).** `locale_rank` counts any usable voice with the exact tag that meets required
controls, but ignores `voice_fits` (required gender/id) and readiness. Example: required female voice + required rate,
en-US language-match request; provider A has an en-US male voice supporting the rate and an en-GB female voice; provider
B has a ready en-US female voice supporting the rate. Both rank 0 and provider id may pick A, which must bind en-GB.
Fix: when `requested_controls(input)` is `Some`, derive the locale rank from the voice `select_voice` actually binds:
rank 0 when the bound voice speaks the exact tag, else 1; when the provider lists no voices keep the existing
`known_locales` rule. When `requested_controls(input)` is `None`, keep today's code path exactly (legacy ordering
unchanged). Update the `locale_rank` doc comment and, if ADR 025 §3 wording on "eligible voice" needs no change, leave
the ADR alone (it says the locale rank uses the voice the candidate can bind).
Tests: planner-conformance `controls_locale_rank_bound_voice_gender` (the example above: B selected, A ranked behind) and
`controls_locale_rank_bound_voice_not_prepared` (A's only exact-region voice is `readiness: not_prepared`, its ready
voice is another region; B selected), plus a no-control twin of the gender case showing the old ordering is unchanged
(write down in the report what the old ordering gives and assert exactly that).

Run all Rust checks and rebuilds from Global Constraints, then `pnpm test:js` (Web conformance), the Swift and Kotlin
conformance tests (`swift test --skip-update --filter Conformance`, `cd android && ./gradlew :inderun-core:test
:inderun-kotlin:test`), `pnpm verify:enum-wire-parity`, `pnpm format:check:js`. One or two commits, scope
`route-core` (and `sdk` for the facades if separate).

## Task 2: Web system speech — live control recheck before commit (finding 3)

Files: `packages/inderun-web/src/providers/system-speech/provider.ts` and its test file(s) in the same directory.

**Finding 3 (review comment 4709707289).** Capability discovery gives a voice control states only when
`localService === true` (`toListedVoice`), but `resolveVoice` at turn time checks only the URI. A queued run whose voice
kept its URI but is now `localService` false/undefined reuses the old apply plan and reports rate/pitch/volume applied.
Fix: after `resolveVoice` and **before** `context.commit()`, re-evaluate each `apply` entry of `context.controls` against
the live voice: the live voice supports the controls only when it is bound and `localService === true` (the same rule as
`toListedVoice`; share one predicate so they cannot drift). If support is lost:
- a `required` entry ⇒ throw `createCapabilityMismatch` with `details: { code: "speech_control_unsupported" }`, runId and
  providerId, before commit, so the engine falls back;
- a `preferred` entry ⇒ becomes `not_applied` with reason `availability_unknown` (what the planner would now compute,
  since the voice has no states) and its value is not passed to the runtime.
`controlRecords` and `appliedValues` must both read the rechecked plan. The value range is a constant, so only
availability can change. A run whose live voice still qualifies behaves exactly as today.
Tests: extend the existing queued-voice-removal fake-runtime test pattern: (a) required rate, voice keeps URI but
`localService` flips to `false` between planning and turn ⇒ CapabilityMismatch `speech_control_unsupported`, nothing
spoken, `commit` not called; (b) same with `localService` becoming `undefined`; (c) preferred pitch + volume with the same
flip ⇒ run succeeds, records `not_applied`/`availability_unknown`, runtime receives no pitch/volume; (d) an engine-level
test (through `IndeRun`/engine with two providers, if the existing test helpers allow it cheaply) showing case (a) falls
back to the next candidate; if no such helper exists, say so in the report instead of building one.
Run `pnpm test:js`, `pnpm lint`, `pnpm format:check:js`. One commit, scope `providers`.

## Task 3: Android system speech — restore failure and lost volume before commit (findings 4 and 5)

Files: `android/inderun-system-speech-providers/src/main/kotlin/app/independo/inderun/providers/systemspeech/AndroidSystemSpeechProvider.kt`
and its unit tests (fake engine) under `android/inderun-system-speech-providers/src/test/`.

**Finding 4 (review comment 4709707295).** `resetSpeechRate`/`resetPitch` return false on refusal; `restore` keeps the
dirty flag but returns normally, so after a rate 0.8 run, a following no-control run whose reset fails commits and speaks
at 0.8. A refused preferred setter whose restore also fails reports `not_applied` while the old value stays.
Fix: inside the turn and before commit, when a setting must be restored (not applied by this plan and in
`changedSettings`, or a refused preferred setter) and the restore fails, retry the reset once; if it still fails, refuse
the attempt before commit with `createCapabilityMismatch(..., details = mapOf("code" to "speech_settings_not_restored"))`.
The setting stays in `changedSettings`, so the next utterance tries again. Do not substitute 1.0 for the user's default.
Document the new `details.code` in the provider's doc comment and in the Android row/section of
`docs/architecture/system-speech-provider-family.md` (or wherever the Android error mapping is listed — find it) and the
Provider Matrix in `docs/architecture/providers.md` if it lists error codes for this provider.

**Finding 5 (review comment 4709707308).** `attenuatesPlayback` is a getter. If it was true at planning and false at the
attempt, an `apply` volume entry becomes `not_applied`, then the run commits and speaks unattenuated; the engine's
required-outcome check fails only after sound played. Fix: evaluate volume first, before any setter runs: an `apply`
volume entry on playback with `engine.attenuatesPlayback == false` ⇒ `required` throws `createCapabilityMismatch(...,
details = mapOf("code" to "speech_control_unsupported"))` before commit; `preferred` ⇒ `not_applied` with reason
`unsupported` (existing behaviour). Read `attenuatesPlayback` once per attempt.

Tests (fake engine): (a) rate 0.8 run, then a no-control run where both reset attempts fail ⇒ second run refused with
`speech_settings_not_restored`, nothing spoken, commit not called, and the setting is still pending (a third run with a
working reset restores and speaks); (b) reset fails once then succeeds ⇒ run speaks, setting restored; (c) refused
preferred setter whose restore fails twice ⇒ refused before commit; (d) required volume with `attenuatesPlayback`
toggled false between `describe`/`capabilities` and the attempt ⇒ `speech_control_unsupported`, nothing spoken, no
setter called; (e) preferred volume in the same state ⇒ speaks, record `not_applied`/`unsupported`, no volume passed.
Existing reset tests stay green.
Run `cd android && ./gradlew :inderun-system-speech-providers:test spotlessCheck`. One or two commits, scope `providers`.
