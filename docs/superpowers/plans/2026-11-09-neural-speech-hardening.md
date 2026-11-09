# Neural Speech Hardening (#280) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Neural speech cannot hang on a stalled audio device, its memory can be freed through a public `close()`,
its known flaky tests become deterministic, both WASM modules ship as size-checked release builds, and the iOS demo
tests run in CI.

**Architecture:**
- Every wait on an audio output session has a wall-clock bound: unplayed audio time + 2 000 ms grace. When it
  expires, the session fails with `audio_output_failed`. A shared fixture case pins this.
- Lifecycle follows "whoever creates a thing closes it". Neural speech runtimes get a terminal, idempotent
  `close()`. Engines get `close()`, which stops their own work and closes only what they constructed.
- The other items are local fixes in tests, the WASM build script and `swift.yml`.

**Tech Stack:** TypeScript (Vitest), Swift 6 (XCTest, SwiftPM), Kotlin (JUnit, coroutines, Robolectric), Rust (cargo
test), Node build scripts, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-09-neural-speech-hardening-design.md` (read in full). Parent:
`docs/superpowers/specs/2026-11-04-neural-speech-design.md`. ADRs 021, 022, 023.

## Global Constraints

- Branch `feat/m5-neural-speech-remaining`; never commit to `dev`/`main`. Task commits are squashed into one #280
  commit at the end.
- Commit trailers, last: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and `Claude-Session: <session url>`.
- Parity: Web, Swift and Kotlin get the same behaviour, the same error codes and the same fixture cases.
- TDD: run every new test and watch it fail before writing the code that makes it pass.
- Grace for output waits: `2_000` ms on all platforms, injectable, with today's Android behaviour as the default.
- Error codes, exact: `audio_output_failed` (`Unavailable`), `runtime_closed` (`Unavailable`), `engine_closed`
  (`Unavailable`). Runtime close message: `runtime closed`.
- Never hand-edit generated files (`contracts/api` → `pnpm generate`).
- Timing assertions use fake or injected clocks, never exact wall-clock equality.
- Text handling on user input must not use backtracking regexes (CodeQL `js/polynomial-redos`).
- Doc placement (CLAUDE.md §8): durable semantics in `docs/architecture`, bounds/algorithms in code comments.
- Any change to the workspace `Cargo.toml` → `pnpm build:route-core-apple`, committing both XCFrameworks + both
  `*.provenance.json` in the same task.
- Formatting: Prettier, `swiftlint lint --strict`, `./gradlew spotlessApply`, `cargo fmt`.

## Review Focus

1. **Stall after partial playback.** Audio plays for a while, then the device stops. The drain bound counts only the
   unplayed remainder, so failure comes within remaining + grace, not total + grace. Owner: Tasks 1–3, test
   `drain_bound_counts_only_unplayed_audio`.
2. **`stop()` during a stalled drain.** The drain resolves at once with no `audio_output_failed`, and no timer fires
   later. Owner: Tasks 1–3, test `stop_releases_a_stalled_drain`.
3. **Two providers share one runtime.** Closing the runtime while provider A is idle and provider B is mid-synthesis:
   A refuses with `runtime_closed` before commit, B ends with terminal `runtime_closed`, and no executor is closed
   while one of its graph calls is running. Owner: Tasks 4–6, test `close_during_synthesis_waits_for_graph_boundary`.
4. **`close()` racing a new call.** `engine.close()` while `stream()` is being set up: the stream either completes
   cancellation normally or is rejected with `engine_closed`. It never hangs and never emits after its terminal event.
   Owner: Tasks 7–9, test `close_racing_stream_start`.
5. **Double close.** Calling close concurrently from two callers: both return, and providers or runtimes are closed
   exactly once. Owner: Tasks 4–9, tests `close_is_idempotent` (runtime) and `concurrent_close_closes_once` (engine).

---

### Task 1: Stall fixture case + Web bounded waits

**Files:**
- Modify: `contracts/fixtures/host/audio-output-lifecycle.json` (case + `$expectKeys.drainRejectsWith`)
- Modify: `packages/inderun-web/src/test/audio-output-fixture.ts` (stalled mode)
- Modify: `packages/inderun-web/src/core/audio-output.conformance.test.ts`
- Modify: `packages/inderun-web/src/core/browser-audio-output.ts` (`write()` :120-162, `drain()` :169-176)
- Test: `packages/inderun-web/src/core/browser-audio-output.test.ts`
- Modify: `docs/architecture/decisions/021-audio-output-host-service.md` §5 (one sentence)

**Interfaces:**
- Produces: fixture case `drain_fails_when_output_stalls`, with `setup` "open, write 500 ms, output never advances"
  and `expect: { drainRejectsWith: "audio_output_failed", drain: { elapsedAtLeastMs: 500, timeoutMs: 2500 } }`.
  Tasks 2 and 3 run it.
- Produces: `BrowserAudioOutputServiceOptions.outputWaitGraceMs?: number` (default `2000`). Timers go through the
  existing timer seam, or a new `setTimeout`-compatible option if none exists, so fake timers control them.

- [ ] **Step 1: Add the fixture case.** If all three fixture services can model it, also add
  `write_fails_when_output_stalls` (backpressure stall). Otherwise record why in the fixture `$comment`.
- [ ] **Step 2: Write the failing tests.**
  - Conformance runner: handle `drainRejectsWith` and run the new case against the fixture service in stalled mode.
  - `browser-audio-output.test.ts`, with `fakeAudioContext` whose `currentTime` never advances and
    `vi.useFakeTimers`:
    - `drain rejects with audio_output_failed after written duration + grace`: write 500 ms, `drain()`, advance timers
      2 499 ms and expect it still pending, advance 2 ms and expect it rejected with an `IndeRunException` having
      `errorClass: "Unavailable"`, `details.code: "audio_output_failed"`.
    - `drain_bound_counts_only_unplayed_audio`: write 2 000 ms, let 1 500 ms play by advancing `currentTime` and
      firing `onended` for those sources, then freeze. Expect the bound to be 500 + 2 000 ms.
    - `stop_releases_a_stalled_drain`: a stalled drain plus `stop()` resolves, and advancing 10 s afterwards fires no
      rejection.
    - `write backpressure wait is bounded`: lead above `maxLeadSeconds` with a frozen clock rejects with
      `audio_output_failed`.
    - After a failure: `write()` is ignored and `drain()` resolves at once.
- [ ] **Step 3: Run** `pnpm --filter @independo/inderun-web test -- audio-output` and expect the new tests to FAIL.
- [ ] **Step 4: Implement the fixture stalled mode and the bounded waits.** The bound is computed when the wait starts:
  unplayed scheduled seconds (scheduled end − last observed `currentTime`) × 1000 + grace. Use wall-clock timers, not
  `currentTime`. On expiry, mark the session failed: stop sources and reject the current and any parked waiters. Doc
  comments on `write`/`drain` state the bound.
- [ ] **Step 5: Run the tests again; they PASS.** Run `pnpm --filter @independo/inderun-web test` (all green).
- [ ] **Step 6: ADR 021 §5.** Add one sentence: waits on the output are bounded and end in `audio_output_failed`; the
  exact bound is in the services' doc comments.
- [ ] **Step 7: Commit.** `fix(web): bound audio output waits (#280)`.

### Task 2: Swift bounded waits

**Files:**
- Modify: `ios/IndeRun/Sources/IndeRunCore/AVAudioEngineAudioOutputService.swift` (write :129-160, drain :162-165)
- Modify: `ios/IndeRun/Sources/IndeRunCore/AudioOutputGate.swift` (`awaitDrained` :59-64)
- Modify: `ios/IndeRun/Tests/IndeRunTests/FixtureAudioOutput.swift` (stalled mode)
- Modify: `ios/IndeRun/Tests/IndeRunTests/AudioOutputLifecycleConformanceTests.swift`
- Test: `ios/IndeRun/Tests/IndeRunTests/AudioOutputGateTests.swift` (or a new `AudioOutputStallTests.swift`)

**Interfaces:**
- Consumes: fixture case `drain_fails_when_output_stalls` (Task 1).
- Produces: `AVAudioEngineAudioOutputService.init(outputWaitGrace: Duration = .milliseconds(2000), …existing)`.
  The gate gets `awaitDrained(deadline:)`, or the same with a sleep function the tests can inject, so they run without
  real 2 s waits.

- [ ] **Step 1: Write the failing tests.** The conformance runner handles `drainRejectsWith`. Gate/service tests with
  a session that never reports played frames:
  - `testDrainFailsWithAudioOutputFailedWhenOutputStalls`
  - `testDrainBoundCountsOnlyUnplayedAudio`
  - `testStopReleasesAStalledDrain`
  - `testBackpressureWaitIsBounded` (if Swift `write` parks)
  - `testWritesAfterFailureAreIgnored`

  Use a short injected grace (for example 50 ms) and assert ordering, not exact durations.
- [ ] **Step 2: Run** `swift test --filter 'AudioOutput'` and expect FAIL.
- [ ] **Step 3: Implement.** Race the gate wait against a deadline of unplayed frames / sampleRate + grace. On expiry,
  throw the existing `failed()` error (`audio_output_failed`) and end the gate so every waiter is released. Do the same
  for any write wait. Put the bound in the doc comment.
- [ ] **Step 4: Run** `swift test --filter 'AudioOutput'` and expect PASS. Then run full `swift test`. The real
  `AVAudioEngine` conformance run may still skip on a machine without output; that is expected.
- [ ] **Step 5: Commit.** `fix(swift): bound audio output waits (#280)`.

### Task 3: Kotlin injectable bounds + fixture case

**Files:**
- Modify: `android/inderun-core/src/main/kotlin/app/independo/inderun/core/AudioTrackAudioOutputService.kt` (:33-35
  ctor, :186-217, :288-293)
- Modify: `android/inderun-kotlin/src/sharedTest/kotlin/app/independo/inderun/sdk/{FixtureAudioOutput.kt,AudioOutputLifecycleCatalog.kt}`
- Test: `android/inderun-core/src/test/.../AudioTrackAudioOutputDrainTest.kt`

**Interfaces:**
- Consumes: the fixture case from Task 1.
- Produces: constructor parameters `drainGraceMs: Long = 2_000L`, `drainPollMs: Long = 10L` on
  `AudioTrackAudioOutputService`. Existing callers are unchanged.

- [ ] **Step 1: Write the failing tests.**
  - The catalog handles `drainRejectsWith`, and the fixture has a stalled mode.
  - Drain tests on `HeadControlledAudioTrack`:
    - `drainBoundCountsOnlyUnplayedAudio`: the head reaches half the target, then stalls. With virtual time, the failure
      happens at remaining + grace.
    - `stopReleasesAStalledDrain`.
    - `writeBackpressureWaitIsBounded`: only if Kotlin `write` can park on a stalled track. Otherwise note in the test
      file why it cannot.
- [ ] **Step 2: Run** `cd android && ./gradlew :inderun-core:test :inderun-kotlin:test` and expect FAIL. Only the new
  cases should fail; today's stall test keeps passing.
- [ ] **Step 3: Implement** the constructor parameters and the stalled mode. Fix any gap the new tests expose.
- [ ] **Step 4: Run the same command; it PASSES.** Then run `./gradlew spotlessApply`.
- [ ] **Step 5: Commit.** `fix(android): make audio output wait bounds injectable, pin stall case (#280)`.

### Task 4: Web runtime `close()` + `runtime_closed`

**Files:**
- Modify: `packages/inderun-web/src/providers/neural-speech/runtime.ts` (interface :109, error class)
- Modify: `packages/inderun-web/src/providers/neural-speech/onnx-runtime.ts` (cache :79-117)
- Modify: `packages/inderun-web/src/providers/neural-speech/fixture-runtime.ts`
- Modify: `packages/inderun-web/src/providers/neural-speech/provider.ts` (`mapRuntimeError` :707-728)
- Test: `packages/inderun-web/src/providers/neural-speech/{onnx-runtime.test.ts,provider.test.ts}`
- Modify docs: `docs/architecture/neural-speech-provider-family.md` (replace the :257 sentence) and the
  `docs/architecture/providers.md` rows :77-78 (`runtime_closed`)

**Interfaces:**
- Produces:
  - `NeuralSpeechRuntime.close?(): Promise<void>`.
  - `NeuralSpeechRuntimeError` constructor `(kind, message, originalError?: unknown, code?: string)` with
    `readonly code?: string`. The provider puts `code` into `details.code` when present.
  - `createOnnxNeuralSpeechRuntime(...)` returns a runtime whose `close()` is terminal and idempotent. After close,
    `availability` reports unavailable with reason `runtime closed`, and `prepare`/`synthesize` throw
    `new NeuralSpeechRuntimeError("unavailable", "runtime closed", undefined, "runtime_closed")`.
  - Fixture runtime: the same behaviour.

- [ ] **Step 1: Write the failing tests.**
  - `close releases every cached pipeline's executor exactly once`: a spy executor whose `close` is counted.
  - `close_is_idempotent`: two concurrent `close()` calls close each executor once.
  - `after close, availability/prepare/synthesize report runtime_closed`.
  - `close_during_synthesis_waits_for_graph_boundary`: a scripted executor holds a `run` open, `close()` is called, the
    executor's `close` is not called until `run` returns, and the synthesis then ends.
  - Provider tests:
    - pre-commit `runtime_closed` falls back to the next provider: two providers in a registry, the first runtime
      closed;
    - committed playback ending with terminal `Unavailable`/`runtime_closed`.
- [ ] **Step 2: Run** `pnpm --filter @independo/inderun-web test -- neural-speech` and expect FAIL.
- [ ] **Step 3: Implement.** A `closed` flag plus in-flight tracking in the composed runtime. Executors are closed
  after their in-flight graph call settles. Graph calls check the flag at each boundary, where the existing signal
  checks are.
- [ ] **Step 4: Run the same tests; they PASS.** Then run `pnpm --filter @independo/inderun-web test`.
- [ ] **Step 5: Docs.** Family doc: replace "The composed runtimes have no `close()`…" with the close semantics (terminal,
  idempotent, `runtime_closed`, owner closes). Provider matrix rows: mention `runtime_closed`.
- [ ] **Step 6: Commit.** `feat(web): add neural speech runtime close() (#280)`.

### Task 5: Swift runtime `close()` (ONNX + Core AI)

**Files:**
- Modify: `ios/IndeRun/Sources/IndeRunNeuralSpeech/NeuralSpeechRuntime.swift` (protocol + error)
- Modify: `ios/IndeRun/Sources/IndeRunOnnxProviders/OnnxNeuralSpeechRuntime.swift` (cache :34-42, :106-114)
- Modify: `ios/IndeRun/Sources/IndeRunCoreAIProviders/CoreAINeuralSpeechRuntime.swift` (cache :37-60, :289-309)
- Modify: `ios/IndeRun/Sources/IndeRunNeuralSpeech/{ComposedNeuralSpeechRuntime.swift,FixtureNeuralSpeechRuntime.swift,NeuralSpeechProvider.swift}`
- Test: `ios/IndeRun/Tests/IndeRunTests/{NeuralSpeechProviderTests.swift,OnnxNeuralSpeechRuntimeTests.swift,CoreAINeuralSpeechRuntimeTests.swift}`
  (use the existing files that test these types)

**Interfaces:**
- Consumes: the semantics of Task 4. They must be identical.
- Produces:
  - `func close() async` on `NeuralSpeechRuntime`, with a default no-op extension.
  - `NeuralSpeechRuntimeError.init(kind:message:originalError:code: String? = nil)` and `public let code: String?`.
  - The provider maps `code` to `details.code`.

- [ ] **Step 1: Write the failing tests.** These are the same six behaviours as Task 4 Step 1, written as Swift test
  names (`testCloseIsIdempotent`, `testCloseDuringSynthesisWaitsForGraphBoundary`, …).
  - Core AI: cover `close()` + `runtime_closed` in the test that already builds a Core AI runtime without a device
    model. The executor-boundary test runs only through the shared composition helper.
- [ ] **Step 2: Run** `swift test --filter 'NeuralSpeech|CoreAI|Onnx'` and expect FAIL.
- [ ] **Step 3: Implement.** Mirror the Web structure. Executor `close()` is awaited after the in-flight graph call.
- [ ] **Step 4: Run** the same command and expect PASS. Then run `swift test` and
  `cd ios/IndeRun && swiftlint lint --strict`.
- [ ] **Step 5: Commit.** `feat(swift): add neural speech runtime close() (#280)`.

### Task 6: Kotlin runtime `close()`

**Files:**
- Modify: `android/inderun-neural-speech/src/main/kotlin/app/independo/inderun/providers/neuralspeech/{NeuralSpeechRuntime.kt,FixtureNeuralSpeechRuntime.kt,NeuralSpeechProvider.kt}`
- Modify: `android/inderun-onnx-providers/src/main/kotlin/app/independo/inderun/providers/onnx/OnnxNeuralSpeechRuntime.kt` (:120-131)
- Test: the existing `NeuralSpeechProviderTest.kt` and `OnnxNeuralSpeechRuntimeTest.kt` (or the closest existing
  runtime test)

**Interfaces:**
- Produces:
  - `interface NeuralSpeechRuntime : AutoCloseable`, with a default `override fun close() {}`. It is synchronous,
    because `AutoCloseable` is synchronous: it marks the runtime closed and schedules executor teardown after
    in-flight calls on the execution thread.
  - `NeuralSpeechRuntimeError(kind, message, cause = null, val code: String? = null)`.
- [ ] **Step 1: Write the failing tests.** These are the same six behaviours as Task 4, as Kotlin tests.
- [ ] **Step 2: Run** `cd android && ./gradlew :inderun-neural-speech:test :inderun-onnx-providers:test` and expect FAIL.
- [ ] **Step 3: Implement.** Mirror Task 4. Executor close runs under the existing mutex / execution thread, after the
  in-flight graph call.
- [ ] **Step 4: Run the same command; it PASSES.** Then run `./gradlew spotlessApply` and
  `pnpm verify:android-api-deps`. If `AutoCloseable` changes a POM scope, re-baseline with `--update` and say why
  in the commit body.
- [ ] **Step 5: Commit.** `feat(android): add neural speech runtime close() (#280)`.

### Task 7: Engine `close()` contract + Web engine

**Files:**
- Modify: `contracts/api/inderun-api.json` (operation `close`: `params: []`, `returns: void`, `async: true`,
  `throws: false`, with a description from spec §2)
- Generated: the `pnpm generate` outputs (`inderun-api.ts`, `IndeRunApi.kt`, `IndeRunApi.swift`)
- Modify: `packages/inderun-web/src/core/engine.ts` (`IndeRun` :134)
- Modify: `packages/inderun-web/src/web-sdk.ts` (`createIndeRunWeb` :104; close the factory-built providers)
- Modify: `packages/inderun-web/src/providers/onnx/*` (`OnnxRuntimeWebProvider.close()` disposes loaded pipelines)
- Test: `packages/inderun-web/src/core/engine-close.test.ts` (new), `packages/inderun-web/src/web-sdk.test.ts`
- Modify docs: `docs/architecture/api-layering.md` (new section "Lifecycle and ownership")

**Interfaces:**
- Produces:
  - `IndeRun.close(): Promise<void>`.
  - Closed-engine error: `createUnavailable("The engine is closed.", { details: { code: "engine_closed" } })` from
    `run`, `stream`, `prepare`, `checkCapabilities`, `readArtifact`. `disposeArtifact` is a no-op.
  - The engine tracks in-flight streams and prepares (their `AbortController`s) and in-flight runs (their promises).
  - The factory engine closes `OnnxRuntimeWebProvider` instances it built. It never closes an app-supplied runtime.

- [ ] **Step 1: Write the failing tests** (`engine-close.test.ts`):
  - `close cancels an in-flight stream: exactly one cancelled terminal, no events after`;
  - `close cancels an in-flight prepare`;
  - `close waits for an in-flight run to settle`;
  - `calls after close reject with engine_closed`;
  - `close disposes engine-owned artifacts`;
  - `concurrent_close_closes_once`;
  - `close_racing_stream_start`;
  - `close does not close an app-supplied runtime`, the two-engine parity test: two engines share one fixture runtime,
    closing engine A leaves engine B able to speak, then `runtime.close()` makes B fall back with `runtime_closed`.

  `web-sdk.test.ts`: `factory engine close closes the ONNX provider it built`.
- [ ] **Step 2: Run** `pnpm --filter @independo/inderun-web test -- close` and expect FAIL.
- [ ] **Step 3: Add the API operation, then run** `pnpm generate` (the Kotlin formatting step needs Gradle). Check that
  the generated diffs only add `close`.
- [ ] **Step 4: Implement** close in the engine order of spec §2 (mark, cancel, wait, dispose artifacts, close owned
  providers). A second call awaits the first call's promise.
- [ ] **Step 5: Run the same tests; they PASS.** Then run `pnpm test:js`, `pnpm verify:packaging` (after `pnpm build`)
  and `pnpm verify:enum-wire-parity`.
- [ ] **Step 6: Docs.** `api-layering.md` gets "Lifecycle and ownership": the rule, engine close, runtime close, the error
  codes, and that Mode 1 runs are awaited, not cancelled.
- [ ] **Step 7: Commit.** `feat(web): add engine close() (#280)`.

### Task 8: Swift engine `close()`

**Files:**
- Modify: `ios/IndeRun/Sources/IndeRunSwift/IndeRun.swift` (conform to the regenerated `IndeRunApi`)
- Test: `ios/IndeRun/Tests/IndeRunTests/EngineCloseTests.swift` (new)

**Interfaces:**
- Consumes: the generated `IndeRunApi.swift` `close` (Task 7) and runtime close (Task 5).
- Produces: `public func close() async`. The closed-engine error is an `IndeRunException` with `.unavailable` and
  `details.code == "engine_closed"`. The engine closes no providers, because the registry is app-built.

- [ ] **Step 1: Write the failing tests.** These are the same list as Task 7 Step 1 except the factory test, written as
  Swift tests. Include the two-engine parity test with `FixtureNeuralSpeechRuntime`.
- [ ] **Step 2: Run** `swift test --filter EngineCloseTests` and expect FAIL (or a compile failure from the missing
  member).
- [ ] **Step 3: Implement** the same order as Web. In-flight runs are tracked tasks; close awaits them and does not
  cancel them.
- [ ] **Step 4: Run** `swift test` and `swiftlint lint --strict`; both PASS.
- [ ] **Step 5: Commit.** `feat(swift): add engine close() (#280)`.

### Task 9: Kotlin engine `close()`

**Files:**
- Modify: `android/inderun-kotlin/src/main/kotlin/app/independo/inderun/sdk/IndeRun.kt` (:94)
- Test: `android/inderun-kotlin/src/test/kotlin/app/independo/inderun/sdk/EngineCloseTest.kt` (new)

**Interfaces:**
- Consumes: the generated `IndeRunApi.kt` `close` (Task 7) and runtime close (Task 6).
- Produces: `override suspend fun close()`, with the same error shape `engine_closed`.

- [ ] **Step 1: Write the failing tests.** These are the same list as Task 8, in Kotlin.
- [ ] **Step 2: Run** `cd android && ./gradlew :inderun-kotlin:test --tests '*EngineCloseTest*'` and expect FAIL.
- [ ] **Step 3: Implement.** Mirror Task 8.
- [ ] **Step 4: Run** `./gradlew test spotlessCheck` and `pnpm verify:android-api-deps`; all PASS.
- [ ] **Step 5: Commit.** `feat(android): add engine close() (#280)`.

### Task 10: Deterministic Kotlin cancel test

**Files:** Modify:
`android/inderun-neural-speech/src/test/kotlin/app/independo/inderun/providers/neuralspeech/ArticulinoPipelineConformanceTest.kt`
(:604-623)

- [ ] **Step 1: Prove the race.** Insert a temporary delay before `launched.complete(job)` (for example
  `Thread.sleep(50)`). Run `./gradlew :inderun-neural-speech:test --tests '*cancelBetweenGraphs*'`; it FAILS.
  Record the failure message, then remove the delay.
- [ ] **Step 2: Fix.** Launch with `start = CoroutineStart.LAZY`, assign the job to the handle the executor's
  `afterCall` cancels, then call `job.start()`. Drop the deferred indirection.
- [ ] **Step 3: Verify.** With the temporary delay put back, the test PASSES; remove the delay again. Then run the test
  50 times in a loop, and every run PASSES.
- [ ] **Step 4: Commit.** `test(android): make cancelBetweenGraphs deterministic (#280)`.

### Task 11: Swift synthesizer retirement test

**Files:** Modify: `ios/IndeRun/Tests/IndeRunTests/AppleSystemSpeechArtifactTests.swift` (:99-138). Production code
in `ios/IndeRun/Sources/IndeRunAppleProviders/AppleSpeechRuntime.swift` changes only if the investigation shows a real
leak.

- [ ] **Step 1: Investigate** with `superpowers:systematic-debugging`. Check the hypothesis that a provider cancelled
  before `PlaybackSynthesizer.shared()` never counts. Shrink the 300 ms sleep to 0 and loop the test. Separately,
  check whether other tests touch the process-global retirement counter concurrently.
- [ ] **Step 2: Write down the confirmed cause** in the task report, with evidence such as the failing counts.
- [ ] **Step 3: Fix the cause.**
  - If the hypothesis holds, wait for the playback-started signal of each run before cancelling, instead of
    `Task.sleep(300 ms)`.
  - If a real leak shows up, fix it in production code and add a regression test.
- [ ] **Step 4: Verify.** Run `swift test --filter testDiscardedProvidersReleaseTheirSynthesizersAfterStoppedSpeech`
  20 times in a loop, plus the sleep-0 variant, and every run PASSES.
- [ ] **Step 5: Commit.** `test(swift): wait for playback before cancelling in the retirement test (#280)`, or a
  `fix(swift): …` subject if the cause was in production code.

### Task 12: Rust scaling tests

**Files:** Modify: `rust/inderun-route-core/src/speech_text/tests.rs` (:105-121, :124-145, :166-185)

**Interfaces:** Produces the test helper `fn assert_scales_linearly(name: &str, make: impl Fn(usize) -> String, n: usize)`,
which times inputs of size n and 2n. It asserts `t2 < 3 * t1` and `t2 < Duration::from_secs(10)`, and prints both
timings on failure.

- [ ] **Step 1: Check the helper catches a quadratic case.** Feed it a closure that builds an O(n²) string (for example
  repeated concatenation scanning) and confirm it FAILS. Then delete that check, because it was scaffolding.
- [ ] **Step 2: Rewrite the three tests.** Use the same input patterns, with n chosen so that `t(n) ≥ ~20 ms` in a
  debug build.
- [ ] **Step 3: Verify.** `cargo test -p inderun_route_core speech_text` PASSES, ten times in a loop. Also run
  `cargo fmt -p inderun_route_core -- --check` and
  `cargo clippy -p inderun_route_core --all-targets -- -D warnings`.
- [ ] **Step 4: Commit.** `test(rust): assert linear scaling instead of wall time in speech_text tests (#280)`.

### Task 13: WASM release builds + size gate

**Files:**
- Modify: `Cargo.toml` (add `[profile.wasm]` after `[profile.android]`, with a comment)
- Modify: `scripts/build-route-core-wasm.mjs` (:36-55 paths, :104-122 `--profile wasm`)
- Create: `scripts/check-wasm-size.mjs`, plus `package.json` script `check:wasm-size`
- Modify: `.github/workflows/javascript.yml` (after `pnpm build:wasm`, :155-156), `.github/workflows/release.yml`
  (after :155)
- Regenerate + commit: `ios/IndeRun/Frameworks/*.xcframework`, `*.provenance.json`, and
  `packages/inderun-route-core-wasm/generated/*.d.ts` if they changed
- Modify docs: `README.md`, `CLAUDE.md` (command list), `docs/ci.md` (:319-330, :432-441), ADR 023 (:62-65)

**Interfaces:** Produces the `pnpm check:wasm-size` command. It prints `<module> raw=<bytes> gzip=<bytes>
budget=<raw>/<gzip>` per module and exits 1 when over budget.

- [ ] **Step 1: Write the size script with a deliberately tiny budget.** Run it after `pnpm build:wasm`; it FAILS. That
  proves the gate works.
- [ ] **Step 2: Release build.** Add the profile and switch the build script to it. Run `pnpm build:wasm` and record the
  raw/gzip sizes of both modules.
- [ ] **Step 3: Set the budgets** to the measured sizes + 15 %, rounded up to 10 KiB. Run `pnpm check:wasm-size`; it
  PASSES.
- [ ] **Step 4: Run** `pnpm test:js`. It PASSES against the release modules.
- [ ] **Step 5: Apple rebuild.** Run `pnpm build:route-core-apple`, then `pnpm verify:route-core-apple`, which
  PASSES. Then run `swift build`.
- [ ] **Step 6: Wire CI and update docs.** In ADR 023, the debug-build paragraph gets the new release sizes.
- [ ] **Step 7: Commit** everything, including the frameworks and manifests:
  `build(wasm): ship release builds with a size gate (#280)`.

### Task 14: iOS demo tests in CI

**Files:** Modify: `.github/workflows/swift.yml` (next to the demo build step), `docs/ci.md` (:402).

- [ ] **Step 1: Run locally.** Run `xcodebuild test -project ios/SampleApps/IndeRunDemo/IndeRunDemo.xcodeproj -scheme
  IndeRunDemo -destination 'platform=iOS Simulator,name=<an installed iPhone>'`. Fix any failing demo test inside this
  task; do not skip tests.
- [ ] **Step 2: Add the CI step.** Reuse the simulator-selection snippet of the existing package-simulator step.
- [ ] **Step 3: Update** `docs/ci.md` to describe the step, replacing "neither built nor run".
- [ ] **Step 4: Commit.** `ci(swift): run the iOS demo tests (#280)`.

### Task 15: Issue verification + squash

- [ ] **Step 1: Run** `pnpm test:js`, `pnpm test:rust`, `pnpm test:kotlin`, `pnpm test:swift`, `pnpm format:check`,
  `pnpm lint`, `cd ios/IndeRun && swiftlint lint --strict`, `cd android && ./gradlew spotlessCheck`,
  `pnpm verify:route-core-apple`, `pnpm verify:android-api-deps`, `pnpm verify:enum-wire-parity`,
  `pnpm check:wasm-size`. Read each output; all PASS.
- [ ] **Step 2: Squash.** `git reset --soft <issue-base>` and make one commit:
  `fix(speech): bound audio output waits, add close(), deflake tests, ship WASM release builds (#280)`. The body lists
  the items, the rulings (refcount replaced by the ownership rule; Mode 1 runs awaited, not cancelled; the runtime-close
  terminal mapping), and the follow-up "Capacitor bridge to expose close()". The trailers come last.
