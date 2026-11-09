# Neural speech hardening (#280) — design

Issue: #280 (part of #260). Parent spec: `2026-11-04-neural-speech-design.md`. ADRs: 021 (audio output), 022
(Core AI), 023 (German frontend).

## Intent

Neural speech should leave `benchmark_only` only once it cannot hang, its memory can be freed, and its tests do not
flake. #280 collected the gaps found while building PRs 2–6. None of them adds a feature. Each one either removes a
way the SDK can wait forever, gives the app control over memory, or makes CI trustworthy.

## Goals

1. `speak()` never hangs when the audio device stops rendering. Every wait on the output is bounded and ends in
   `audio_output_failed`, on all three SDKs. The shared fixture pins the behaviour.
2. An app can free the memory a neural runtime holds (ORT / Core AI sessions, hundreds of MB), and can shut down an
   engine, through a public API with parity on Web, Swift and Kotlin.
3. The three known flaky tests become deterministic.
4. Both WASM modules ship as release builds, and CI checks their size.
5. The iOS demo's unit tests run in CI.

## Non-goals

- Changing playback timing semantics (`firstAudioMs`, commit point) or the error taxonomy beyond the codes named here.
- Automatic memory-pressure eviction or unloading. Close is explicit.
- Reference counting or any other implicit shared-ownership scheme (owner decision, below).
- `wasm-opt` or other post-link optimisation. It may be added later if the size budget demands it.

## Anti-goals

- A fix that makes a flaky test pass by widening a timeout. The cause must be removed.
- A close that breaks an app with several engines sharing one runtime.
- Any event delivered after cancel, or more than one terminal outcome, during engine close.

## 1. Bounded audio output waits

**Today.**
- Android `AudioTrackAudioOutputService.drain()` is bounded: the remaining written duration plus `DRAIN_GRACE_MS`
  (2 000 ms). When the playback head does not reach the target in that window, it throws `audio_output_failed`.
- Web `BrowserAudioOutput.drain()` has no bound, and neither does the backpressure wait in its `write()`.
- Swift `AVAudioEngineAudioOutputService.drain()` (`AudioOutputGate.awaitDrained`) has no bound either.
- In playback mode, the provider's request timeout ends at the first chunk. Nothing else bounds the drain.

**Decided.**
- **Rule, same on every platform.** A wait on the output is bounded by the wall-clock audio time it is waiting
  for, plus a fixed grace of 2 000 ms:
  - for `drain()`, the not-yet-played duration at the moment `drain()` starts;
  - for a backpressure wait in `write()`, the time the queued lead must fall to admit the write.
- **Expiry.** The call fails with `errorClass: Unavailable`, `details.code: "audio_output_failed"` (ADR 021 §5),
  and a message naming the bound. The session is then treated as ended: later writes are ignored, a later `drain()`
  resolves at once, and `stop()` stays idempotent. This matches what `stop()` already guarantees.
- **The bound uses a wall clock, never the output's own clock.** A frozen `AudioContext.currentTime` or an
  `AVAudioEngine` that never runs an IO cycle must not stop the timer.
- **Injectable for tests.** The grace, the clock and the timer can be injected per platform (constructor options
  with defaults), so tests run on virtual time. Kotlin already accepts `ioDispatcher`; its grace and poll interval
  become parameters too. The defaults keep today's Android behaviour exactly.
- **Fixture.** `contracts/fixtures/host/audio-output-lifecycle.json` gains a case `drain_fails_when_output_stalls`:
  - setup: open, write 500 ms, the output never advances;
  - expect: `drain` rejects with `audio_output_failed` no earlier than the written duration and no later than written
    duration + grace.
  - A new expect key, `drainRejectsWith`, is documented in `$expectKeys`.
  - If the backpressure stall can be expressed the same way on all three fixture services, add a
    `write_fails_when_output_stalls` case as well. The builder decides from the fixture services.
  - The fixture services on all three SDKs gain a "stalled" mode for these cases. Each real service also gets a
    stall test with its fake: `fakeAudioContext` + fake timers (Web), an injected session (Swift), and
    `HeadControlledAudioTrack` (Android).
- **Docs.** ADR 021 §5 gets one sentence saying that waits on the output are bounded and how. The bound itself is
  documented in the `drain()`/`write()` doc comments, not in the ADR.

**Provider effect.** In playback mode the attempt has committed before the first audio, so a stall becomes the run's
terminal `audio_output_failed`, not a fallback. No provider code needs to change beyond what the drain already throws.

## 2. Lifecycle: whoever creates a thing closes it (owner decision, 2026-11-09)

The owner first proposed reference counting, to keep an engine close from breaking other engines that share a
provider. We replaced it with an explicit ownership rule, and the owner agreed. Reference counting would let a
runtime the app still holds die when the last engine closes. It would also count a twice-registered provider twice,
and it would make memory release depend on close order across engines.

**Rule.** An object that holds releasable resources has a `close()`. Whoever constructed it is responsible for
calling it. An engine closes only what the engine constructed itself, and never an object the app passed in.

