# Speech Controls Stage 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the accepted speech-control contract (ADR 025, issue #311, PR #312) work end to end: the shared Rust planner negotiates controls and binds control application plans; the three engines refuse inconsistent plans, pass plans to providers and validate control outcomes; `listVoices()` projects control states; the Android, Apple and Web system speech providers apply rate, pitch and playback volume; neural providers declare nothing; docs and demos follow.

**Architecture:** The contract is already on the branch (`contracts/schemas/*`, generated types, projections, facades, fixtures). This plan adds behaviour only, against those shapes. The planner is the one decision point; engines hand its `candidates[].controls` to the attempt in `RunContext`; providers apply `decision: apply` entries before commit and report one `SpeechControlOutcome` per requested control; engines complete and check the records. Shared JSON fixtures are the source of truth for cross-SDK behaviour.

**Tech Stack:** Rust (route core, `cargo test`), TypeScript (Vitest, Ajv), Swift 5.9 SwiftPM + XCTest, Kotlin/Gradle + JUnit 4 (Robolectric where `org.json` is read).

**Spec:** `docs/architecture/decisions/025-speech-controls.md` (accepted) and issue #311. Read ADR 025 §2–§4 before any task. Related: ADR 016 §4 (refusal stages), ADR 018 §3–§4 (voice binding, locality), ADR 019 (readiness), `docs/architecture/system-speech-provider-family.md`.

## Global Constraints

