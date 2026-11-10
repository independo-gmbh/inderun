# Neural Speech Provider Family (PR 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the runtime-neutral neural speech provider on all three SDKs: one provider class per SDK that takes a `ModelPackage` with a `speech` block and a `NeuralSpeechRuntime`, splits text into sentences, plays the runtime's PCM chunks through `HostServices.audioOutput` (commit before the first write, `stop()` on cancel) or writes them as an `audio/wav` artifact, and reports `PlaybackTiming` with `firstChunkMs` and `firstAudioMs` from one origin. The runtime seams (`NeuralSpeechRuntime`, `SpeechGraphExecutor`, `PcmChunk`, `SpeechTensor`) and a deterministic fixture runtime ship with it; the ONNX executor and the first model pipeline are PR 4.

**Architecture:** The provider lives in a new runtime-free module per SDK (`@independo/inderun-web/neural-speech`, SwiftPM `IndeRunNeuralSpeech`, Gradle `inderun-neural-speech`) and depends on Core only. Two shared fixtures pin cross-SDK behaviour: `contracts/fixtures/speech/neural-frontend.json` (text → sentences → grapheme token ids over an embedded mini vocab) and `contracts/fixtures/speech/neural-speech-lifecycle.json` (a scenario catalog run through each SDK's real engine with the fixture runtime and the PR 2 fixture audio output). Two helpers move into Core first: the model-package validator (Swift and Kotlin; TypeScript's already lives in contracts) and the WAV encoder (Swift). No schema changes, no generated files, no XCFramework rebuild.

**Tech Stack:** TypeScript (Vitest), Swift 5.9 SwiftPM + XCTest, Kotlin/Gradle + JUnit 4 (Robolectric where `org.json` is read), the existing `HostServices.audioOutput` and `ArtifactSink` seams.

**Spec:** `docs/superpowers/specs/2026-11-04-neural-speech-design.md` (§C "Neural speech provider family", §A "New fixtures", §E routing, "Phases / PRs" row 3). ADRs: 020 (model packages, timing origin), 021 (audio output, `audio_output_unavailable`), 019 (prepare/readiness), 017 §6-7 (playback is not an artifact, no media in events).

## Global Constraints