**Neural speech runtime close.** The ONNX runtimes (Web, Swift, Kotlin) and the Core AI runtime (Swift) get a public
`close()`.
- It releases every cached pipeline and calls `close()` on their graph executors.
- It is idempotent and terminal. After close, `availability` reports unavailable, and `prepare` and `synthesize`
  fail with `NeuralSpeechRuntimeError` kind `unavailable` and the message `runtime closed`. The provider maps this to
  `errorClass: Unavailable`, `details.code: "runtime_closed"` before commit, so routing falls back.
- A synthesis already running when close is called ends at its next graph boundary. Its executor is closed only after
  that graph call returns, never while a graph is running.
- Shape:
  - Web: `close(): Promise<void>` on the `NeuralSpeechRuntime` interface, optional, so custom runtimes may omit it.
  - Swift: `func close() async` on the protocol, with a default no-op extension.
  - Kotlin: the runtime interface extends `AutoCloseable`, with a default no-op `close()`. Executor teardown already
    runs on the execution thread.
- The fixture runtimes implement it too, so the conformance tests can pin "closed means unavailable".

**Engine close.**
- `close()` on the engine:
  - Web `IndeRun.close(): Promise<void>`;
  - Swift `func close() async` on `IndeRun`;
  - Kotlin `suspend fun close()` on `IndeRun`.
- It is added to `contracts/api/inderun-api.json` (an `IndeRunApi` operation), and the generated API surfaces are
  regenerated.
- Steps, in order:
  1. Mark the engine closed. Every later `run`, `stream`, `prepare`, `readArtifact` and the speech
     facades fail with an `IndeRunException`, `errorClass: Unavailable`, `details.code: "engine_closed"`.
     `checkCapabilities` returns an empty snapshot instead (Swift's generated signature cannot throw, so all
     three SDKs agree). `disposeArtifact` stays a no-op.
  2. Cancel every in-flight stream and prepare through its existing cancel hook. Each gets its standard terminal
     cancelled outcome. No events follow the cancel, as the existing cancellation guarantee already requires.
     In-flight Mode 1 `run()` calls are not cancelled, because Mode 1 has no cancel path and close adds none.
     Close waits for them to settle; provider timeouts and the bounds from §1 keep that wait finite. (Builder's call:
     this keeps Mode 1 semantics unchanged and gives the same behaviour on all three SDKs.)
  3. Wait for the streams, prepares and runs to reach their terminal outcomes.
  4. Dispose all engine-owned artifacts.
  5. Close the providers the engine constructed itself. Today only the Web factory `createIndeRunWeb` constructs
     providers from options. It closes the ones that have a `close()` (for example `OnnxRuntimeWebProvider`'s ORT
     sessions). It never closes the `runtime` object an app passed in `neuralSpeech[].runtime`. Swift and Kotlin
     engines take an app-built registry, so they close no providers.
- Close is idempotent. A second call returns once the first has finished.
- **Speech facades.** `speak()` and `generateSpeech()` are built on `stream()` and `run()` (Web
  `facade/speech.ts`; Swift and Kotlin work the same way), so step 2 covers them. Cancelling a playback run already
  calls `AudioOutput.stop()` through the provider's cancel path, so no audio plays after close. A drain that is
  stalled at close time ends with the stop, because `stop()` releases every waiter.