- Branch `feat/311-speech-controls` (PR #312, draft). Commit on it; do not push, do not open PRs, do not change PR state.
- Do not change anything under `contracts/schemas/`, and do not hand-edit generated files (`packages/contracts/src/generated/`, `ios/IndeRun/Sources/IndeRunContracts/Contracts.swift`, `android/inderun-contracts/.../Contracts.kt`, `rust/inderun-route-core/src/generated/contracts.rs`). If a task seems to need a schema change, stop and report NEEDS_CONTEXT.
- Fixture JSON files are the cross-SDK source of truth. When a task adds cases to an existing fixture, append them and keep the file's existing formatting (run `npx prettier --write <file>` only if the file was already Prettier-clean at HEAD; check with `git show HEAD:<file> | npx prettier --check --stdin-filepath <file>`).
- Control ids, in the planner's fixed order: `speech.speakingRate`, `speech.pitch`, `playback.volume`. Requirement default is `preferred`.
- Error and reason vocabulary, exactly:
  - Route rejection codes: `speech_control_unsupported`, `speech_control_out_of_range` (already in the schemas).
  - Plan omission reasons: `unsupported`, `out_of_range`, `range_unknown`, `availability_unknown`.
  - Outcome reasons: the four above plus `provider_rejected`, `not_reported`.
  - Outcome methods: `platform_synthesis` (rate, pitch), `playback_attenuation` (volume).
  - Engine failures: `Internal` with `details.code: "control_plan_mismatch"` (plan inconsistent with request, no attempt made); `Internal` with `details.code: "output_mismatch"` (control records violate ADR 025 §4).
  - Provider pre-commit refusal of a required control the platform rejects: `CapabilityMismatch` with `details.code: "speech_control_unsupported"` (fallback-eligible).
- Support rule (ADR 025 §2): a control satisfies a request only when (a) the task capability declares it once, with `lifetime: utterance` and the requested delivery in `deliveries`; (b) the merged state for `(id, delivery)` has `available: true`; (c) the merged `range` is known and `min <= value <= max`. Merge: the task's `controlStates` entry for `(id, delivery)`, overlaid field by field by the bound voice's entry for the same `(id, delivery)`. Two entries for one `(id, delivery)` at one level, or one id declared twice, make that control unsupported for that provider. A state for a delivery the declaration does not list is ignored.
- Never clamp, approximate, time-stretch or apply gain. Never infer application from the request.
- Existing behaviour must not change for requests without controls: every existing case of `contracts/fixtures/routing/planner-conformance.json` keeps its exact expected plan, and every existing test suite stays green.
- No new third-party dependency anywhere. Native OS and package floors do not change.
- Commits: Conventional Commits; scopes `route-core`, `sdk`, `providers`, `docs`; demo work is `feat(demo)`. End every commit message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. No `BREAKING CHANGE` footer unless the task says so.
- Tooling notes: Swift builds need the local SwiftPM cache workaround because `microsoft/onnxruntime-swift-package-manager` is currently unreachable (#313). Use `swift build --build-tests --skip-update` / `swift test --skip-update` (network-disabled sandbox may need lifting). Formatting and lint: `pnpm format:js` + `npx eslint --ignore-pattern 'tmp/**' .` (TS); `(cd ios/IndeRun && swiftlint lint --strict)`; `cd android && ./gradlew spotlessApply` before every Kotlin commit. Gradle filtered tests: `./gradlew :<module>:testDebugUnitTest --tests '<pattern>'`.
- Rust route-core changes require, in the same task: `cargo fmt -p inderun_route_core -- --check`, `cargo clippy -p inderun_route_core --all-targets -- -D warnings`, `cargo test -p inderun_route_core`, `pnpm build:wasm` + `pnpm check:wasm-size` (budget must hold; do not raise it), and `pnpm build:route-core-apple` with the regenerated XCFrameworks and both `*.provenance.json` committed, then `pnpm verify:route-core-apple`.

## Review Focus

1. Required controls are never lost or ignored: planner filter, plan integrity check, provider pre-commit refusal, outcome check.
2. No change to existing plans or behaviour without controls.
3. Commit placement and cancellation: a control refusal happens before commit; after commit nothing is replayed; nothing is delivered after cancel.
4. Cross-SDK parity: every new behaviour is pinned by a shared fixture that all applicable SDKs run behind a guard test.

---

### Task 1: Rust planner — control negotiation, voice binding, application plans

**Files:** `rust/inderun-route-core/src/planner.rs`, `rust/inderun-route-core/src/tests.rs`, `contracts/fixtures/routing/planner-conformance.json`; regenerated `ios/IndeRun/Frameworks/*` (XCFrameworks + provenance).

Implement ADR 025 §3 in the planner, reading `input.task.controls` (absent or empty means no controls; then nothing in this task may change behaviour).

1. **Effective state.** A helper that, for a provider task capability, an optional voice, a control id and the requested delivery (`input.task.delivery.mode`, `playback` or `artifact`), returns one of: `Supported { range }`, `Unsupported` (not declared once for this delivery with lifetime `utterance`, contradictory duplicate declarations or states, or merged `available: false`), `AvailabilityUnknown` (merged `available` absent), `RangeUnknown` (available true, no merged range). Merge per the Global Constraints support rule. A request on a delivery other than playback/artifact has no controls to evaluate (text never carries them).
2. **Required controls filter voices.** In `select_voice` (and wherever voice fit is evaluated for rejection), a voice qualifies only if every `required` control is `Supported` with the value inside the range. A provider that lists no voices is evaluated against the task state alone (no voice overlay). A required voice id is never substituted.
3. **Rejection.** In `evaluate_provider`, after the existing locale/voice checks: when the request has required controls and no qualifying voice remains (or, without a voice list, the task state fails), add reasons:
   - For each required control that no locale/trait/privacy-fit voice satisfies on its own: `speech_control_out_of_range` if some fit voice (or the task state) has it `Supported` with the value outside the range, else `speech_control_unsupported`. Message names the control id and the value, e.g. `"speech.speakingRate 3 is outside every voice's range"` / `"no voice supports required speech.pitch for playback"`.
   - If each required control is satisfiable alone but no single voice satisfies all together: one `speech_control_unsupported` reason, message `"no single voice supports every required speech control"`.
   Keep the existing reason order and early-return behaviour of `evaluate_provider`; add the control check at the point where voice fit is decided, and follow the existing pattern for whether later checks still run.
4. **Ranking.** `priority_tuple` becomes `(placement, profile, preference, voice, controls, locale)`. `controls` rank = number of `preferred` controls NOT satisfied by the voice the provider would bind (task state when it lists no voices); lower is better; 0 for everyone without controls. Inside `select_voice`, insert "more preferred controls satisfied" after preferred gender and before the existing readiness/region/local/listing keys.
5. **Locale rank reads eligible voices.** In `locale_rank`, the "offers the exact tag" test considers only voices that also satisfy every required control (the same eligibility as step 2). Without required controls this is unchanged. Ruling recorded: ADR 025 §3 "the voice it would bind: one that meets every hard requirement" is implemented as the eligible-voice set, which keeps every existing plan unchanged; Task 9 aligns the ADR sentence.
6. **Application plan.** For each candidate, when the request has controls, set `candidates[].controls`: one `ControlApplicationPlan` per requested control in request order, with the request's `id`, `value`, `requirement`; `decision: apply` when `Supported` and in range on the bound voice (or task state without voices), else `decision: omit` with `reason` mapped `Unsupported → unsupported`, value outside range → `out_of_range`, `RangeUnknown → range_unknown`, `AvailabilityUnknown → availability_unknown`. Required controls are always `apply` (guaranteed by the filter). Without controls `controls` stays `None` (replace the current `controls: None` stub at `planner.rs:69`).
7. **Prepare mode** (`interactionMode: prepare`): controls are ignored (PrepareRequest carries none); keep `None`.
8. **Fixtures.** Append cases to `contracts/fixtures/routing/planner-conformance.json` (complete `RoutePlannerInput` + exact expected `RoutePlan`, messages included; generate `expected` from the planner and review each by hand). Cover at least: `controls_required_supported`, `controls_required_unsupported`, `controls_required_out_of_range`, `controls_conflicting_voices` (two voices, each meets one of two required controls → rejected with the "no single voice" reason), `controls_required_voice_id_not_substituted` (required id voice lacks the control → rejected even though another voice has it), `controls_preferred_voice_before_controls` (preferred id voice without the preferred control is still bound), `controls_sparse_voice_override` (voice disables pitch; another voice inherits task state), `controls_unknown_availability` (required → unsupported; preferred → omit `availability_unknown`), `controls_range_unknown`, `controls_by_delivery` (rate supported for playback, out of range for artifact), `controls_preferred_soft_ordering` (two otherwise equal providers; the one satisfying more preferred controls ranks first; placement and profile still win over it in a second case), `controls_local_required_network_voice` (only a network voice supports the control → rejected under `local_required`), `controls_profile_allow_list` (provider outside the profile that supports the control stays rejected with `not_in_model_profile`), `controls_contradictory_declaration`, `controls_no_voice_list_task_state`, `controls_locale_rank_ignores_ineligible_voice`. All 53 existing cases must keep their expected plans byte for byte.
9. Unit tests in `tests.rs` for the effective-state merge and reason selection. Run the Rust gates from the Global Constraints, the WASM conformance (`pnpm --filter @independo/inderun-route-core-wasm test`), `pnpm --filter @independo/inderun-contracts test`, the Swift `RoutePlannerConformanceTests` and the Kotlin `SharedCoreRoutePlannerConformanceTest` (both read the same fixture through FFI/JNI).

Commit: `feat(route-core): negotiate speech controls and bind control application plans`.

---

### Task 2: Web engine — control plans in, outcome records out (+ shared execution catalog)

**Files:** `packages/inderun-web/src/core/provider.ts` (RunContext), `engine.ts`, `task-profiles.ts`, new tests; new `contracts/fixtures/execution/control-execution.json`.

1. `RunContext` gains `controls?: ControlApplicationPlan[]` (the candidate's plan, verbatim). The engine passes it with the bound voice to every attempt (run and stream).
2. **Plan integrity** (ADR 025 §3, `contracts/fixtures/execution/control-plan-integrity.json`): after planning, before the first attempt, check every candidate's `controls` against the request's projected controls: same length, request order, same id/value/requirement, every required `decision: apply`, absent or empty counts as mismatch when the request has controls, any entries when the request has none is a mismatch. Failure: `Internal`, `details.code: "control_plan_mismatch"`, provenance with `attemptCount: 0`. Put the check next to the existing projection/rechecks in `task-profiles.ts` (exported helper) and call it from both run and stream paths.
3. **Outcome check** (ADR 025 §4, `contracts/fixtures/execution/control-outcomes.json`): extend `checkOutput` (or a helper it calls) to validate and complete `output.speech.controls` for completed runs and cancelled terminals, exactly as the fixture describes; failures `Internal`, `details.code: "output_mismatch"`. For a request without controls the provider's `output.speech.controls` must be absent or empty (otherwise `output_mismatch`).
4. **Handlers**: one test file running both catalogs: each case id maps to a handler, and a guard test asserts the handler ids equal the catalog ids (follow the pattern of `artifacts.conformance.test.ts` / the engine-conformance handlers). Plan-integrity cases inject a planner returning the case's candidate(s) (find the existing planner injection seam used by `route-planner.test.ts` / router tests).
5. **New catalog `contracts/fixtures/execution/control-execution.json`** (scenario catalog, `$comment` header in the house style), with handlers in this task and in Tasks 3 and 4. Cases, each with a fake speech provider pair or single provider and a request with a required rate:
   - `precommit_control_refusal_falls_back_once`: primary throws `CapabilityMismatch` `speech_control_unsupported` before commit; secondary succeeds; exactly two attempts, `fallbackOccurred: true`, the secondary received its own plan.
   - `postcommit_failure_is_not_replayed`: primary commits then fails; one attempt, run fails, secondary never called.
   - `cancel_before_commit_runs_nothing`: cancel while the provider waits before commit; terminal `cancelled`, no commit, no further attempt.
   - `cancel_after_commit_keeps_known_records`: provider commits, reports the rate as applied, then is cancelled; terminal `cancelled` carries the rate record applied and others `not_reported`.
   - `late_callback_after_cancel_is_suppressed`: provider emits after cancel; no event after the terminal.
   - `plan_reaches_provider`: the provider's `RunContext.controls` equals the candidate's plan.
   Add `packages/contracts` shape validation for the new catalog to `packages/contracts/src/control-fixtures.test.ts`.
6. Route rejections with the new codes must already flow into `details.rejectedProviders` and provenance; add one engine-level test that a request whose only provider is rejected with `speech_control_unsupported` fails `CapabilityMismatch` with that code in provenance `routeRejections`.

Commit: `feat(sdk): web engine passes control plans and validates control outcomes`.

---

### Task 3: Swift engine — same as Task 2

**Files:** `ios/IndeRun/Sources/IndeRunCore/Provider.swift` (RunContext), `ios/IndeRun/Sources/IndeRunSwift/IndeRun.swift`, `ios/IndeRun/Sources/IndeRunCore/TaskProfiles.swift`, new tests under `ios/IndeRun/Tests/IndeRunTests/`.

Port Task 2 items 1–4 and 6 to Swift with identical semantics, messages where shared fixtures pin them, and handlers for all three catalogs (`control-plan-integrity.json`, `control-outcomes.json`, `control-execution.json`) behind guard tests. `RunContext` gains `controls: [ControlApplicationPlan]?` with a default of `nil` so existing providers and tests compile. Use the existing planner injection seam (`TaskProfileTests.planRoute` style) for plan-integrity cases. Run `swift test --skip-update` fully and SwiftLint.

Commit: `feat(sdk): swift engine passes control plans and validates control outcomes`.

---

### Task 4: Kotlin engine — same as Task 2

**Files:** `android/inderun-core/src/main/kotlin/app/independo/inderun/core/Provider.kt` (RunContext), `TaskProfiles.kt`, `android/inderun-kotlin/src/main/kotlin/app/independo/inderun/sdk/IndeRun.kt`, new tests.

Port Task 2 items 1–4 and 6 to Kotlin with handlers for all three catalogs behind guard tests. `RunContext` gains `val controls: List<ControlApplicationPlan>? = null`. Check `SharedCoreRoutePlanner.kt` parses `candidates[].controls` (it does since Stage 1; extend `SharedCoreRoutePlannerConformanceTest` to compare parsed `controls` field by field like it does for voices). Run `./gradlew test spotlessCheck`.

Commit: `feat(sdk): kotlin engine passes control plans and validates control outcomes`.

---

### Task 5: `listVoices()` control projection on all three SDKs

**Files:** `packages/inderun-web/src/facade/speech.ts`, `ios/IndeRun/Sources/IndeRunSwift/SpeechGeneration.swift`, `android/inderun-kotlin/src/main/kotlin/app/independo/inderun/sdk/SpeechGeneration.kt`, `contracts/fixtures/facade/list-voices.json` (append cases), the three facade test files.

1. Options: Web `ListVoicesOptions` gains `includeControls?: boolean`, `includeUnavailable?: boolean`; Swift `listVoices(locale:localeMatch:includeControls:includeUnavailable:)`; Kotlin `listVoices(locale, localeMatch, includeControls = false, includeUnavailable = false)`. Defaults keep today's output exactly.
2. New facade type `SpeechVoiceControl` on each SDK: `id` (`SpeechControlId`), `delivery` (`ControlDelivery`), `phase` (`SpeechControlPhase`), `available?: boolean`, `reason?: string`, `range?: SpeechControlRange`. `SpeechVoiceInfo` gains `controls?: SpeechVoiceControl[]` (only with `includeControls`) and `available?: boolean` (set to `false` only under `includeUnavailable` for a voice whose provider or task is unavailable; absent otherwise).
3. With `includeControls`: one entry per declared `lifetime: utterance` control × each declared delivery, in declaration order then delivery order, with the merged state (same merge and contradiction rules as the planner; a contradiction yields `available: false`, `reason: "contradictory declaration"`; unknown availability stays absent). `provider_instance` controls are not listed. Voices of unavailable providers/tasks (only with `includeUnavailable`) list their controls with `available: false` and no range.
4. With `includeUnavailable`: also list voices of providers or tasks with `available: false`, keeping their known metadata and readiness. Discovery stays a pure projection of `checkCapabilities()`: no prepare, download, load or synthesis.
5. Append to `list-voices.json`: `controls_by_delivery_with_voice_override`, `controls_unknown_state_stays_unknown`, `controls_contradictory_declaration`, `controls_provider_instance_not_listed`, `include_unavailable_disables_controls`, `default_listing_unchanged_with_controls_declared`. Each SDK's list-voices vector test runs every case (extend the Swift/Kotlin fixture mappers for the new options and expected fields).

Commit: `feat(sdk): listVoices projects speech control states`.

---

### Task 6: Web system speech provider applies controls

**Files:** `packages/inderun-web/src/providers/system-speech/{provider.ts,runtime.ts,browser-runtime.ts}` and their tests.

1. Descriptor task capability `controls`: `speech.speakingRate` and `speech.pitch` (`number`, `synthesis`, `utterance`, deliveries `["playback"]`), `playback.volume` (`number`, `playback`, `utterance`, `["playback"]`).
2. Capabilities: no task-level `controlStates`. Every voice with `localService: true` gets voice `controlStates` for playback: rate `available: true, range {min 0.5, max 2, default 1, step 0.1}`, pitch same, volume `{min 0, max 1, default 1, step 0.05}`. Voices with `localService: false` or unknown get none (unknown), so required controls never route to them. Do not claim support from API property presence alone; comment the source (Web Speech API `SpeechSynthesisUtterance.rate` 0.1–10, `pitch` 0–2, `volume` 0–1; ranges chosen conservatively, device evidence pending in `docs/verification/system-speech.md`).
3. Execution: `SystemSpeechUtterance` gains `rate?`, `pitch?`, `volume?`; the provider sets them from `RunContext.controls` entries with `decision: apply` (unset otherwise, so the browser default applies), before commit; `browser-runtime.ts` assigns them to the utterance. Output `speech.controls`: one record per plan entry, `apply` → `applied` with `effective = value` and the method by id; `omit` → `not_applied` with the plan's reason.
4. Tests: mock synthesis assertions that the utterance carries exactly the applied values and nothing for omitted ones; a run without controls leaves the properties unset; records; capability fidelity (local vs network voice states); cancellation unchanged.

Commit: `feat(providers): web system speech applies rate, pitch and volume`.

---

### Task 7: Apple system speech provider applies controls

**Files:** `ios/IndeRun/Sources/IndeRunAppleProviders/{AppleSpeechRuntime.swift,AppleSystemSpeechProvider.swift}`, tests `AppleSystemSpeechProviderTests.swift` (+ artifact tests).

1. Declarations: rate and pitch (`synthesis`, deliveries `["playback","artifact"]`), volume (`playback`, `["playback"]`).
2. Task-level `controlStates` (all installed voices): rate playback and artifact `available: true, range {min 0.5, max 2, default 1, step 0.05}`; pitch playback and artifact `{min 0.5, max 2, default 1, step 0.05}`; volume playback `{min 0, max 1, default 1, step 0.05}`. Rate mapping: `utterance.rate = AVSpeechUtteranceDefaultSpeechRate * r`; the range 0.5–2 keeps the result inside `AVSpeechUtteranceMinimumSpeechRate…AVSpeechUtteranceMaximumSpeechRate` (verify with the constants in a test, never clamp). Pitch: `pitchMultiplier = p` (documented 0.5–2.0). Volume: `utterance.volume = v`, playback only.
3. The runtime protocol's `speak` and `render` take an applied-controls value (rate/pitch for both, volume for speak only). When any control is applied, set `prefersAssistiveTechnologySettings = false` explicitly (document why: otherwise the user's assistive-technology speech settings may override the requested values); when none is applied, leave the utterance as today.
4. Records as Task 6; `effective` = requested value in shared units.
5. Tests with the existing fake runtime: playback sets rate/pitch/volume; render sets rate/pitch and never volume; omitted controls leave defaults; records; a run without controls is unchanged; cancellation unchanged.

Commit: `feat(providers): apple system speech applies rate, pitch and volume`.

---

### Task 8: Android system speech provider applies controls

**Files:** `android/inderun-system-speech-providers/src/main/kotlin/app/independo/inderun/providers/systemspeech/{AndroidSpeechEngine.kt,PlatformAndroidSpeechEngine.kt,AndroidSystemSpeechProvider.kt}`, tests in `android/inderun-system-speech-providers/src/test/...` and `android/inderun-kotlin/src/test/.../AndroidSystemSpeechEngineTest.kt` as appropriate.

1. Declarations: rate and pitch (`synthesis`, `["playback","artifact"]`), volume (`playback`, `["playback"]`).
2. Task-level `controlStates`: rate and pitch, playback and artifact, `available: true, range {min 0.5, max 2, default 1, step 0.05}`; volume playback `{min 0, max 1, default 1, step 0.05}`. Comment: `TextToSpeech.setSpeechRate`/`setPitch` document 1.0 as normal with no upper bound; the range is a conservative choice pending device evidence.
3. Inside the existing serialized turn, before commit: select the voice, then `setSpeechRate(r or 1.0)` and `setPitch(p or 1.0)` every utterance (omitted ⇒ reset to 1.0, so settings never leak between queued utterances); check each return code. A setter returning `TextToSpeech.ERROR` for a `required` control ⇒ `CapabilityMismatch` `details.code "speech_control_unsupported"` before commit; for a `preferred` one ⇒ record `not_applied` / `provider_rejected` and reset that setting to 1.0. Volume: `KEY_PARAM_VOLUME` in the `speak` params Bundle only; `synthesizeToFile` gets rate/pitch only.
4. Records as Task 6.
5. Fake-engine tests: two queued utterances, first with rate 0.8, second without ⇒ second sees 1.0; setter failure required ⇒ refusal before commit; setter failure preferred ⇒ `provider_rejected`; volume only in speak params; artifact path never sets volume.

Commit: `feat(providers): android system speech applies rate, pitch and volume`.

---

### Task 9: Neural no-claim tests, documentation and contributor guidance

**Files:** neural provider tests on three SDKs; `docs/architecture/providers.md` (Provider Matrix rows for the three system speech providers and the neural family), `docs/architecture/system-speech-provider-family.md`, `docs/architecture/neural-speech-provider-family.md`, `docs/architecture/api-layering.md` (speech table: `controls`, `playback`, `SpeechOptions` split, `listVoices` options), `docs/architecture/architecture.md` (short versioning/controls note if it describes contract versions), `docs/guides/speech.md` (settings screen from `listVoices({ includeControls: true })`, a required-rate example that falls back, an unsupported preferred pitch example, preview and speech through the same call, migration from stored numeric voice indexes to provider-scoped opaque ids — description only), `docs/verification/system-speech.md` (new "Speech controls" section: a checklist of device checks — de-AT/de-DE and English voices, changed rate/pitch/volume, artifact excludes volume, repeated and cancelled utterances, latency, offline — every item marked "not yet run", no fabricated results), `CLAUDE.md` §3 status paragraph (controls ship; native floors unchanged), ADR 025 §3 one-sentence clarification "a voice it could bind" per Task 1's ruling.

1. Neural providers on all three SDKs: a test that the descriptor declares no `controls` and capabilities have no `controlStates`, and that `RunContext.controls` with only `omit` entries yields `not_applied` records rather than an applied claim (if the neural provider does not emit control records at all, the engine's completion makes them `not_reported` — assert that through the engine instead and do not add provider code).
2. Docs follow `CLAUDE.md` §8: durable concepts in architecture docs, details in code comments. Run `pnpm --filter website build` and `pnpm --filter website check:docs` if the website toolchain is installed; otherwise report that they were not run.

Commit: `docs: speech controls across providers, guides and verification`.

---

### Task 10: Demo settings views

**Files:** `packages/inderun-web-demo/src/*`, `ios/SampleApps/IndeRunDemo/IndeRunDemo/*`, `android/inderun-demo-app/src/main/kotlin/app/independo/inderun/demo/*` and their existing tests.

Each demo's speech screen gains rate, pitch and volume controls built from `listVoices({ includeControls: true })` for the selected voice and delivery: a slider per available control using its range/default/step; a control whose state is unavailable or unknown is shown disabled with its reason. Preview and speak use the same `speak()` call with the same options; generate uses `generateSpeech()` with rate/pitch only. After a run, show `output.speech.controls` (applied / not applied with reason). Include a "require rate" toggle that sends the rate as `required`. App-owned persistence of the chosen values follows each demo's existing settings storage; no new storage mechanism. Extend the existing demo tests (`packages/inderun-web-demo` Vitest, `DemoViewModelTest`, iOS demo view-model tests if present) for option building and outcome display. If the iOS demo project is not built by any test target, state so in the report and keep its changes minimal and compiling by inspection.

Commit: `feat(demo): speech control settings in the three demos`.