- Hand-written code only: no change under `contracts/schemas/`, no `pnpm generate`, no generated file edits, no `pnpm build:route-core-apple`.
- Each new module depends on Core only: TS imports from `../../core/*` and `@independo/inderun-contracts`; Swift target dependencies `["IndeRunCore", "IndeRunContracts"]`; Gradle `api(project(":inderun-core"))` plus contracts and coroutines, nothing else. No `onnxruntime`, no `@huggingface/transformers`, no new third-party dependency anywhere. Consumer smoke targets gain no imports or dependencies.
- Provider ids: default `local.onnx.speech.web` / `local.onnx.speech.apple` / `local.onnx.speech.android`; the provider's id is `options.id ?? "<default>:<modelPackage.id>"` (composed, so one app registers one provider per model without clashes). Descriptor `model` is `modelPackage.id`.
- Descriptor on all three SDKs: `type: local`, `transport: in_process`, `cancel: hard`, `supports.run: true`, `supports.streaming: true` (lifecycle only, as system speech), `tasks: ["text_to_speech"]`, one task capability `{ kind: text_to_speech, inputs: [text], interaction: { prepare: true, run: true, stream: true }, cancel: hard, outputs: [{ delivery: playback }, { delivery: artifact, mediaTypes: ["audio/wav"] }], locales: <union of speech.voices[].locales in first-seen order, deduplicated>, privacy: { dataLeavesDevice: false } }`, provider `privacy.dataLeavesDevice: false`.
- Capabilities order (ONNX pattern): package validation issues → "model package malformed: …"; `tasks` without `text_to_speech` or `speech` absent → "unsupported task: …"; source type not in the platform list (web: registry, bundled, programmatic, app_managed; Apple and Android: bundled, programmatic, app_managed, filesystem) → "model source unavailable: …"; `runtime.platforms` set and missing the platform → "platform unsupported: …"; `await runtime.availability(pkg)` not available → its reason verbatim; remembered load failure → its reason; else `available: true` with voices and `readiness: cold` until loaded. Voices: one `ProviderVoice` per `speech.voices[]` entry with `id`, `name`, `locale = locales[0]`, `locales`, `gender` when present, `networkRequired: false`.
- Playback path: `receivedAt` is taken as the first statement of the playback path (before the turn wait, voice check and commit). Refuse before commit, in this order: request without `speech` or with `delivery.mode` other than `playback`/`artifact` → `CapabilityMismatch`; host without `audioOutput` → `CapabilityMismatch` `details.code "audio_output_unavailable"` (ADR 021 §2); bound voice id not in the package → `CapabilityMismatch` `details.code "voice_not_available"`; `audioOutput.open()` failures propagate as thrown (`audio_format_unsupported`, `audio_not_allowed`, `audio_output_failed`). Commit immediately before the first `write()`; a cancel before that point returns quietly (no result, no sound). After commit: cancel calls `session.stop()` and stops consuming the runtime, then returns quietly (the engine owns the `cancelled` terminal); any error (runtime failure, `audio_output_interrupted`) is thrown and is not retried. Normal end: `drain()` then `stop()`.
- Artifact path: no `audioOutput` needed. Collect PCM in memory; when `44 + 2 × frames` would exceed `MAX_ARTIFACT_BYTES = 16 × 1024 × 1024` stop synthesis and throw `Unavailable` `details.code "artifact_too_large"` before `finish()` (so the run is uncommitted and may fall back); otherwise `artifacts.create({ mediaType: "audio/wav", durationMs })`, write header + samples once, `finish()` (which commits). The constant duplicates the engine default on purpose, as the system speech providers do.
- `PlaybackTiming`: `firstChunkMs` = first chunk received from the runtime − `receivedAt`; `firstAudioMs` = (`openedAt` − `receivedAt`) + `session.firstAudioMs()` read after `drain()`, absent when the session reports none; `durationMs` = total frames ÷ sampleRate × 1000. All in milliseconds from the same origin (ADR 020 §3). Chunks must carry the package's `speech.sampleRate`; a chunk with another rate is `Internal` ("never resample").
- One utterance at a time per provider instance (the `inTurn` / `SpeechTurns` / `Mutex` patterns of the system speech providers): a call that is cancelled while waiting holds its place and plays nothing.
- Sentence rule, identical on all three SDKs and pinned by the frontend fixture: normalize to NFC; split at `\n`; split after a run of `.`, `!`, `?`, `…` when followed by whitespace or the end of the text; trim each piece; collapse internal whitespace to one space; drop empty pieces; text without a boundary is one sentence. Grapheme tokenizer: lowercase the sentence, map each code point through the vocab, drop code points the vocab lacks. The pipeline-specific normalizers are PR 4.
- Fixture runtime (`createFixtureNeuralSpeechRuntime` / `FixtureNeuralSpeechRuntime`) is deterministic: a 440 Hz sine at −14 dBFS with phase continuous across chunks, `msPerCharacter` (default 50) × sentence length per sentence, chunks of `chunkMs` (default 100), `isLast` on the final chunk of each sentence, `sampleRate` from the package, records every `synthesize` call; honours cancellation between chunks; options script `availability`, `prepareResult`, `failAfterChunks`, `delayMs` (wall delay per chunk, default 0).
- Tests never wait unbounded; every catalog wait is bounded by the case's `timeoutMs`.
- Branch `feat/m5-neural-speech-provider-family` off `dev` (after PR #270 merged), PR into `dev`, Conventional Commits, trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` last.
- Formatting and lint: `pnpm format:js && pnpm lint` (TS), `(cd ios/IndeRun && swiftlint lint --strict)` (Swift, line length 140), `cd android && ./gradlew spotlessApply` before every Kotlin commit. Gradle filtered tests: `./gradlew :<module>:testDebugUnitTest --tests '<pattern>'`.

## Review Focus

1. Nothing audible after cancel: `cancel_mid_stream_stops_audio_once` (Task 2 catalog; Tasks 4-6 handlers) must see the fixture session stopped with discarded frames and the runtime's chunk iteration ended; `cancel_while_waiting_plays_nothing` must see no session opened for the waiting call.
2. Commit placement: `playback_commits_before_first_write` pins exactly one commit after `open()` and before the first `write()`; `missing_audio_output_refuses_before_commit` and `artifact_over_cap_fails_before_commit` pin zero commits and a fallback to the next provider in the profile.
3. Timing origin: `firstChunkMs ≤ firstAudioMs` and `durationMs` equal to the synthesized length on every SDK (`playback_reports_timing`, Task 2).
4. Artifact bytes: `artifact_is_wav_of_the_samples` checks the 44-byte header fields and `byteLength = 44 + 2 × frames` so a stray resample or a truncated sentence fails.
5. Capabilities never load the model: `testNeuralSpeechCapabilityCheckNeverLoadsTheModelAndReportsItCold` (per SDK, Tasks 4-6) asserts the fixture runtime's `prepare` count is 0 after `capabilities()` and readiness is `cold`; an unknown `pipeline` is refused through `runtime.availability` with the reason verbatim.

---

### Task 1: Move the model-package validator into Core (Swift and Kotlin)

**Files:**
- Create: `ios/IndeRun/Sources/IndeRunCore/ModelPackageValidation.swift` (moved from `ios/IndeRun/Sources/IndeRunOnnxProviders/ModelPackageValidation.swift`, which is deleted)
- Modify: `ios/IndeRun/Sources/IndeRunOnnxProviders/OnnxRuntimeAppleProvider.swift:123` (unchanged call; the module already imports `IndeRunCore`)
- Create: `android/inderun-core/src/main/kotlin/app/independo/inderun/core/ModelPackageValidation.kt` (moved from `android/inderun-onnx-providers/src/main/kotlin/app/independo/inderun/providers/onnx/ModelPackageValidation.kt`, deleted)
- Modify: `android/inderun-onnx-providers/src/main/kotlin/app/independo/inderun/providers/onnx/AndroidOnnxRuntimeProvider.kt:128` (import `app.independo.inderun.core.getModelPackageValidationIssues`)
- Create: `android/inderun-core/src/test/kotlin/app/independo/inderun/core/ModelPackageValidationTest.kt` (the validator tests moved out of `android/inderun-onnx-providers/src/test/kotlin/app/independo/inderun/providers/onnx/AndroidOnnxRuntimeProviderTest.kt:215-307`, including the `speechPackage`/`speechVoice` helpers at `:258-272`)
- Modify: `ios/IndeRun/Tests/IndeRunTests/IndeRunTests.swift:1743-1856` (tests stay; they compile against Core through the existing `@testable import IndeRunCore`)
- Modify: `docs/architecture/onnx-runtime-provider-family.md` (the sentence that places the validator in the ONNX modules, if any; and line 183: the descriptor does carry `taskCapabilities` with `interaction.prepare` since ADR 019 — reword to "declares `text_to_text` with `prepare`")

**Interfaces:**
- Produces (Swift, `IndeRunCore`): `public struct ModelPackageValidationIssue: Equatable, Sendable { public let path: String; public let message: String; public init(path: String, message: String) }` and `public func getModelPackageValidationIssues(_ modelPackage: ModelPackage) -> [ModelPackageValidationIssue]` — same rules as today (`/id`, `/source/ref` userinfo, `/speech` required for `text_to_speech`, unique voice ids, structural speech rules, `/integrity/checksums/<key>` secrets). The doc comment drops the "moving this is the first step" sentence and says it is shared by every local-model provider.
- Produces (Kotlin, `app.independo.inderun.core`): `data class ModelPackageValidationIssue(val path: String, val message: String)` and `fun getModelPackageValidationIssues(modelPackage: ModelPackage): List<ModelPackageValidationIssue>`, same rules.
- Consumes: nothing new. TypeScript needs no move: `getModelPackageValidationIssues` is already in `packages/contracts/src/validators.ts:242` and exported from the package index.

- [ ] **Step 1: Write the failing Kotlin test file**

Create `ModelPackageValidationTest.kt` in `inderun-core` with the seven validator tests from `AndroidOnnxRuntimeProviderTest.kt:215-307` (URL userinfo rejected, plain ref allowed, speech required, duplicate voice ids, empty speech structure yields `/speech/sampleRate`, `/speech/graphs`, `/speech/voices`, a malformed locale yields `/speech/voices/0/locales/0`, well-formed package yields no issues) calling the Core function. Remove those tests and helpers from the ONNX test file.

- [ ] **Step 2: Run it to verify it fails**

Run: `cd android && ./gradlew :inderun-core:testDebugUnitTest --tests "app.independo.inderun.core.ModelPackageValidationTest"`
Expected: FAIL to compile — `Unresolved reference: getModelPackageValidationIssues`.

- [ ] **Step 3: Move the Kotlin validator**

`git mv` the file into `inderun-core`, change its package line, update the ONNX provider's import. The ONNX module already has `api(project(":inderun-core"))`.

- [ ] **Step 4: Run the Kotlin tests**

Run: `cd android && ./gradlew spotlessApply && ./gradlew :inderun-core:testDebugUnitTest --tests "app.independo.inderun.core.ModelPackageValidationTest" && ./gradlew :inderun-onnx-providers:testDebugUnitTest`
Expected: PASS, 7 tests in the new class; the ONNX suite still passes without the moved tests.

- [ ] **Step 5: Move the Swift validator**

`git mv` the file into `IndeRunCore`; make the struct's initializer `public`; the ONNX provider compiles unchanged.

- [ ] **Step 6: Run the Swift tests and lint**

Run: `swift test --filter "IndeRunTests.testModelPackage|testOnnx" && (cd ios/IndeRun && swiftlint lint --strict)`
Expected: PASS; 0 lint violations. (If the filter matches nothing, run `swift test --filter IndeRunTests`.)

- [ ] **Step 7: Fix the stale ONNX doc line and commit**

```bash
git add -A ios/IndeRun/Sources android/inderun-core android/inderun-onnx-providers docs/architecture/onnx-runtime-provider-family.md
git commit -m "refactor(core): move the model package validator into Core on Swift and Kotlin"
```

---

### Task 2: Shared fixtures — frontend vectors and the lifecycle catalog

**Files:**
- Create: `contracts/fixtures/speech/neural-frontend.json`
- Create: `contracts/fixtures/speech/neural-speech-lifecycle.json`
- Create: `packages/contracts/src/neural-speech-fixtures.test.ts` (shape tests for both files)
- Modify: `docs/speech-conformance.md:20-34` (two rows; the Kotlin-suites sentence names `android/inderun-neural-speech/src/test/`)

**Interfaces:**
- Produces `neural-frontend.json`:
  ```json
  {
    "$comment": "Text frontend vectors shared by the three neural speech providers. 'sentences' is the sentence rule's output for 'text'; 'tokens' is the grapheme tokenizer's output per sentence over 'vocab' (lowercased NFC code points; code points absent from the vocab are dropped). Pipeline-specific normalizers (numbers, abbreviations) are not covered here; 'z.B. Hallo' splits after 'B.' by design.",
    "vocab": { " ": 1, "a": 2, "b": 3, "c": 4, "d": 5, "e": 6, "f": 7, "g": 8, "h": 9, "i": 10, "j": 11, "k": 12, "l": 13, "m": 14, "n": 15, "o": 16, "p": 17, "q": 18, "r": 19, "s": 20, "t": 21, "u": 22, "v": 23, "w": 24, "x": 25, "y": 26, "z": 27, "ä": 28, "ö": 29, "ü": 30, "ß": 31, "é": 32, ".": 33, ",": 34, "!": 35, "?": 36, "'": 37, "-": 38, "0": 39, "1": 40, "2": 41, "3": 42, "4": 43, "5": 44, "6": 45, "7": 46, "8": 47, "9": 48 },
    "cases": [ { "id": "...", "text": "...", "sentences": ["..."], "tokens": [[...]] } ]
  }
  ```
  Cases (ids and texts; sentences and tokens follow from the rule — the implementer computes the token arrays by hand from the vocab and the TS test in Task 3 proves them):
  | id | text | sentences |
  | --- | --- | --- |
  | `two_sentences` | `Hallo Welt. Wie geht es dir?` | `["Hallo Welt.", "Wie geht es dir?"]` |
  | `no_terminator` | `Guten Morgen` | `["Guten Morgen"]` |
  | `whitespace_collapsed` | `  Hallo   Welt .  ` | `["Hallo Welt ."]` |
  | `newline_splits` | `Erste Zeile\nZweite Zeile` | `["Erste Zeile", "Zweite Zeile"]` |
  | `terminator_run` | `Wirklich?! Ja... Nein!` | `["Wirklich?!", "Ja...", "Nein!"]` |
  | `abbreviation_splits` | `z.B. Hallo` | `["z.B.", "Hallo"]` |
  | `umlauts_and_sharp_s` | `Größe über Straße.` | `["Größe über Straße."]` |
  | `unknown_code_points_dropped` | `Hallo 🙂 Welt!` | `["Hallo 🙂 Welt!"]` (tokens omit the emoji; the two spaces around it stay two spaces) |
  | `nfc_composed` | `étude` (decomposed) | `["étude"]` (tokens use `é` = 32) |
  | `empty_text` | `` | `[]` |
  | `only_whitespace` | ` \n ` | `[]` |
  | `digits_kept` | `Um 7 Uhr 30.` | `["Um 7 Uhr 30."]` |
- Produces `neural-speech-lifecycle.json`, same top-level shape as `host/audio-output-lifecycle.json` (`$comment`, `$expectKeys`, `cases[]` with `id`, `description`, `setup`, `expect`). `$comment`: scenario catalog for the neural speech provider; every SDK runs it through its engine (`IndeRun` + `ProviderRegistry`) with the fixture runtime and the fixture audio output of ADR 021; the package under test is the catalog's `package` (24000 Hz, pipeline `fixture`, voices `v_de` (`de-DE`, `de-AT`) and `v_en` (`en-US`)); text is `Hallo Welt. Wie geht es dir?` (28 characters → 1400 ms with `msPerCharacter: 50`) unless the setup says otherwise; the profile is `[neural, fallback]` where `fallback` is a scripted fake speech provider that records whether it was asked; every wait is bounded by `timeoutMs`.
  The catalog carries `package` (the `ModelPackage` JSON used by every SDK) and `format` (`{ "sampleRate": 24000, "channels": 1, "encoding": "pcm_s16le" }`).
  `$expectKeys`:
  ```json
  "outcome": "The run's terminal outcome: 'completed', 'cancelled' or 'error'.",
  "commitCount": "Whether the neural provider committed: 1 when the engine's provenance reports its attempt 'committed', else 0.",
  "commitAt": "For a direct provider call with a spying commit(): 'sessionsOpened' and 'firstSessionWrites' at the moment commit() was called.",
  "sessions": "How many audio output sessions the provider opened, and for the first: 'writes' (at least), 'stopped', 'discardedFrames' ('some' or 'none'), 'playedFrames' ('all' = every written frame played).",
  "fallbackAsked": "Whether the second provider in the profile was asked to run.",
  "error": "For 'error' outcomes and thrown refusals: 'errorClass' and 'code' (details.code).",
  "timing": "'durationMsEquals' ('synthesized' = frames / sampleRate * 1000), 'firstChunkDefined', 'firstAudioDefined', 'firstChunkAtMostFirstAudio'.",
  "artifact": "'mediaType', 'byteLengthEquals' ('wav' = 44 + 2 * frames), 'header' (sampleRate, channels, bitsPerSample, dataBytes = 2 * frames).",
  "runtime": "'synthesizeCalls' (sentences handed to the runtime, exact), 'synthesizeCallsAtMost', 'prepareCalls'.",
  "order": "For two utterances on one provider: 'secondOpensAfterFirstStops'.",
  "timeoutMs": "Bounds every wait in the case."
  ```
  Cases:
  | id | setup | expect |
  | --- | --- | --- |
  | `playback_commits_before_first_write` | direct provider `run` in playback with a spying `commit()` that records how many fixture sessions are open and how many writes the first has at the moment it is called | `commitAt: { sessionsOpened: 1, firstSessionWrites: 0 }`, `sessions: { count: 1, first: { writes: 1, stopped: true, discardedFrames: "none", playedFrames: "all" } }`, `runtime: { synthesizeCalls: 2 }` |
  | `playback_reports_timing` | same as above | `timing: { durationMsEquals: "synthesized", firstChunkDefined: true, firstAudioDefined: true, firstChunkAtMostFirstAudio: true }` |
  | `cancel_while_waiting_plays_nothing` | start `speak` A (text of 60 characters); start `speak` B; cancel B while A is still writing; await both | B: `outcome: cancelled`, `commitCount` for B `0`; `sessions: { count: 1 }` (only A opened one); A: `outcome: completed` |
  | `cancel_mid_stream_stops_audio_once` | `speak` a text of 200 characters with the fixture runtime's `delayMs: 5`; cancel after the first write | `outcome: cancelled`, `commitCount: 1`, `sessions: { count: 1, first: { stopped: true, discardedFrames: "some" } }`, `runtime: { synthesizeCallsAtMost: 2 }` (iteration ended) ; exactly one terminal event |
  | `missing_audio_output_refuses_before_commit` | host without `audioOutput`; `speak` | `outcome: completed` (by the fallback), `fallbackAsked: true`, neural `commitCount: 0`, `sessions: { count: 0 }`, provenance's first attempt rejected with `CapabilityMismatch` / `audio_output_unavailable` |
  | `unknown_voice_refused_before_commit` | direct provider call with a bound voice `{ id: "ghost" }` | `error: { errorClass: "CapabilityMismatch", code: "voice_not_available" }`, `commitCount: 0`, `sessions: { count: 0 }` |
  | `artifact_is_wav_of_the_samples` | `generateSpeech` the text | `outcome: completed`, `commitCount: 1`, `sessions: { count: 0 }`, `artifact: { mediaType: "audio/wav", byteLengthEquals: "wav", header: { sampleRate: 24000, channels: 1, bitsPerSample: 16, dataBytes: "2*frames" } }`, `timing` absent |
  | `artifact_over_cap_fails_before_commit` | single-provider profile; `generateSpeech` with `msPerCharacter: 50000` and a 7-character text (350 s → 16.8 MB) | `outcome: error`, `error: { errorClass: "Unavailable", code: "artifact_too_large" }`, `commitCount: 0`, `sessions: { count: 0 }`, `runtime: { synthesizeCalls: 1 }` (stopped at the cap, not after) |
  | `interruption_after_commit_fails_without_fallback` | `speak`; after the first write the fixture session is interrupted with `audio_output_interrupted` | `outcome: error`, `error: { errorClass: "Unavailable", code: "audio_output_interrupted" }`, `commitCount: 1`, `fallbackAsked: false` |
  | `utterances_play_one_at_a_time` | two `speak` calls started back to back on one provider | both `completed`, `sessions: { count: 2 }`, `order: { secondOpensAfterFirstStops: true }` |
  | `capabilities_never_load` | `checkCapabilities` twice, then `prepare` | `runtime: { prepareCalls: 1 }` after prepare and `0` before; readiness `cold` before, absent after |
  `timeoutMs` is 5000 on every case. Engine-driven cases register the neural provider and, where the setup says so, the fallback, in a profile named `auto` (TS `new IndeRun(registry, host, { modelProfiles: { auto: [neuralId, "fallback"] } })` with `speak(api, { text, locale, model: "auto" })`; Swift `IndeRun(registry:hostServices:modelProfiles: try ModelProfiles(["auto": [...]]))` with `SpeakOptions(model: "auto")`; Kotlin `IndeRun(registry, hostServices, modelProfiles = ModelProfiles(mapOf("auto" to listOf(...))))` with `model = "auto"`); `fallback` is a scripted fake speech provider that commits and completes a playback (`createFakeStreamProvider("fallback", { task: "text_to_speech", script: [{ commit: true }, { event: <playback result> }] })` and its Swift/Kotlin counterparts in `StreamTestFakes.swift` / `StreamConformanceFakes.kt`), and records whether it was asked (`callCount`).
- Consumes: nothing; the TS shape test checks ids unique, every case has `setup`, `expect` keys ⊆ `$expectKeys`, `package` validates with `getModelPackageValidationIssues` (no issues) and `tokens` arrays have one entry per sentence.

- [ ] **Step 1: Write the failing shape test**

`packages/contracts/src/neural-speech-fixtures.test.ts`: loads both files with `readFileSync` (pattern `utterance-corpus.test.ts:12`), asserts the invariants above, and for the frontend fixture additionally that every token id exists in `vocab` values.

- [ ] **Step 2: Run it to verify it fails**

Run: `pnpm --filter @independo/inderun-contracts test -- neural-speech-fixtures`
Expected: FAIL — `ENOENT` on the fixture files.

- [ ] **Step 3: Write both fixtures**

Hand-formatted 2-space JSON. Compute the token arrays from the vocab by hand (lowercase first: `Hallo Welt.` → `[9,2,13,13,16,1,24,6,13,21,33]`).

- [ ] **Step 4: Run the test**

Run: `pnpm --filter @independo/inderun-contracts test -- neural-speech-fixtures`
Expected: PASS.

- [ ] **Step 5: Add the conformance rows and commit**

`docs/speech-conformance.md`: two rows after the `host/audio-output-lifecycle.json` row — `speech/neural-frontend.json` ("Text → sentences → grapheme token ids over an embedded vocab", loaded by `packages/inderun-web/src/providers/neural-speech/frontend.test.ts`, `NeuralSpeechFrontendTests.swift`, `SpeechTextFrontendTest.kt`) and `speech/neural-speech-lifecycle.json` ("Scenario catalog: commit placement, cancel, missing audio output, artifact cap, timing", loaded by `packages/inderun-web/src/providers/neural-speech/lifecycle.conformance.test.ts`, `NeuralSpeechLifecycleConformanceTests.swift`, `NeuralSpeechLifecycleConformanceTest.kt`). Extend the Kotlin-suites sentence with `android/inderun-neural-speech/src/test/`.

```bash
git add contracts/fixtures/speech packages/contracts/src/neural-speech-fixtures.test.ts docs/speech-conformance.md
git commit -m "test(contracts): add the neural speech frontend and lifecycle fixtures"
```

---

### Task 3: TypeScript seams, frontend, WAV and the fixture runtime

**Files:**
- Create: `packages/inderun-web/src/providers/neural-speech/runtime.ts`
- Create: `packages/inderun-web/src/providers/neural-speech/frontend.ts` + `frontend.test.ts`
- Create: `packages/inderun-web/src/providers/neural-speech/wav.ts` + `wav.test.ts`
- Create: `packages/inderun-web/src/providers/neural-speech/fixture-runtime.ts` + `fixture-runtime.test.ts`

**Interfaces:**
- Produces (`runtime.ts`):
  ```ts
  export interface PcmChunk { samples: Int16Array; sampleRate: number; isLast: boolean }
  export interface SpeechTensor { shape: number[]; data: Float32Array | BigInt64Array }
  /** Runs one graph of a package; implemented by the ORT and Core AI executors (PR 4, PR 5). */
  export interface SpeechGraphExecutor {
    load(graphs: Record<string, string>): Promise<void>;
    run(role: string, inputs: Record<string, SpeechTensor>): Promise<Record<string, SpeechTensor>>;
    close?(): Promise<void>;
  }
  export interface NeuralSpeechAvailability { available: boolean; reason?: string }
  export interface NeuralSpeechSynthesisInput { modelPackage: ModelPackage; text: string; locale: string; voiceId: string; signal?: AbortSignal }
  export interface NeuralSpeechRuntime {
    availability(pkg: ModelPackage): Promise<NeuralSpeechAvailability>;   // also where `limits.memBytes` and an unknown `pipeline` are refused, with the reason verbatim
    prepare(pkg: ModelPackage): Promise<NeuralSpeechAvailability>;
    synthesize(input: NeuralSpeechSynthesisInput): AsyncIterable<PcmChunk>;   // one sentence per call
  }
  export type NeuralSpeechRuntimeErrorKind = "capability" | "unavailable" | "timeout" | "internal";
  export class NeuralSpeechRuntimeError extends Error { constructor(readonly kind: NeuralSpeechRuntimeErrorKind, message: string, readonly originalError?: unknown) }
  ```
- Produces (`frontend.ts`): `export function splitSentences(text: string): string[]` and `export class GraphemeTokenizer { constructor(vocab: Record<string, number>); encode(sentence: string): number[] }` implementing the Global Constraints rule.
- Produces (`wav.ts`): `export function encodeWav(samples: Int16Array, sampleRate: number): Uint8Array` (44-byte canonical header, mono, 16-bit, little-endian) and `export const WAV_HEADER_BYTES = 44`.
- Produces (`fixture-runtime.ts`):
  ```ts
  export interface FixtureNeuralSpeechRuntimeOptions {
    availability?: NeuralSpeechAvailability;   // default { available: true }
    prepareResult?: NeuralSpeechAvailability;  // default { available: true }
    msPerCharacter?: number;                   // default 50
    chunkMs?: number;                          // default 100
    delayMs?: number;                          // default 0, wall delay before each chunk
    failAfterChunks?: number;                  // throw NeuralSpeechRuntimeError("internal") after N chunks
  }
  export interface FixtureNeuralSpeechRuntime extends NeuralSpeechRuntime {
    readonly synthesized: { text: string; locale: string; voiceId: string }[];
    readonly prepareCalls: number;
    readonly availabilityCalls: number;
  }
  export function createFixtureNeuralSpeechRuntime(options?: FixtureNeuralSpeechRuntimeOptions): FixtureNeuralSpeechRuntime;
  ```
  Samples: 440 Hz sine at −14 dBFS (`Math.round(0.2 * 32767 * Math.sin(2π·440·n/sampleRate))`), phase continuous across chunks of one sentence; `sampleRate` from `pkg.speech.sampleRate`; the last chunk is partial when the duration is not a multiple of `chunkMs`; `signal.aborted` checked before each chunk — an aborted signal ends the iteration without throwing.
- Consumes: `ModelPackage` from `@independo/inderun-contracts`; the fixture `contracts/fixtures/speech/neural-frontend.json` from Task 2.

- [ ] **Step 1: Write the failing frontend test**

`frontend.test.ts` loads the fixture (path `../../../../../contracts/fixtures/speech/neural-frontend.json` from `src/providers/neural-speech/`) and for every case asserts `splitSentences(text)` equals `sentences` and `tokenizer.encode(sentence)` equals `tokens[i]`; a guard asserts the case ids are unique and non-empty.

- [ ] **Step 2: Run it to verify it fails**

Run: `pnpm --filter @independo/inderun-web exec vitest run src/providers/neural-speech/frontend.test.ts`
Expected: FAIL — `Cannot find module './frontend.js'`.

- [ ] **Step 3: Implement `frontend.ts`**

Sentence splitting with one regular expression over NFC text (`/[.!?…]+(?=\s|$)/u` as the boundary, plus `\n`), then trim/collapse/drop.

- [ ] **Step 4: Run it, then write the failing WAV and fixture-runtime tests**

`wav.test.ts`: `encodeWav(new Int16Array([0, 1, -1]), 24000)` has length 50, bytes 0-3 `RIFF`, 4-7 = 42 LE, 8-11 `WAVE`, 12-15 `fmt `, 16-19 = 16, 20-21 = 1, 22-23 = 1, 24-27 = 24000, 28-31 = 48000, 32-33 = 2, 34-35 = 16, 36-39 `data`, 40-43 = 6, then `00 00 01 00 ff ff`.
`fixture-runtime.test.ts`: a 28-character sentence at 24000 Hz yields 14 chunks (13 × 2400 frames + 1 × 2400; total 33600 frames) with `isLast` only on the last; phase continuity (sample 2400 of chunk 1 equals the sine at n = 2400); `signal` aborted after two chunks ends the iteration at two; `failAfterChunks: 1` throws `NeuralSpeechRuntimeError` with kind `internal`; `synthesized` records the call; `prepareCalls` increments.

- [ ] **Step 5: Run them to verify they fail, implement `runtime.ts`, `wav.ts`, `fixture-runtime.ts`, run them to verify they pass**

Run: `pnpm --filter @independo/inderun-web exec vitest run src/providers/neural-speech`
Expected: PASS.

- [ ] **Step 6: Format, lint, commit**

```bash
pnpm format:js && pnpm lint
git add packages/inderun-web/src/providers/neural-speech
git commit -m "feat(web): add the neural speech runtime seams, text frontend and fixture runtime"
```

---

### Task 4: TypeScript provider, subpath, `createIndeRunWeb`, lifecycle catalog

**Files:**
- Create: `packages/inderun-web/src/providers/neural-speech/provider.ts` + `provider.test.ts`
- Create: `packages/inderun-web/src/providers/neural-speech/lifecycle.conformance.test.ts`
- Create: `packages/inderun-web/src/neural-speech.ts` (entry; mirror `src/system-speech.ts` and `src/onnx.ts`)
- Modify: `packages/inderun-web/package.json` (`exports["./neural-speech"]` with `types`/`default` like the others)
- Modify: `packages/inderun-web/src/web-sdk.ts:26-68` (`neuralSpeech?: (NeuralSpeechProviderOptions & ProviderRegistrationOptions)[]`), `:94-98` (guard and message list `neuralSpeech`), `:113-123` (register each)
- Modify: the existing `createIndeRunWeb` test file (find it with `grep -rl createIndeRunWeb packages/inderun-web/src | grep test`; create `packages/inderun-web/src/web-sdk.test.ts` if none): `neuralSpeech` with two packages registers both composed ids; `createIndeRunWeb({})` still throws the guard message, now naming `neuralSpeech`
- Modify: `packages/inderun-web/src/test/stream-fakes.ts` only if the fallback fake needs a `text_to_speech` provider that records being asked (`createFakeStreamProvider` with `task: "text_to_speech"` already records `callCount`; reuse it)

**Interfaces:**
- Produces (`provider.ts`):
  ```ts
  export const DEFAULT_NEURAL_SPEECH_WEB_PROVIDER_ID = "local.onnx.speech.web";
  export const SUPPORTED_WEB_NEURAL_SPEECH_MODEL_SOURCE_TYPES: readonly ModelSourceType[] = ["registry", "bundled", "programmatic", "app_managed"];
  export const MAX_ARTIFACT_BYTES = 16 * 1024 * 1024;
  export interface NeuralSpeechProviderOptions { id?: string; modelPackage: ModelPackage; runtime: NeuralSpeechRuntime; timeoutMs?: number }
  export class NeuralSpeechWebProvider implements StreamingProviderAdapter, PreparableProviderAdapter {
    constructor(options: NeuralSpeechProviderOptions);
    readonly id: string;                       // options.id ?? `${DEFAULT}:${modelPackage.id}`
    describe(): ProviderDescriptor;
    capabilities(host: HostServices): Promise<ProviderDynamicCapabilities>;
    prepare(context: ProviderPrepareContext): AsyncIterable<{ fractionCompleted?: number }>;
    run(request: TaskRequest, context: RunContext): Promise<TaskResult>;
    stream(request: TaskRequest, context: ProviderStreamContext): AsyncIterable<ProviderStreamEvent>;
  }
  ```
  `run()` handles `playback` (no signal) and `artifact`; `stream()` handles `playback` with `context.signal` and yields only `{ kind: "result", output, finishReason: "stop" }` (quiet when cancelled). `timeoutMs` bounds each `synthesize` call like the ONNX provider bounds `generate` (`createTimeout` on expiry; after commit it is a thrown error, before commit a refusal). Error mapping from `NeuralSpeechRuntimeError` as `mapRuntimeError` in `providers/onnx/provider.ts:290-316`.
  Playback algorithm (what the signatures leave open): `receivedAt = Date.now()` first; validate request; `inTurn` (copy of `providers/system-speech/provider.ts:239-258` + `untilTurnOrAbort :289`); inside: `audioOutput` presence → `voice` check (bound `context.voice?.id` must be a package voice id; when no voice is bound use `speech.voice?.id` if given else the first voice whose `locales` matches `speech.locale` by language, else the first voice) → `ensureLoaded(runId)` (runtime.prepare, remembered failure) → `sentences = splitSentences(speech.text)` (zero sentences → `CapabilityMismatch` "nothing to say") → `session = await audioOutput.open(format, signal)` → `openedAt = Date.now()` → for each sentence `for await (chunk of runtime.synthesize({...}))`: on the first chunk overall set `firstChunkAt`, then `if (signal?.aborted || !context.commit()) { session.stop(); return undefined }`; on every chunk check `chunk.sampleRate === format.sampleRate`, `frames += chunk.samples.length`, `await session.write(chunk.samples)`, then `if (signal?.aborted) { session.stop(); return undefined }` → after all sentences `await session.drain()`, `firstAudio = session.firstAudioMs()`, `session.stop()` → timing → output `{ type: "playback", playback: { timing }, speech: { locale: voice.locales[0] matching or speech.locale, voice: { id, name } } }`. A thrown error after `open()` always `session.stop()`s in `finally`.
  Artifact algorithm: same validation minus `audioOutput` and `open`; loop sentences collecting chunks into an array, tracking `bytes = 44 + 2 × frames`; when the next chunk would exceed `MAX_ARTIFACT_BYTES` stop iterating (abort the runtime through an internal `AbortController`) and throw `createUnavailable("The synthesized audio exceeds the artifact size limit.", { details: { code: "artifact_too_large" } })`; else concatenate, `encodeWav`, `artifacts.create({ mediaType: "audio/wav", durationMs })`, `write`, `finish()`; `abort()` on any throw; output `{ type: "artifact", artifact, speech }`.
- Produces (`neural-speech.ts` entry): exports the provider, its ids/constants/options, the runtime seam (`NeuralSpeechRuntime`, `NeuralSpeechAvailability`, `NeuralSpeechSynthesisInput`, `PcmChunk`, `SpeechTensor`, `SpeechGraphExecutor`, `NeuralSpeechRuntimeError`, `NeuralSpeechRuntimeErrorKind`), `createFixtureNeuralSpeechRuntime` + its option/type, `splitSentences`, `GraphemeTokenizer`, `encodeWav`, and `type { ModelPackage, ModelSourceType }`.
- Consumes: Task 3 modules; `createFixtureAudioOutput` (`src/test/audio-output-fixture.ts`), `createFakeStreamProvider` (`src/test/stream-fakes.ts`), `IndeRun`, `ProviderRegistry`, `speak`, `generateSpeech`, `checkCapabilities`/`prepare` from `src/index.ts`.

- [ ] **Step 1: Write the failing provider unit tests**

`provider.test.ts` (fixture runtime + a package built inline as in the catalog):
- `describes a hard-cancel in-process speech provider` — descriptor equals the Global Constraints shape, `locales: ["de-DE", "de-AT", "en-US"]`, id `local.onnx.speech.web:fixture-tts`.
- `capability check never loads the model and reports it cold` — `prepareCalls` 0 after two `capabilities()` calls; `taskCapabilities[0].readiness === "cold"`; three voices with `locale`, `locales`, `networkRequired: false`.
- `refuses a malformed package, a package without speech, an unsupported source type, an unsupported platform, and what the runtime refuses` — five packages, five reasons (prefixes `model package malformed:`, `unsupported task:`, `model source unavailable:`, `platform unsupported:`, and the runtime's reason verbatim `unsupported pipeline: kokoro`).
- `remembers a load failure` — `prepareResult: { available: false, reason: "graph missing" }`; `prepare()` throws `CapabilityMismatch`; `capabilities()` then reports `available: false, reason: "graph missing"`.
- `reports readiness absent once prepared`.
- `refuses an inline delivery and a non-speech request before commit`.
- `bounds a slow runtime with timeoutMs` — `delayMs: 50`, `timeoutMs: 20` → `Timeout`, `commitCount` 0 when it expired before the first chunk.

- [ ] **Step 2: Run them to verify they fail**

Run: `pnpm --filter @independo/inderun-web exec vitest run src/providers/neural-speech/provider.test.ts`
Expected: FAIL — `Cannot find module './provider.js'`.

- [ ] **Step 3: Implement `provider.ts`, the entry and the `package.json` export; run the unit tests**

Run: `pnpm --filter @independo/inderun-web exec vitest run src/providers/neural-speech/provider.test.ts`
Expected: PASS.

- [ ] **Step 4: Write the failing lifecycle catalog test**

`lifecycle.conformance.test.ts`: load the catalog (path as in `src/core/audio-output.conformance.test.ts:28-37` with `speech/neural-speech-lifecycle.json`); per case build `createFixtureAudioOutput()`, `createFixtureNeuralSpeechRuntime(opts)`, the provider from `catalog.package`, the fallback fake where the setup names it, a `ProviderRegistry`, host services `{ ...createWallClockHostServices(), audioOutput }` (without `audioOutput` for the missing case) and `new IndeRun(registry, host, { modelProfiles: { auto: [...] } })` (pattern `src/core/engine.test.ts:900-905`); drive it through `speak`/`generateSpeech` from `src/index.ts` with `model: "auto"`, or call the provider's `run` directly with a `RunContext` whose `commit` spies (the two direct cases); one handler per case id producing an `Observation` (`outcome` from the facade result or rejection, `commitCount` from the engine provenance `attempts[].committed` of the neural attempt, `commitAt` from the spy, `sessions` from the fixture, `fallbackAsked` from the fake's `callCount`, `error` from the rejection, `timing`/`artifact` from the result (artifact bytes read back through `readArtifact`), `runtime` from the fixture runtime, `order` from the fixture sessions' open order against the first session's `stopped`); a guard `implements every case in the shared catalog, and no others`; `assertCase(expect, observation)` mirroring the `$expectKeys`.

- [ ] **Step 5: Run it to verify it fails, fix the provider until it passes**

Run: `pnpm --filter @independo/inderun-web exec vitest run src/providers/neural-speech`
Expected: PASS for the guard and all 11 cases.

- [ ] **Step 6: Wire `createIndeRunWeb`, run the package suite, packaging check**

Run: `pnpm --filter @independo/inderun-web test && pnpm build && pnpm verify:packaging && pnpm format:js && pnpm lint`
Expected: PASS; publint/attw list the new subpath without findings.

- [ ] **Step 7: Commit**

```bash
git add packages/inderun-web/src/providers/neural-speech packages/inderun-web/src/neural-speech.ts packages/inderun-web/src/web-sdk.ts packages/inderun-web/src/web-sdk.test.ts packages/inderun-web/package.json
git commit -m "feat(web): add the neural speech provider over the audio output host service"
```

---

### Task 5: Swift module `IndeRunNeuralSpeech`, `SpeechWAV` in Core, catalogs

**Files:**
- Modify: `Package.swift` (product + target `IndeRunNeuralSpeech` with `dependencies: ["IndeRunCore", "IndeRunContracts"]`, `path: "ios/IndeRun/Sources/IndeRunNeuralSpeech"`; add it to `IndeRunTests` dependencies at `:106-117`; the comment at `:91-95` says "all six modules" → "all seven")
- Create: `ios/IndeRun/Sources/IndeRunCore/SpeechWAV.swift` (`public enum SpeechWAV { public static let headerBytes = 44; public static func encode(samples: Data, sampleRate: Int) -> Data }`, moved from `ios/IndeRun/Sources/IndeRunAppleProviders/AppleSpeechRuntime.swift:64-89`; the Apple provider's call at `AppleSystemSpeechProvider.swift:325` becomes `SpeechWAV.encode(samples: rendered.samples, sampleRate: rendered.sampleRate)`)
- Create under `ios/IndeRun/Sources/IndeRunNeuralSpeech/`: `Exports.swift` (`@_exported import IndeRunCore`, same 10-line header as the other targets), `PcmChunk.swift`, `SpeechGraphExecutor.swift`, `NeuralSpeechRuntime.swift`, `SpeechTextFrontend.swift`, `FixtureNeuralSpeechRuntime.swift`, `NeuralSpeechProvider.swift`
- Create under `ios/IndeRun/Tests/IndeRunTests/`: `NeuralSpeechFrontendTests.swift`, `NeuralSpeechProviderTests.swift`, `NeuralSpeechLifecycleConformanceTests.swift`, `SpeechWAVTests.swift`
- Modify: `ios/IndeRun/README.md:5-12` (module bullet), `:24-29` (products paragraph), new `### Neural speech` subsection after `### Custom local ONNX models` (`:97`)

**Interfaces:**
- Produces:
  ```swift
  public struct PcmChunk: Sendable, Equatable { public let samples: [Int16]; public let sampleRate: Int; public let isLast: Bool; public init(samples:sampleRate:isLast:) }
  public enum SpeechTensorData: Sendable, Equatable { case f32([Float]); case i64([Int64]) }
  public struct SpeechTensor: Sendable, Equatable { public let shape: [Int]; public let data: SpeechTensorData; public init(shape:data:) }
  public protocol SpeechGraphExecutor: Sendable {
      func load(graphs: [String: String]) async throws
      func run(role: String, inputs: [String: SpeechTensor]) async throws -> [String: SpeechTensor]
      func close() async
  }
  public struct NeuralSpeechAvailability: Sendable, Equatable { public let available: Bool; public let reason: String?; public init(available:reason:) }
  public struct NeuralSpeechSynthesisInput: Sendable { public let modelPackage: ModelPackage; public let text: String; public let locale: String; public let voiceId: String; public init(...) }
  public protocol NeuralSpeechRuntime: Sendable {
      func availability(_ modelPackage: ModelPackage) async -> NeuralSpeechAvailability
      func prepare(_ modelPackage: ModelPackage) async -> NeuralSpeechAvailability
      func synthesize(_ input: NeuralSpeechSynthesisInput) -> AsyncThrowingStream<PcmChunk, Error>   // honours Task cancellation of the consumer
  }
  public enum NeuralSpeechRuntimeErrorKind: Sendable { case capability, unavailable, timeout, internalFailure }
  public struct NeuralSpeechRuntimeError: Error, Sendable { public let kind: NeuralSpeechRuntimeErrorKind; public let message: String; public let originalErrorDescription: String?; public init(...) }
  public enum SpeechTextFrontend { public static func splitSentences(_ text: String) -> [String] }
  public struct GraphemeTokenizer: Sendable { public init(vocab: [String: Int]); public func encode(_ sentence: String) -> [Int] }
  public struct FixtureNeuralSpeechRuntimeOptions: Sendable { availability, prepareResult, msPerCharacter = 50, chunkMs = 100, delayMs = 0, failAfterChunks: Int? }
  public final class FixtureNeuralSpeechRuntime: NeuralSpeechRuntime, @unchecked Sendable { public init(options: = .init()); public var synthesized: [(text: String, locale: String, voiceId: String)] { get }; public var prepareCalls: Int { get }; public var availabilityCalls: Int { get } }   // NSLock-guarded, as FixtureAudioOutputService
  public struct NeuralSpeechProviderOptions: Sendable { public let id: String?; public let modelPackage: ModelPackage; public let runtime: any NeuralSpeechRuntime; public let timeout: Duration?; public init(id: String? = nil, modelPackage:, runtime:, timeout: Duration? = nil) }
  public final class NeuralSpeechProvider: StreamingProviderAdapter, PreparableProviderAdapter, Sendable {
      public static let defaultId = "local.onnx.speech.apple"
      public static let supportedModelSourceTypes: [SourceType] = [.bundled, .programmatic, .appManaged, .filesystem]
      public static let maxArtifactBytes = 16 * 1024 * 1024
      public init(options: NeuralSpeechProviderOptions)
      public var id: String { get }   // options.id ?? "\(Self.defaultId):\(modelPackage.id)"
      public func describe() -> ProviderDescriptor
      public func capabilities(host: HostServices) async -> ProviderDynamicCapabilities
      public func prepare(context: ProviderPrepareContext) -> AsyncThrowingStream<PreparationProgress, Error>
      public func run(request: TaskRequest, context: RunContext) async throws -> TaskResult
      public func stream(request: TaskRequest, context: ProviderStreamContext) -> AsyncThrowingStream<ProviderStreamEvent, Error>
  }
  ```
  `stream` wraps the work in a `Task` as `AppleSystemSpeechProvider.swift:210-239` does (`context.cancellation.onCancel { task.cancel() }`, `onTermination` cancels, `CancellationError` finishes quietly, other errors finish throwing unless cancelled). Cancellation inside the playback path is `Task` cancellation: check `Task.isCancelled` before commit and after every write; on cancellation `session.stop()` then `throw CancellationError()`. The turn helper is a private copy of `SpeechTurns` (`AppleSystemSpeechProvider.swift:7-43`). `firstChunkMs`/`firstAudioMs`/`durationMs` as in the Global Constraints, with `Date()`.
- Consumes: Task 1's Core validator, `FixtureAudioOutputService` (`FixtureAudioOutput.swift`), `MockStreamProvider`/`makeSpeechRequest` (`StreamTestFakes.swift`), `HostServices(connectivity:clock:audioOutput:)`, `IndeRun(registry:hostServices:)`, the catalog from Task 2 via a `repositoryRoot()` copy (`AudioOutputLifecycleConformanceTests.swift:278`).

- [ ] **Step 1: Write the failing `SpeechWAV` and frontend tests**

`SpeechWAVTests.swift`: the Task 3 WAV byte vector against `SpeechWAV.encode(samples:sampleRate:)`. `NeuralSpeechFrontendTests.swift`: loads `neural-frontend.json` and checks every case; a guard for unique ids.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift build --build-tests`
Expected: compile errors — `cannot find 'SpeechTextFrontend' in scope`, and `SpeechWAV.encode(samples:sampleRate:)` has no such member.

- [ ] **Step 3: Add the target, move `SpeechWAV`, implement the frontend; run the two suites**

Run: `swift test --filter "SpeechWAVTests|NeuralSpeechFrontendTests|AppleSystemSpeechArtifactTests"`
Expected: PASS (the Apple artifact test still produces a valid WAV through the Core encoder).

- [ ] **Step 4: Write the failing provider and catalog tests**

`NeuralSpeechProviderTests.swift`: the seven unit tests of Task 4 Step 1 in Swift (`testNeuralSpeechCapabilityCheckNeverLoadsTheModelAndReportsItCold`, etc.). `NeuralSpeechLifecycleConformanceTests.swift`: `testImplementsEveryCaseInTheSharedCatalogAndNoOthers` plus one handler per case id driving `IndeRun` with the fixture runtime, `FixtureAudioOutputService` and a `MockStreamProvider` fallback, through `speak(_:)` / `generateSpeech(_:)` of the Swift facade (or `stream`/`run` on the engine, as `SpeechGenerationTests.swift` does); bounded waits via a `withThrowingTaskGroup` race as in the audio output suite.

- [ ] **Step 5: Run them to verify they fail, implement the seams, fixture runtime and provider, run until green**

Run: `swift test --filter "NeuralSpeech|SpeechWAV" && swift test --filter IndeRunTests && (cd ios/IndeRun && swiftlint lint --strict)`
Expected: PASS; both consumer smoke targets still build; 0 lint violations.

- [ ] **Step 6: README and commit**

```bash
git add Package.swift ios/IndeRun/Sources ios/IndeRun/Tests ios/IndeRun/README.md
git commit -m "feat(apple): add the IndeRunNeuralSpeech provider module"
```

---

### Task 6: Kotlin module `inderun-neural-speech`, catalogs, publishing baseline

**Files:**
- Modify: `android/settings.gradle.kts:19-27` (`include(":inderun-neural-speech")` after `:inderun-mlkit-providers`)
- Create: `android/inderun-neural-speech/build.gradle.kts` (copy of `android/inderun-system-speech-providers/build.gradle.kts` with `namespace = "app.independo.inderun.providers.neuralspeech"`; test deps add `org.robolectric:robolectric:4.17` and `androidx.test:core:1.7.0` because the tests read JSON through `org.json`)
- Create under `android/inderun-neural-speech/src/main/kotlin/app/independo/inderun/providers/neuralspeech/`: `PcmChunk.kt`, `SpeechGraphExecutor.kt`, `NeuralSpeechRuntime.kt`, `SpeechTextFrontend.kt`, `SpeechWavEncoder.kt`, `FixtureNeuralSpeechRuntime.kt`, `NeuralSpeechProvider.kt`
- Create under `android/inderun-neural-speech/src/test/kotlin/app/independo/inderun/providers/neuralspeech/`: `SpeechTextFrontendTest.kt`, `SpeechWavEncoderTest.kt`, `FixtureNeuralSpeechRuntimeTest.kt`, `NeuralSpeechProviderTest.kt`
- Create: `android/inderun-kotlin/src/test/kotlin/app/independo/inderun/sdk/NeuralSpeechLifecycleConformanceTest.kt` (lives here because the engine and `FixtureAudioOutputService` live here; `android/inderun-kotlin/build.gradle.kts:66-68` gains `testImplementation(project(":inderun-neural-speech"))` next to the system speech line, same "opt-in" comment)
- Modify: `android/published-api-dependencies.txt` via `pnpm verify:android-api-deps --update` (new `inderun-neural-speech compile …` lines only)
- Modify: `android/README.md:5-19` (module bullet after `inderun-onnx-providers`), `docs/release.md:15` (artifact list: add `inderun-neural-speech`; also add the two already-published-but-unlisted modules `inderun-onnx-providers` and `inderun-system-speech-providers`)

**Interfaces:**
- Produces (package `app.independo.inderun.providers.neuralspeech`):
  ```kotlin
  data class PcmChunk(val samples: ShortArray, val sampleRate: Int, val isLast: Boolean)   // equals/hashCode over content
  sealed interface SpeechTensorData { data class F32(val values: FloatArray) : SpeechTensorData; data class I64(val values: LongArray) : SpeechTensorData }
  data class SpeechTensor(val shape: List<Int>, val data: SpeechTensorData)
  interface SpeechGraphExecutor { suspend fun load(graphs: Map<String, String>); suspend fun run(role: String, inputs: Map<String, SpeechTensor>): Map<String, SpeechTensor>; fun close() }
  data class NeuralSpeechAvailability(val available: Boolean, val reason: String? = null)
  data class NeuralSpeechSynthesisInput(val modelPackage: ModelPackage, val text: String, val locale: String, val voiceId: String)
  interface NeuralSpeechRuntime {
      suspend fun availability(modelPackage: ModelPackage): NeuralSpeechAvailability
      suspend fun prepare(modelPackage: ModelPackage): NeuralSpeechAvailability
      fun synthesize(input: NeuralSpeechSynthesisInput): Flow<PcmChunk>   // cooperative cancellation
  }
  enum class NeuralSpeechRuntimeErrorKind { Capability, Unavailable, Timeout, Internal }
  class NeuralSpeechRuntimeError(val kind: NeuralSpeechRuntimeErrorKind, message: String, cause: Throwable? = null) : Exception(message, cause)
  object SpeechTextFrontend { fun splitSentences(text: String): List<String> }
  class GraphemeTokenizer(vocab: Map<String, Int>) { fun encode(sentence: String): List<Int> }
  object SpeechWavEncoder { const val HEADER_BYTES = 44; fun encode(samples: ShortArray, sampleRate: Int): ByteArray }
  data class FixtureNeuralSpeechRuntimeOptions(availability = NeuralSpeechAvailability(true), prepareResult = NeuralSpeechAvailability(true), msPerCharacter: Int = 50, chunkMs: Int = 100, delayMs: Long = 0, failAfterChunks: Int? = null)
  class FixtureNeuralSpeechRuntime(options = FixtureNeuralSpeechRuntimeOptions()) : NeuralSpeechRuntime { val synthesized: List<NeuralSpeechSynthesisInput>; val prepareCalls: Int; val availabilityCalls: Int }
  class NeuralSpeechProvider(
      private val modelPackage: ModelPackage,
      private val runtime: NeuralSpeechRuntime,
      id: String? = null,
      private val timeoutMs: Long? = null,
  ) : StreamingProviderAdapter, PreparableProviderAdapter {
      val id: String   // id ?: "$DEFAULT_ID:${modelPackage.id}"
      companion object { const val DEFAULT_ID = "local.onnx.speech.android"; val supportedModelSourceTypes = listOf(Bundled, Programmatic, AppManaged, Filesystem); const val MAX_ARTIFACT_BYTES = 16L * 1024 * 1024 }
  }
  ```
  `stream` is `flow { val output = execute(...); if (output != null) emit(ProviderStreamEvent.Result(output, FinishReason.STOP)) }` as `AndroidSystemSpeechProvider.kt:218-221`; `run` throws `CancellationException` when `execute` returns null (`:202-212`). Cancellation is coroutine cancellation: `ensureActive()` before commit and after each `write`; on cancellation `session.stop()` in a `finally` (wrapped in `withContext(NonCancellable)` so the cleanup runs) and rethrow; the writes themselves stay cancellable. Turn-taking is a fair `Mutex` as `:85`.
- Consumes: Task 1's Core validator (`app.independo.inderun.core.getModelPackageValidationIssues`), `FixtureAudioOutputService` (`inderun-kotlin/src/sharedTest`), `conformanceHostServices` (`StreamConformanceFakes.kt`), `IndeRun(registry, hostServices)`, the walk-up fixture locator (`AudioOutputLifecycleConformanceTest.kt:23-33`).

- [ ] **Step 1: Create the module skeleton and the failing frontend/WAV/fixture-runtime tests**

Gradle file, settings include, the three test classes (vectors as in Tasks 3 and 5; the frontend test is `@RunWith(RobolectricTestRunner::class)` because it parses the fixture with `org.json`).

- [ ] **Step 2: Run them to verify they fail**

Run: `cd android && ./gradlew :inderun-neural-speech:testDebugUnitTest`
Expected: FAIL to compile — unresolved references.

- [ ] **Step 3: Implement the seams, frontend, encoder and fixture runtime; run until green**

Run: `cd android && ./gradlew spotlessApply && ./gradlew :inderun-neural-speech:testDebugUnitTest`
Expected: PASS.

- [ ] **Step 4: Write the failing provider unit tests and the lifecycle catalog test**

`NeuralSpeechProviderTest.kt` (plain JUnit, the seven cases of Task 4 Step 1, contexts built as `AndroidSystemSpeechProviderTest.kt:114-119`). `NeuralSpeechLifecycleConformanceTest.kt` in `inderun-kotlin` (`@RunWith(RobolectricTestRunner::class)`, `runTest`), one handler per case id driving `IndeRun` with the fixture runtime, `FixtureAudioOutputService` and a recording fallback fake, through the Kotlin facade (`speak`/`generateSpeech` in `SpeechGeneration.kt`, as `SpeechGenerationTest.kt` does); guard test on the ids; `withTimeoutOrNull(timeoutMs)` on every wait.

- [ ] **Step 5: Run them to verify they fail, implement `NeuralSpeechProvider.kt`, run until green**

Run: `cd android && ./gradlew spotlessApply && ./gradlew :inderun-neural-speech:testDebugUnitTest && ./gradlew :inderun-kotlin:testDebugUnitTest --tests "app.independo.inderun.sdk.NeuralSpeechLifecycleConformanceTest"`
Expected: PASS.

- [ ] **Step 6: Whole Android build, publishing baseline, README, commit**

Run: `cd android && ./gradlew test && cd .. && pnpm verify:android-api-deps --update && git diff --stat android/published-api-dependencies.txt`
Expected: tests PASS (`:inderun-consumer-smoke` included); the baseline diff adds only `inderun-neural-speech compile …` lines (contracts, core, kotlin-stdlib, kotlinx-coroutines-core); `pnpm verify:android-api-deps --no-generate` then PASSES.

```bash
git add android/settings.gradle.kts android/inderun-neural-speech android/inderun-kotlin/build.gradle.kts android/inderun-kotlin/src/test/kotlin/app/independo/inderun/sdk/NeuralSpeechLifecycleConformanceTest.kt android/published-api-dependencies.txt android/README.md docs/release.md
git commit -m "feat(android): add the inderun-neural-speech provider module"
```

---

### Task 7: Family doc, provider matrix, scope line, migration note, web README

**Files:**
- Create: `docs/architecture/neural-speech-provider-family.md`
- Modify: `docs/architecture/providers.md` (Provider Matrix: one row after the system speech row; the paragraph after the matrix that counts streaming families gains "and the neural speech family's `stream` is lifecycle-only like system speech")
- Modify: `docs/architecture/architecture.md` (`## Host Services` section: one sentence that the neural speech family is the first consumer of `audioOutput`)
- Modify: `CONTEXT.md:42-43` (scope line gains: "A neural speech provider family (`local.onnx.speech.*`, runtime seam, fixture runtime) exists on all three SDKs; its ONNX executor and the first model pipeline follow (ADR 020, ADR 021).")
- Modify: `docs/migration.md` (new `### Neural speech provider family` after `### Audio output host service`: additive; new subpath/product/module; `getModelPackageValidationIssues` moved from the ONNX modules to Core on Swift and Kotlin — a consumer that imported it from `IndeRunOnnxProviders` / `app.independo.inderun.providers.onnx` imports it from Core now; `SpeechWAV` is public in `IndeRunCore`)
- Modify: `packages/inderun-web/README.md` (new `## On-Device Models: Neural speech` before `## Commands` at `:347`: `createIndeRunWeb({ neuralSpeech: [{ modelPackage, runtime }] })`, the subpath, the fixture runtime for demos, the gesture requirement inherited from the audio output, that the ORT runtime arrives with PR 4)
- Modify: `docs/architecture/api-layering.md` only if the `SpeechVoiceInfo.kind` sentence at `:87` needs the family named (it already describes `kind`; add "the neural speech family is the first `model` kind" only if absent)

**Interfaces:** none (documentation).

- [ ] **Step 1: Write the family doc**

Sections, in the voice of `system-speech-provider-family.md`: Scope (what ships now, what PR 4/5 add); Ids and registration per SDK (composed id, one provider per package); Options; The seams (`NeuralSpeechRuntime`, `SpeechGraphExecutor`, `PcmChunk`, `SpeechTensor`, where `limits.memBytes` and unknown `pipeline` are refused and why: the runtime is what allocates); Capabilities order; Playback and artifact (commit placement, cancel = `stop()`, the 16 MiB cap, never resample); Timing (`firstChunkMs`, `firstAudioMs`, `durationMs`, one origin; the web `firstAudioMs` caveat from ADR 021); Error codes (`audio_output_unavailable`, `voice_not_available`, `artifact_too_large`, `audio_output_interrupted`, `audio_format_unsupported`, `audio_not_allowed`, runtime kinds); The text frontend (sentence rule, grapheme tokenizer, pipeline normalizers are per pipeline); Fixtures (the two files and the guard pattern); Placement per SDK (paths, products, modules, no dependency beyond Core); "Implementation detail … lives in code comments in" the three directories (the CLAUDE.md §8 pattern).

- [ ] **Step 2: Matrix row**

`| Neural speech (`local.onnx.speech.*`) | Shipped (`@independo/inderun-web/neural-speech`, `createIndeRunWeb({ neuralSpeech })`) | Shipped (`IndeRunNeuralSpeech`, registered explicitly) | Shipped (`inderun-neural-speech`, registered explicitly) | Custom/developer-supplied local | `text_to_speech` | `run` (Mode 1), `stream` (Mode 2, lifecycle only, cancel `hard`); `playback` through `HostServices.audioOutput`, `artifact` (`audio/wav`) | Package validation, source type, platform, then `runtime.availability` (files, memory, pipeline); readiness `cold` until `prepare`; voices from the package with `locales` | Developer supplies the package files; no download | The `ModelPackage` id; the id is `<default>:<model id>` | No runtime ships yet: the ORT executor and the first pipeline (Articulino) follow in #260 PR 4, Core AI in PR 5; until then only an injected runtime (the fixture runtime for demos) synthesizes. Refuses playback before commit on a host without `audioOutput` (`audio_output_unavailable`). Artifacts cap at 16 MiB (≈5.5 min at 24 kHz). One utterance at a time per instance. See [the family doc](./neural-speech-provider-family.md) |`

- [ ] **Step 3: The rest, then check and commit**

Run: `pnpm format:check`
Expected: PASS.

```bash
git add docs CONTEXT.md packages/inderun-web/README.md
git commit -m "docs(providers): describe the neural speech provider family"
```

---

### Task 8: Whole-branch verification, squash and PR

- [ ] **Step 1: Automated**

Run: `pnpm test:js && swift test && (cd android && ./gradlew test) && (cd ios/IndeRun && swiftlint lint --strict) && (cd android && ./gradlew spotlessCheck) && pnpm format:check && pnpm build && pnpm verify:packaging && pnpm verify:android-api-deps --no-generate && pnpm verify:enum-wire-parity && git diff --exit-code`
Expected: all PASS; no generated file changed.

- [ ] **Step 2: Squash, push and open the PR into `dev`**

One commit: `feat(providers): add the neural speech provider family (#260)` with a body naming the three modules, the seams, the fixture runtime, the two fixtures, the validator move and the `SpeechWAV` move; trailer last.

```bash
git push -u origin feat/m5-neural-speech-provider-family
gh pr create --base dev --title "feat(providers): neural speech provider family on all three SDKs (#260, PR 3)" --body-file <body>
```

---

### Critical Files for Implementation

- `contracts/fixtures/speech/neural-speech-lifecycle.json` (new; the catalog every SDK's engine runs)
- `contracts/fixtures/speech/neural-frontend.json` (new; the sentence rule and tokenizer vectors)
- `packages/inderun-web/src/providers/neural-speech/provider.ts` (new; the playback and artifact algorithms the other two port)
- `ios/IndeRun/Sources/IndeRunNeuralSpeech/NeuralSpeechProvider.swift` and `android/inderun-neural-speech/src/main/kotlin/app/independo/inderun/providers/neuralspeech/NeuralSpeechProvider.kt` (new; ports with Task-cancellation and coroutine-cancellation semantics)
- `packages/inderun-web/src/providers/system-speech/provider.ts:160-300` (the commit-before-play, turn and timing patterns to copy)
- `Package.swift`, `android/settings.gradle.kts`, `android/published-api-dependencies.txt` (module wiring that CI checks)