- **A runtime closed under a committed run (builder's call).** If a runtime is closed while one of its syntheses is
  already committed (in playback mode, that is from the first chunk on), that run ends with the terminal error
  `Unavailable` / `runtime_closed`. Audio already played stays played, and nothing falls back. The run was not cancelled
  by its caller, so this is a failure, not a cancellation. Before commit, the provider refuses with the same code and
  routing falls back. Both cases are pinned by tests on all three SDKs.
- **Web factory providers (builder's call).**
  - `createIndeRunWeb` constructs `OpenAIResponsesProvider`, `OnnxRuntimeWebProvider`, `SystemModelWebProvider`,
    `SystemSpeechWebProvider` and the neural speech providers from options.
  - Neural providers always take an app-supplied `runtime`; the factory never creates one. Closing a factory-built
    neural provider therefore releases nothing of the runtime.
  - `OnnxRuntimeWebProvider` holds loaded ORT pipelines. It gets a `close()` that disposes them, and the factory
    engine calls it.
  - Providers with nothing to release get no `close()`.
- **Error codes (builder's call).** `details.code` is an open string, not a schema enum (as `artifact_not_found` is
  today), so `engine_closed` and `runtime_closed` need no contract regeneration. They are listed in the docs where the
  existing codes are listed.
- **Capacitor bridge.** The separate `capacitor-inderun` repo consumes the published SDKs. Exposing `close()` there
  is a follow-up in that repo. The PR body mentions it, and it is out of scope here.
- **Parity test, all three SDKs.** Two engines share one neural runtime. Closing the first leaves the second able to
  speak. Closing the runtime makes the second fall back with `runtime_closed`.

**Docs.**
- `docs/architecture/api-layering.md` gets a short section, "Lifecycle and ownership", with the rule, engine
  `close()` and runtime `close()`.
- The family doc replaces "The composed runtimes have no `close()`…" with the runtime close semantics.
- The Provider Matrix rows for neural and Core AI speech mention `runtime_closed`.

## 3. Flaky tests

The cause must be shown before each fix (`superpowers:systematic-debugging`). A fix only widens a timeout when the
investigation shows the timeout itself is wrong.

- **Kotlin `ArticulinoPipelineConformanceTest.cancelBetweenGraphs`.** The cancel is wired through a deferred `Job`
  that the test thread completes after launch, while graph calls run on `Dispatchers.Default`. Call #2 can therefore
  happen before the job is published. Fix: start the job `LAZY`, publish it, then `start()`. The executor cancels the
  job at the boundary synchronously, so the cancel is ordered before the runtime's next `ensureActive()`. The fixture's
  `callsAtMost` stays the assertion.
- **Swift `AppleSystemSpeechArtifactTests.testDiscardedProvidersReleaseTheirSynthesizersAfterStoppedSpeech`
  (`2 != 4`).** Suspected cause: a provider counts only after its playback reached `PlaybackSynthesizer.shared()`.
  The test cancels after a fixed 300 ms, so on a slow runner some providers are cancelled before playback creates a
  synthesizer. Confirm first, then make the test wait for the playback-started signal before cancelling. If the cause
  is different (for example the process-global counter is touched by a concurrently running test), fix that cause
  instead and record it.
- **Rust `speech_text::tests::long_benign_lines_are_still_normalized` and its two 1.0 s siblings.** The tests guard
  against super-linear time, but they assert an absolute wall time in an unoptimised CI build. Replace each with a
  scaling assertion: normalise input of size n and 2n, then require `t(2n) < 3 × t(n)`. Choose n so that `t(n)` is at
  least tens of milliseconds, which keeps the ratio stable. Keep a generous absolute ceiling (for example 10 s) as a
  backstop. The inputs keep exercising the same patterns.

## 4. WASM release builds

- Add `[profile.wasm]` to the workspace `Cargo.toml` next to `apple` and `android`: inherits `release`,
  `opt-level = "z"`, `lto = true`, `codegen-units = 1`. Include a comment in the same style as the neighbouring
  profiles.
- `scripts/build-route-core-wasm.mjs` builds both modules with `--profile wasm` and reads
  `.../wasm32-unknown-unknown/wasm/...`. The staleness check keeps working.
- **Size gate.** A new `scripts/check-wasm-size.mjs` (`pnpm check:wasm-size`) prints the raw and gzip size of each
  `_bg.wasm`. It fails when either exceeds its budget.
  - The budgets live in the script, set from the first release build plus about 15 % headroom.
  - It runs in `javascript.yml` right after `pnpm build:wasm`, and in `release.yml` before publishing.
  - Document the command in `README.md` and the CLAUDE.md command list.
- The workspace `Cargo.toml` is part of the Apple provenance hash, so `pnpm build:route-core-apple` runs in the same
  change. Both XCFrameworks and both `*.provenance.json` manifests are committed with it.
- Docs: ADR 023's "what ships today is the debug profile" paragraph gets the release numbers. `docs/ci.md` describes
  the size gate.
- The committed `generated/*.d.ts` files are regenerated by the build, whatever the pinned wasm-bindgen emits.
- The release profile turns off overflow checks and debug assertions. This is accepted: `pnpm test:js` builds the
  WASM before testing, so every JS route-planner and German-frontend conformance test runs against the release
  modules. The native `cargo test` keeps the debug checks.

## 5. iOS demo tests in CI

- `swift.yml` gains an `xcodebuild test` step for `ios/SampleApps/IndeRunDemo/IndeRunDemo.xcodeproj`, scheme
  `IndeRunDemo`, on the first available iPhone simulator. Pick the simulator the same way the existing package
  simulator step does, next to the existing demo build step.
- `docs/ci.md` replaces the sentence that the demo tests are "neither built nor run" with a description of the step.
- The shared scheme's Test action already includes `IndeRunDemoTests`, and it needs no code signing on a simulator.
  If the first CI run exposes failing demo tests, fix them in this issue. Do not skip them.

## Constraints

- Parity: the same behaviour and the same fixtures on TS, Swift and Kotlin.
- TDD: every behaviour change starts with a test that is seen failing.
- Never hand-edit generated contracts. `pnpm generate` after the API JSON change.
- A route core change goes with the rebuilt Apple XCFrameworks and their provenance in the same commit.
- Timing assertions use fake or injected clocks, never exact wall-clock equality (the lesson of `fa228d8`).
- One squashed commit for the issue: `fix(speech): bound audio output waits, add close(), deflake tests, ship WASM
  release builds (#280)` or similar.

## Left to the builder

- Internal names of the injected clock/timer options and the fixture "stalled" mode.
- How each fixture service models a stall.
- The exact n per Rust scaling test, and the size budgets (first release build + headroom).
- Whether `write_fails_when_output_stalls` can be a shared case (see §1).
- The simulator selection snippet in `swift.yml`.
