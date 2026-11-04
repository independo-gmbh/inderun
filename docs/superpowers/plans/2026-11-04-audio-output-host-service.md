# Audio Output Host Service (PR 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every host an optional, uniformly specified way to play PCM — `HostServices.audioOutput` — with a default per platform, a recording fixture for tests, and one shared lifecycle catalog that pins what `open()`, `write()`, `drain()` and `stop()` guarantee, so the neural speech provider (PR 3) can stream synthesized audio through one seam on all three SDKs.

**Architecture:** Host services are hand-written per SDK, not schema contracts, so this PR adds three small type sets (`packages/contracts/src/host.ts`, `IndeRunCore/HostServices.swift`, `inderun-core/.../HostServices.kt`) with identical doc-comment semantics, and nothing is generated. Behaviour is pinned by a scenario catalog, `contracts/fixtures/host/audio-output-lifecycle.json`, in the shape of `execution/artifact-lifecycle.json`: one handler per case id behind a guard test, run against each SDK's fixture service on the JVM/node/macOS, and additionally against the real `AVAudioEngine` and `AudioTrack` services where a runner can. Defaults wrap Web Audio, `AVAudioEngine` and `AudioTrack`; none touches `AVAudioSession` or audio focus. No provider, engine or planner code changes; the absent-service refusal is PR 3's.

**Tech Stack:** TypeScript (Vitest, node, no DOM), Swift 5.9 SwiftPM + XCTest (macOS and iOS simulator), Kotlin/Gradle + JUnit 4/Robolectric and an instrumented androidTest, Web Audio API, AVFoundation, `android.media.AudioTrack`.

**Spec:** `docs/superpowers/specs/2026-11-04-neural-speech-design.md` (section B, "Audio output host service"; "Decisions" 4; "Risks": audio session ownership and the Web `AudioContext` gesture requirement)

## Global Constraints

- Hand-written types only. No schema under `contracts/schemas/`, no `pnpm generate`, no generated file changes.
- Additive on every SDK: `audioOutput` is optional; Swift appends `audioOutput: AudioOutputService? = nil` after `artifactDestinations` in `HostServices.init` and `DefaultHostServices.make`; Kotlin appends `val audioOutput: AudioOutputService? = null` last on the data class. Existing call sites compile unchanged.
- The semantic wording on the types is identical across the three SDKs (spec B lines 158-166, repeated verbatim in the doc comments); the catalog is the executable form of that wording.
- Shared format rule: `channels` is 1, `encoding` is `pcm_s16le`, `sampleRate` is 8000–48000 inclusive; a service may refuse further rates with the same `audio_format_unsupported` code.
- No `AVAudioSession` category or activation and no Android audio focus request anywhere in this PR (spec "Risks": the session stays app-owned; `AppleSpeechRuntime.swift:378-397` sets none today).
- `audio_output_unavailable` (host without the service) is raised by the provider in PR 3. This PR states the rule in ADR 021 and nowhere in code.
- No new dependency in any published module; `pnpm verify:android-api-deps` stays green. Consumer smoke-test targets gain no imports. `AVFoundation` is imported only inside `#if canImport(AVFoundation)` in `IndeRunCore`.
- Every wait in a test is bounded (the catalog carries `timeoutMs`); a real-engine run skips, never hangs or fails, on a runner without an output device or without rendering.
- Branch `feat/m5-audio-output-host-service` off `dev` after PR #269 has merged, PR into `dev`, Conventional Commits, trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` last.
- Prettier covers `ts/mjs/js`; the fixture JSON is hand-formatted 2-space; `swiftlint lint --strict` (`line_length` 140 is the effective hard limit; size rules are disabled in `ios/IndeRun/.swiftlint.yml`); `./gradlew spotlessApply` before every Kotlin commit.

## Review Focus

1. Nothing renders after `stop()`, and a `write()` blocked on backpressure is released by it — catalog cases `stop_discards_buffered_audio` and `write_after_stop_is_ignored` (Task 1; run on the fixtures in Tasks 1–3 and on the real engines in Tasks 5–6), `testEndWithoutErrorReleasesWaiters` (Task 5) and `stop stops every live source and settles drain and a waiting write` (Task 4).
2. `open()` is silent and never claims an audio context the page may not use: `open_makes_no_sound` (Task 1), `creates no AudioContext before the first open` and `refuses to open when the context stays suspended after resume` (Task 4); `createBrowserHostServices()` builds the service in node without touching `AudioContext` (Task 4).
3. `firstAudioMs()` is an observation, not a promise: undefined until `currentTime` passes the first scheduled start on the web (`firstAudioMs is undefined until currentTime passes the first start`, Task 4), the first rendered tap buffer after `play()` on Apple and the first marker on Android (`first_write_starts_playback`, Tasks 5–6), and always relative to `open()` (ADR 021 §3, Task 7).
4. Backpressure bounds memory: the web `write()` waits beyond `maxLeadSeconds` (Task 4), the Apple gate holds the fourth buffer (`testReserveWaitsWhenThreeBuffersAreInFlight`, Task 5), the Android blocking `write` runs off the caller's dispatcher and is unblocked by `stop()` (`stop_discards_buffered_audio` on the emulator, Task 6).
5. Refusals and interruptions carry the fixed codes: `unsupported_format_refused` is `CapabilityMismatch`/`audio_format_unsupported` on every service (Task 1), a suspended browser context is `Unavailable`/`audio_not_allowed` (Task 4), a configuration change ends an Apple session with `audio_output_interrupted` (`testInterruptionEndsPendingDrain`, Task 5).

---

### Task 1: Shared catalog, TypeScript types, fixture and catalog run

**Files:**
- Create: `contracts/fixtures/host/audio-output-lifecycle.json`
- Modify: `packages/contracts/src/host.ts` (new types after `ArtifactDestinationService`, line 193; `HostServices.audioOutput` after `artifactDestinations`, line 233)
- Modify: `packages/contracts/src/index.ts:121-135` (export list)
- Modify: `packages/inderun-web/src/core/host.ts` (re-export list)
- Modify: `packages/inderun-web/src/provider.ts:16-30` (host type block)
- Create: `packages/inderun-web/src/test/audio-output-fixture.ts`
- Create: `packages/inderun-web/src/core/audio-output.conformance.test.ts`
- Modify: `docs/speech-conformance.md:26` (new row) and `:32-33` (where the Kotlin suites live)

**Interfaces:**
- Produces (`packages/contracts/src/host.ts`):
  ```ts
  export interface AudioOutputFormat { sampleRate: number; channels: 1; encoding: "pcm_s16le" }
  export interface AudioOutputSession {
    write(samples: Int16Array): Promise<void>;
    drain(): Promise<void>;
    stop(): void;
    firstAudioMs(): number | undefined;
  }
  export interface AudioOutputService {
    open(format: AudioOutputFormat, signal?: AbortSignalLike): Promise<AudioOutputSession>;
  }
  // HostServices
  audioOutput?: AudioOutputService;
  ```
  Doc comments carry the semantics from spec B verbatim: `open()` makes no sound and validates the format; `write()` resolves once the host has buffered the samples (backpressure) and the first write is the first possible audible effect; `drain()` resolves when everything written has played; `stop()` ends the session now, discards buffered audio, releases the output, is idempotent, and nothing renders after it; the normal path is `drain()` then `stop()`; after `stop()`, `write()` and `drain()` return at once without effect; `firstAudioMs()` is milliseconds from `open()` to the first frame the host observed leaving the output, undefined until then; sessions of one service are independent. Plus the shared format rule. The `HostServices` comment mirrors `streamingHttpClient` (line 221-222): "PCM playback for providers that synthesize audio themselves. Absent on hosts that cannot play audio; such a provider refuses before commit."
- Produces (`packages/inderun-web/src/test/audio-output-fixture.ts`):
  ```ts
  export interface FixtureAudioOutputSession extends AudioOutputSession {
    readonly format: AudioOutputFormat;
    readonly writes: Int16Array[];
    readonly writtenFrames: number;
    readonly playedFrames: number;
    readonly discardedFrames: number;
    readonly playing: boolean;
    readonly stopped: boolean;
  }
  export interface FixtureAudioOutput {
    service: AudioOutputService;
    sessions: FixtureAudioOutputSession[];
    /** Virtual milliseconds; advanced only by drain(). */
    now(): number;
  }
  export function createFixtureAudioOutput(): FixtureAudioOutput;
  ```
  Clock model (the part the signature does not fix): `now()` starts at 0 and only `drain()` advances it, by the duration of the frames not yet played, moving `playedFrames` to `writtenFrames`; `stop()` moves unplayed frames to `discardedFrames` without advancing; `write()` after `stop()` is ignored; the first `write()` sets `firstAudioMs = now() − openedAt` and `playing = true`; `open()` applies the shared format rule and throws `createCapabilityMismatch(…, { details: { code: "audio_format_unsupported" } })`. This is what makes `drain_waits_for_everything_written` meaningful without wall time: elapsed on the fixture clock equals exactly the written audio.
- Consumes: `createCapabilityMismatch` from `packages/inderun-web/src/core/errors.ts`, `IndeRunException`.

- [ ] **Step 1: Write the catalog**

`contracts/fixtures/host/audio-output-lifecycle.json`, same top-level shape as `execution/artifact-lifecycle.json` (`$comment`, `$expectKeys`, `cases[]` with `id`, `description`, `setup`, `expect`). The `$comment` states: scenario catalog for ADR 021; `setup` is normative prose; every SDK runs it against its fixture service, Swift also against `AVAudioEngineAudioOutputService`, Android also against `AudioTrackAudioOutputService` on an emulator; unless the setup says otherwise the format is 24000 Hz, 1 channel, `pcm_s16le`, and written audio is a 440 Hz sine at −14 dBFS; elapsed times are read on the target's clock (the fixture's virtual clock or wall time for a real service); every wait is bounded by `timeoutMs`; what a listener hears is a manual check.

`$expectKeys`:

```json
"afterOpen": "State after open() and a 200 ms settle: 'firstAudioDefined' is whether firstAudioMs() returned a value.",
"afterWrites": "State after the writes, waiting up to 'waitAtMostMs' (default 0) for firstAudioMs(): 'firstAudioDefined'; 'firstAudioAtMostMs' bounds its value.",
"drain": "drain() after the writes: 'elapsedAtLeastMs' from before the first write to its resolution, on the target's clock; 'timeoutMs' bounds the wait.",
"stop": "stop(): 'throws' for every call, 'calls' how many were made, 'writeSettlesWithinMs' how soon a write that was in flight returns after it.",
"writeAfterStop": "A write() after stop(): 'elapsedAtMostMs' and 'throws'.",
"drainAfterStop": "A drain() after stop(): 'elapsedAtMostMs' and 'throws'.",
"independence": "Two sessions of one service: 'stoppedDrainAtMostMs' for the stopped one; 'otherDrainAtLeastMs' from before the other's first write to its drain; 'timeoutMs'.",
"openRejectsWith": "open() threw: the error class and details.code."
```

Cases (id, setup, expect):

| id | setup | expect |
| --- | --- | --- |
| `open_makes_no_sound` | open(); settle 200 ms; read firstAudioMs(); stop() | `afterOpen: { firstAudioDefined: false }` |
| `first_write_starts_playback` | open(); read firstAudioMs(); write(200 ms); wait up to 2000 ms for firstAudioMs(); drain(); stop() | `afterOpen: { firstAudioDefined: false }`, `afterWrites: { firstAudioDefined: true, waitAtMostMs: 2000, firstAudioAtMostMs: 2000 }` |
| `drain_waits_for_everything_written` | open(); write(200 ms) twice; drain(); stop() | `drain: { elapsedAtLeastMs: 320, timeoutMs: 3000 }` |
| `stop_discards_buffered_audio` | open(); start write(3000 ms) without awaiting; settle 100 ms; stop(); await the write; drain() | `stop: { throws: false, writeSettlesWithinMs: 500 }`, `drainAfterStop: { elapsedAtMostMs: 50, throws: false }` |
| `stop_is_idempotent` | open(); write(200 ms); stop() twice; drain() | `stop: { throws: false, calls: 2 }`, `drainAfterStop: { elapsedAtMostMs: 50, throws: false }` |
| `write_after_stop_is_ignored` | open(); stop(); write(200 ms); settle 300 ms; read firstAudioMs() | `writeAfterStop: { elapsedAtMostMs: 50, throws: false }`, `afterWrites: { firstAudioDefined: false }` |
| `drain_after_stop_resolves_at_once` | open(); write(200 ms); stop(); drain() | `drainAfterStop: { elapsedAtMostMs: 50, throws: false }` |
| `sessions_are_independent` | open() A and B; write(1000 ms) to A then B; stop() A; drain() A; drain() B | `independence: { stoppedDrainAtMostMs: 50, otherDrainAtLeastMs: 800, timeoutMs: 4000 }` |
| `unsupported_format_refused` | open() with sampleRate 4000 | `openRejectsWith: { errorClass: "CapabilityMismatch", code: "audio_format_unsupported" }` |

The 320/800 thresholds are 0.8 of the written audio: a real engine starts a few ms after the first write and reports played-back a few ms late, and the fixture reports exactly 400/1000.

- [ ] **Step 2: Write the failing TypeScript catalog test**

`packages/inderun-web/src/core/audio-output.conformance.test.ts`, mirroring `artifacts.conformance.test.ts:79-87` (load with `readFileSync` from `../../../../contracts/fixtures/host/audio-output-lifecycle.json`) and `:588-598` (guard plus one `it` per case):

```ts
interface Target { service: AudioOutputService; now(): number }
interface Observation {
  firstAudioDefinedAfterOpen?: boolean;
  firstAudioDefinedAfterWrites?: boolean;
  firstAudioMs?: number;
  drainElapsedMs?: number;
  stopThrew?: boolean;
  stopCalls?: number;
  writeSettledAfterStopMs?: number;
  writeAfterStopElapsedMs?: number;
  writeAfterStopThrew?: boolean;
  drainAfterStopElapsedMs?: number;
  drainAfterStopThrew?: boolean;
  stoppedDrainElapsedMs?: number;
  otherDrainElapsedMs?: number;
  openRejection?: IndeRunException;
}
const format: AudioOutputFormat = { sampleRate: 24000, channels: 1, encoding: "pcm_s16le" };
/** 440 Hz at -14 dBFS. */
function tone(ms: number, sampleRate = format.sampleRate): Int16Array { … }
function settle(ms: number): Promise<void> { … }            // wall time
function bounded<T>(p: Promise<T>, ms: number, label: string): Promise<T> { … }

const handlers: Record<string, (target: Target) => Promise<Observation>> = {
  async open_makes_no_sound({ service }) {
    const session = await service.open(format);
    await settle(200);
    const firstAudioDefinedAfterOpen = session.firstAudioMs() !== undefined;
    session.stop();
    return { firstAudioDefinedAfterOpen };
  },
  async drain_waits_for_everything_written({ service, now }) {
    const session = await service.open(format);
    const from = now();
    await session.write(tone(200));
    await session.write(tone(200));
    await bounded(session.drain(), 3000, "drain");
    const drainElapsedMs = now() - from;
    session.stop();
    return { drainElapsedMs };
  },
  async stop_discards_buffered_audio({ service, now }) {
    const session = await service.open(format);
    const inFlight = session.write(tone(3000));
    await settle(100);
    let stopThrew = false;
    try { session.stop(); } catch { stopThrew = true; }
    const stoppedAt = now();
    await bounded(inFlight, 1000, "in-flight write");
    const writeSettledAfterStopMs = now() - stoppedAt;
    const drainFrom = now();
    await bounded(session.drain(), 1000, "drain after stop");
    return { stopThrew, writeSettledAfterStopMs, drainAfterStopElapsedMs: now() - drainFrom, drainAfterStopThrew: false };
  },
  // … one handler per remaining id in the same vocabulary
};

async function assertCase(expected: Expectations, observed: Observation): Promise<void> {
  if (expected.afterOpen) expect(observed.firstAudioDefinedAfterOpen).toBe(expected.afterOpen.firstAudioDefined);
  if (expected.afterWrites) {
    expect(observed.firstAudioDefinedAfterWrites).toBe(expected.afterWrites.firstAudioDefined);
    if (expected.afterWrites.firstAudioAtMostMs !== undefined)
      expect(observed.firstAudioMs).toBeLessThanOrEqual(expected.afterWrites.firstAudioAtMostMs);
  }
  if (expected.drain) expect(observed.drainElapsedMs).toBeGreaterThanOrEqual(expected.drain.elapsedAtLeastMs);
  if (expected.stop) { expect(observed.stopThrew).toBe(expected.stop.throws); /* calls, writeSettlesWithinMs */ }
  if (expected.openRejectsWith) {
    expect(observed.openRejection).toBeInstanceOf(IndeRunException);
    expect(observed.openRejection!.errorClass).toBe(expected.openRejectsWith.errorClass);
    expect(observed.openRejection!.details?.["code"]).toBe(expected.openRejectsWith.code);
  }
  // … writeAfterStop, drainAfterStop, independence
}

describe("audio output conformance", () => {
  it("implements every case in the shared catalog, and no others", () => {
    expect(Object.keys(handlers).sort()).toEqual(catalog.cases.map((entry) => entry.id).sort());
  });
  describe("fixture service", () => {
    for (const catalogCase of catalog.cases) {
      it(catalogCase.id, async () => {
        const fixture = createFixtureAudioOutput();
        await assertCase(catalogCase.expect, await handlers[catalogCase.id]!({ service: fixture.service, now: fixture.now }));
      });
    }
  });
});
```

`first_write_starts_playback` polls `firstAudioMs()` every 10 ms up to `waitAtMostMs`; the fixture defines it on the first write, so the poll returns at once.

- [ ] **Step 3: Run it to verify it fails**

Run: `pnpm --filter @independo/inderun-web test -- audio-output`
Expected: FAIL — `Cannot find module '../test/audio-output-fixture.js'`, and the type-check of the test reports `AudioOutputService` is not exported by `@independo/inderun-contracts`.

- [ ] **Step 4: Add the types and exports**

In `packages/contracts/src/host.ts`, after line 193, add `AudioOutputFormat`, `AudioOutputSession`, `AudioOutputService` with the doc comments above; add `audioOutput?: AudioOutputService` after line 233. Add the three names to the `export type` list at `packages/contracts/src/index.ts:121-135`, to `packages/inderun-web/src/core/host.ts`, and to the host block of `packages/inderun-web/src/provider.ts:16-30`.

- [ ] **Step 5: Write the fixture**

`packages/inderun-web/src/test/audio-output-fixture.ts` as specified in Interfaces. One closure-held `clock` per fixture; each session is a small class with private counters and public readonly getters.

- [ ] **Step 6: Run the tests**

Run: `pnpm --filter @independo/inderun-contracts build && pnpm --filter @independo/inderun-web test -- audio-output && pnpm --filter @independo/inderun-web typecheck`
Expected: PASS — the guard and the nine fixture cases.

- [ ] **Step 7: Add the conformance row**

`docs/speech-conformance.md`: after line 26 add

`| [`host/audio-output-lifecycle.json`](../contracts/fixtures/host/audio-output-lifecycle.json) | Scenario catalog: what the audio output host service guarantees at open, write, drain and stop | `packages/inderun-web/src/core/audio-output.conformance.test.ts` (fixture), `AudioOutputLifecycleConformanceTests.swift` (fixture and `AVAudioEngine`), `AudioOutputLifecycleConformanceTest.kt` (fixture), `AudioTrackAudioOutputConformanceTest.kt` (real `AudioTrack`, instrumented) |`

and extend lines 32-33: the corpus test and the `AudioTrack` catalog run are instrumented.

- [ ] **Step 8: Commit**

```bash
git add contracts/fixtures/host packages/contracts/src/host.ts packages/contracts/src/index.ts packages/inderun-web/src/core/host.ts packages/inderun-web/src/provider.ts packages/inderun-web/src/test/audio-output-fixture.ts packages/inderun-web/src/core/audio-output.conformance.test.ts docs/speech-conformance.md
git commit -m "feat(contracts): add the audio output host service with a shared lifecycle catalog"
```

---

### Task 2: Swift types, fixture and catalog run

**Files:**
- Modify: `ios/IndeRun/Sources/IndeRunCore/HostServices.swift` (types after `ArtifactDestinationService`, line 109; struct and init at lines 112-145)
- Create: `ios/IndeRun/Tests/IndeRunTests/FixtureAudioOutput.swift`
- Create: `ios/IndeRun/Tests/IndeRunTests/AudioOutputLifecycleConformanceTests.swift`

**Interfaces:**
- Produces (`HostServices.swift`):
  ```swift
  public enum AudioOutputEncoding: String, Sendable { case pcmS16le = "pcm_s16le" }
  public struct AudioOutputFormat: Sendable, Equatable {
      public let sampleRate: Int
      public let channels: Int
      public let encoding: AudioOutputEncoding
      public init(sampleRate: Int, channels: Int = 1, encoding: AudioOutputEncoding = .pcmS16le)
  }
  public protocol AudioOutputSession: Sendable {
      func write(_ samples: [Int16]) async throws
      func drain() async throws
      func stop()
      func firstAudioMs() -> Double?
  }
  public protocol AudioOutputService: Sendable {
      func open(format: AudioOutputFormat) async throws -> any AudioOutputSession
  }
  // HostServices: public let audioOutput: AudioOutputService?  (init parameter appended, default nil)
  ```
  Cancellation: the doc comment on `open`/`write`/`drain` says they honour `Task` cancellation like `HttpStreamingClientService.stream(request:)` (line 83-92), and that a provider's cancel path is `stop()`.
- Produces (test target): `final class FixtureAudioOutputService: AudioOutputService, @unchecked Sendable { var sessions: [FixtureAudioOutputSession]; func now() -> Double }` and `final class FixtureAudioOutputSession: AudioOutputSession, @unchecked Sendable` with `format`, `writes: [[Int16]]`, `writtenFrames`, `playedFrames`, `discardedFrames`, `playing`, `stopped`, same clock model as the TS fixture, guarded by an `NSLock` as `RecordingDestinations` is (`ArtifactLifecycleConformanceTests.swift:515-570`).
- Produces (test): `struct AudioOutputTarget { let service: any AudioOutputService; let now: @Sendable () -> Double }`, `private typealias Handler = (AudioOutputTarget) async throws -> Observation`, `private func run(_ target: AudioOutputTarget, label: String) async throws` that loops the catalog and calls `check(label:expected:observed:)`.
- Consumes: `createCapabilityMismatch(message:details:)` (`Errors.swift:71`), `JSONAny`.

- [ ] **Step 1: Write the failing tests**

`AudioOutputLifecycleConformanceTests.swift`, loading the catalog through `repositoryRoot()` as `ArtifactLifecycleConformanceTests.swift:91-105` does, with `Decodable` `Expectations` mirroring the `$expectKeys`:

```swift
func testImplementsEveryCaseInTheSharedCatalogAndNoOthers() throws {
    let catalogIds = try loadCatalog().cases.map(\.id).sorted()
    XCTAssertFalse(catalogIds.isEmpty)
    XCTAssertEqual(Set(catalogIds).count, catalogIds.count, "duplicate case id in the catalog")
    XCTAssertEqual(handlers.keys.sorted(), catalogIds)
}

func testFixtureMatchesTheSharedCatalog() async throws {
    let fixture = FixtureAudioOutputService()
    try await run(AudioOutputTarget(service: fixture, now: { fixture.now() }), label: "fixture")
}
```

`run` fails with `XCTFail("\(label)/\(case.id): …")` per mismatch, as `check` does in the artifact suite (`:378-504`). Handlers are the Swift spelling of Task 1's (`tone(ms:)` returns `[Int16]`, `settle` is `Task.sleep`, `bounded` is a `withThrowingTaskGroup` race against a sleep that throws).

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter AudioOutputLifecycleConformanceTests`
Expected: compile error — `cannot find type 'AudioOutputService' in scope`.

- [ ] **Step 3: Add the types**

Append the enum, struct and two protocols after line 109 of `HostServices.swift`; add `public let audioOutput: AudioOutputService?` after `artifactDestinations` (line 124) with the same comment as the TS type; append `audioOutput: AudioOutputService? = nil` to the init (line 134) and the assignment.

- [ ] **Step 4: Write the fixture**

`FixtureAudioOutput.swift` in the test target as specified in Interfaces.

- [ ] **Step 5: Run the tests**

Run: `swift test --filter AudioOutputLifecycleConformanceTests && swift test --filter IndeRunTests`
Expected: PASS; every existing `HostServices(connectivity:clock:)` and `DefaultHostServices.make()` call still compiles.

- [ ] **Step 6: Lint and commit**

Run: `(cd ios/IndeRun && swiftlint lint --strict)`
Expected: no violations.

```bash
git add ios/IndeRun/Sources/IndeRunCore/HostServices.swift ios/IndeRun/Tests/IndeRunTests/FixtureAudioOutput.swift ios/IndeRun/Tests/IndeRunTests/AudioOutputLifecycleConformanceTests.swift
git commit -m "feat(core): add AudioOutputService to the Swift host services"
```

---

### Task 3: Kotlin types, fixture, `sharedTest` source directory and catalog run (unit)

**Files:**
- Modify: `android/inderun-core/src/main/kotlin/app/independo/inderun/core/HostServices.kt` (types after `ArtifactDestinationService`, line 132; data class at lines 159-175)
- Modify: `android/inderun-kotlin/build.gradle.kts:16-33` (`sourceSets` for `test` and `androidTest`)
- Create: `android/inderun-kotlin/src/sharedTest/kotlin/app/independo/inderun/sdk/FixtureAudioOutput.kt`
- Create: `android/inderun-kotlin/src/sharedTest/kotlin/app/independo/inderun/sdk/AudioOutputLifecycleCatalog.kt`
- Create: `android/inderun-kotlin/src/test/kotlin/app/independo/inderun/sdk/AudioOutputLifecycleConformanceTest.kt`

**Interfaces:**
- Produces (`HostServices.kt`):
  ```kotlin
  enum class AudioOutputEncoding(val rawValue: String) { PcmS16le("pcm_s16le") }
  data class AudioOutputFormat(
      val sampleRate: Int,
      val channels: Int = 1,
      val encoding: AudioOutputEncoding = AudioOutputEncoding.PcmS16le,
  )
  interface AudioOutputSession {
      suspend fun write(samples: ShortArray)
      suspend fun drain()
      fun stop()
      fun firstAudioMs(): Double?
  }
  interface AudioOutputService {
      suspend fun open(format: AudioOutputFormat): AudioOutputSession
  }
  // HostServices: val audioOutput: AudioOutputService? = null   (appended last)
  ```
- Produces (`sharedTest`):
  ```kotlin
  internal class FixtureAudioOutputService : AudioOutputService {
      val sessions: List<FixtureAudioOutputSession>
      fun now(): Double
  }
  internal class FixtureAudioOutputSession(val format: AudioOutputFormat, …) : AudioOutputSession {
      val writes: List<ShortArray>; val writtenFrames: Long; val playedFrames: Long
      val discardedFrames: Long; val playing: Boolean; val stopped: Boolean
  }
  internal class AudioOutputTarget(val service: AudioOutputService, val now: () -> Double)
  internal class AudioOutputObservation(/* the Task 1 fields as nullable vals */)
  internal val audioOutputHandlers: Map<String, suspend (AudioOutputTarget) -> AudioOutputObservation>
  internal fun audioOutputCatalogCases(json: String): List<JSONObject>
  internal fun checkAudioOutputCase(label: String, expected: JSONObject, observed: AudioOutputObservation): List<String>
  internal suspend fun runAudioOutputCatalog(json: String, target: AudioOutputTarget, ids: Set<String>? = null): List<String>
  ```
  The catalog is handed in as a string so the unit test can read the repository file and the instrumented test an asset (Task 6). `runAudioOutputCatalog` returns the failure list, in the style of `checkArtifactCase` (`ArtifactLifecycleConformanceTest.kt`).
- Consumes: `createCapabilityMismatch(message, details = …)` (`Errors.kt:49`), `org.json` (Robolectric on the JVM).

- [ ] **Step 1: Write the failing tests**

`AudioOutputLifecycleConformanceTest.kt` (Robolectric, like the artifact suite):

```kotlin
@RunWith(RobolectricTestRunner::class)
class AudioOutputLifecycleConformanceTest {
    private fun catalogJson(): String = /* walk up from File("").absoluteFile to contracts/fixtures/host/audio-output-lifecycle.json */

    @Test
    fun implementsEveryCaseInTheSharedCatalogAndNoOthers() {
        val catalogIds = audioOutputCatalogCases(catalogJson()).map { it.getString("id") }.sorted()
        assertTrue(catalogIds.isNotEmpty())
        assertEquals(catalogIds, audioOutputHandlers.keys.sorted())
    }

    @Test
    fun fixtureMatchesTheSharedCatalog() = runTest {
        val fixture = FixtureAudioOutputService()
        val failures = runAudioOutputCatalog(catalogJson(), AudioOutputTarget(fixture) { fixture.now() })
        assertTrue("Conformance failures:\n${failures.joinToString("\n")}", failures.isEmpty())
    }
}
```

Under `runTest` the handlers' `delay`-based settles are virtual and instant; the elapsed figures come from the target's clock, so the fixture reports exactly 400 and 1000 ms for the drain cases.

- [ ] **Step 2: Run them to verify they fail**

Run: `cd android && ./gradlew :inderun-kotlin:testDebugUnitTest --tests "app.independo.inderun.sdk.AudioOutputLifecycleConformanceTest"`
Expected: FAIL — `Unresolved reference: AudioOutputService` (and the `sharedTest` files are not on the source set yet).

- [ ] **Step 3: Add the types and the source directory**

Append the enum, data class and two interfaces after line 132 of `HostServices.kt`; append `val audioOutput: AudioOutputService? = null` with the TS doc comment to the data class. In `android/inderun-kotlin/build.gradle.kts`, inside `android { }`:

```kotlin
// Catalog handlers shared by the JVM and the instrumented audio output runs.
sourceSets {
    getByName("test") { kotlin.srcDir("src/sharedTest/kotlin") }
    getByName("androidTest") { kotlin.srcDir("src/sharedTest/kotlin") }
}
```

No publishing impact: neither source set reaches the AAR.

- [ ] **Step 4: Write the fixture and the catalog**

`FixtureAudioOutput.kt` and `AudioOutputLifecycleCatalog.kt` as in Interfaces; `tone(ms)` returns a `ShortArray`, `settle` is `delay`, `bounded` is `withTimeoutOrNull` with a failure string on null.

- [ ] **Step 5: Run the tests**

Run: `cd android && ./gradlew spotlessApply && ./gradlew :inderun-kotlin:testDebugUnitTest --tests "app.independo.inderun.sdk.AudioOutputLifecycleConformanceTest" && ./gradlew :inderun-core:testDebugUnitTest`
Expected: PASS; the existing `conformanceHostServices()` and every `HostServices(...)` construction compile unchanged.

- [ ] **Step 6: Commit**

```bash
git add android/inderun-core/src/main/kotlin/app/independo/inderun/core/HostServices.kt android/inderun-kotlin/build.gradle.kts android/inderun-kotlin/src/sharedTest android/inderun-kotlin/src/test/kotlin/app/independo/inderun/sdk/AudioOutputLifecycleConformanceTest.kt
git commit -m "feat(core): add AudioOutputService to the Kotlin host services"
```

---

### Task 4: Web default service, wiring, exports and unit tests

**Files:**
- Create: `packages/inderun-web/src/core/browser-audio-output.ts`
- Create: `packages/inderun-web/src/core/browser-audio-output.test.ts`
- Modify: `packages/inderun-web/src/core/browser-host.ts:289-295` (options) and `:302-339` (factory)
- Modify: `packages/inderun-web/src/core/browser-host.test.ts` (two wiring tests)
- Modify: `packages/inderun-web/src/provider.ts:36-44` (browser implementations block)

**Interfaces:**
- Produces:
  ```ts
  /** The slice of AudioContext the service uses; a real AudioContext satisfies it. */
  export interface WebAudioContextLike {
    readonly state: "suspended" | "running" | "closed";
    readonly currentTime: number;
    readonly sampleRate: number;
    readonly baseLatency?: number;
    readonly outputLatency?: number;
    readonly destination: unknown;
    resume(): Promise<void>;
    createBuffer(numberOfChannels: number, length: number, sampleRate: number): WebAudioBufferLike;
    createBufferSource(): WebAudioSourceLike;
  }
  export interface WebAudioBufferLike { readonly duration: number; readonly sampleRate: number; getChannelData(channel: number): Float32Array }
  export interface WebAudioSourceLike {
    buffer: WebAudioBufferLike | null;
    onended: (() => void) | null;
    connect(destination: unknown): unknown;
    start(when?: number): void;
    stop(when?: number): void;
  }
  export interface CreateWebAudioOutputServiceOptions {
    /** Defaults to `() => new AudioContext()`; called once, on the first open(). */
    audioContext?: () => WebAudioContextLike;
    /** Scheduled audio a write() may run ahead of currentTime before it waits. Default 1.0. */
    maxLeadSeconds?: number;
    /** How long open() waits for resume() before reporting audio_not_allowed. Default 500. */
    resumeTimeoutMs?: number;
  }
  export function createWebAudioOutputService(options?: CreateWebAudioOutputServiceOptions): AudioOutputService;
  ```
- Produces: `CreateBrowserHostServicesOptions` already covers `audioOutput` through `Partial<HostServices>`; `createBrowserHostServices` sets `hostServices.audioOutput = options.audioOutput ?? createWebAudioOutputService()`.
- Produces (`provider.ts:36-44`): `createWebAudioOutputService`, `type CreateWebAudioOutputServiceOptions`, `type WebAudioContextLike`.
- Consumes: `createUnavailable`, `createCapabilityMismatch` (`errors.ts:172`, and the sibling), `AbortSignalLike`.

Scheduling rules (what the signature does not fix, from the design): one lazily created context per service, never closed; `open()` applies the shared format rule first, then creates the context, then if `state !== "running"` races `resume()` against the signal and `resumeTimeoutMs` and throws `audio_not_allowed` when still not running; a throwing factory is `audio_output_failed`; `write()` converts Int16 to Float32 (`sample / 32768`) into a buffer at `format.sampleRate`, starts a source at `nextStartTime = max(nextStartTime, currentTime + 0.02)` and advances `nextStartTime` by the buffer duration; after scheduling, while `nextStartTime − currentTime > maxLeadSeconds` it waits for the earliest live source's `onended` and re-checks before resolving; `drain()` resolves on the last started source's `onended` or at once; `stop()` clears waiters, stops every live source, marks stopped; `firstAudioMs()` is `(firstStart + (outputLatency ?? baseLatency ?? 0) − openedAtContextTime) × 1000` once `currentTime >= firstStart`. The doc comment says the web value is scheduled time plus reported output latency, not an observed frame. On abort during `open()`, reject the way `FetchStreamingHttpClient` rejects on abort.

- [ ] **Step 1: Write the failing tests**

`browser-audio-output.test.ts` with a fake:

```ts
function fakeAudioContext(options: {
  state?: "suspended" | "running";
  resume?: () => Promise<void>;          // default: sets state to "running"
  baseLatency?: number; outputLatency?: number; sampleRate?: number;
} = {}) {
  const sources: FakeSource[] = [];       // { startedAt, stopCalls, buffer, onended, end() }
  const context = { state, currentTime: 0, sampleRate: 48000, baseLatency, outputLatency, destination: {},
    resume, createBuffer(c, length, rate) { … }, createBufferSource() { … } } as WebAudioContextLike & { currentTime: number };
  return { context, sources, advance(seconds: number) { context.currentTime = seconds; } };
}
const format = { sampleRate: 24000, channels: 1, encoding: "pcm_s16le" } as const;

it("creates no AudioContext before the first open", async () => {
  const factory = vi.fn(() => fakeAudioContext({ state: "running" }).context);
  const service = createWebAudioOutputService({ audioContext: factory });
  expect(factory).not.toHaveBeenCalled();
  await service.open(format);
  await service.open(format);
  expect(factory).toHaveBeenCalledTimes(1);
});

it("refuses an unsupported format before touching the context", async () => {
  const factory = vi.fn();
  await expect(createWebAudioOutputService({ audioContext: factory }).open({ ...format, sampleRate: 4000 }))
    .rejects.toMatchObject({ errorClass: "CapabilityMismatch", details: { code: "audio_format_unsupported" } });
  expect(factory).not.toHaveBeenCalled();
});

it("reports audio_output_failed when the context cannot be created", async () => {
  const service = createWebAudioOutputService({ audioContext: () => { throw new ReferenceError("AudioContext is not defined"); } });
  await expect(service.open(format)).rejects.toMatchObject({ errorClass: "Unavailable", details: { code: "audio_output_failed" } });
});

it("refuses to open when the context stays suspended after resume", async () => {
  const resume = vi.fn(async () => {});
  const { context } = fakeAudioContext({ state: "suspended", resume });
  await expect(createWebAudioOutputService({ audioContext: () => context }).open(format))
    .rejects.toMatchObject({ errorClass: "Unavailable", details: { code: "audio_not_allowed" } });
  expect(resume).toHaveBeenCalledTimes(1);
});

it("refuses to open when resume() does not settle within the timeout", async () => {
  const { context } = fakeAudioContext({ state: "suspended", resume: () => new Promise(() => {}) });
  await expect(createWebAudioOutputService({ audioContext: () => context, resumeTimeoutMs: 20 }).open(format))
    .rejects.toMatchObject({ details: { code: "audio_not_allowed" } });
});

it("rejects open when the signal aborts while resuming", async () => {
  const controller = new AbortController();
  const { context } = fakeAudioContext({ state: "suspended", resume: () => new Promise(() => {}) });
  const opening = createWebAudioOutputService({ audioContext: () => context }).open(format, controller.signal);
  controller.abort();
  await expect(opening).rejects.toMatchObject({ name: "AbortError" });   // or whatever FetchStreamingHttpClient throws on abort
});

it("makes no sound at open", async () => {
  const { context, sources } = fakeAudioContext({ state: "running" });
  const session = await createWebAudioOutputService({ audioContext: () => context }).open(format);
  expect(sources).toHaveLength(0);
  expect(session.firstAudioMs()).toBeUndefined();
});

it("schedules writes back to back from 20 ms ahead at the session sample rate", async () => {
  const fake = fakeAudioContext({ state: "running", sampleRate: 48000 });
  fake.advance(1.0);
  const session = await createWebAudioOutputService({ audioContext: () => fake.context }).open(format);
  await session.write(Int16Array.from({ length: 4800 }, () => 16384));   // 0.2 s
  await session.write(new Int16Array(2400));                              // 0.1 s
  expect(fake.sources.map((s) => s.startedAt)).toEqual([1.02, 1.22]);
  expect(fake.sources[0]!.buffer.sampleRate).toBe(24000);
  expect(fake.sources[0]!.buffer.getChannelData(0)[0]).toBeCloseTo(0.5);
});

it("waits in write once the scheduled lead exceeds maxLeadSeconds", async () => {
  const fake = fakeAudioContext({ state: "running" });
  const session = await createWebAudioOutputService({ audioContext: () => fake.context, maxLeadSeconds: 1 }).open(format);
  await session.write(new Int16Array(14400));            // 0.6 s, lead 0.62
  let settled = false;
  const second = session.write(new Int16Array(14400)).then(() => { settled = true; });  // lead 1.22 > 1
  await Promise.resolve(); await Promise.resolve();
  expect(settled).toBe(false);
  fake.advance(0.62); fake.sources[0]!.end();
  await second;
  expect(settled).toBe(true);
});

it("drain resolves when the last started source has ended", async () => { /* two writes; end source 0 → pending; end source 1 → resolved */ });
it("drain resolves at once when nothing was written", async () => { … });

it("stop stops every live source and settles drain and a waiting write", async () => {
  // two writes of 0.6 s, maxLeadSeconds 1 → third write pending; drain pending
  session.stop();
  await Promise.all([pendingWrite, pendingDrain]);
  expect(fake.sources.map((s) => s.stopCalls)).toEqual([1, 1]);
  await session.write(new Int16Array(240));
  expect(fake.sources).toHaveLength(2);
  session.stop();
  expect(fake.sources.map((s) => s.stopCalls)).toEqual([1, 1]);
});

it("firstAudioMs is undefined until currentTime passes the first start", async () => {
  const fake = fakeAudioContext({ state: "running", baseLatency: 0.01 });
  fake.advance(1.0);
  const session = await createWebAudioOutputService({ audioContext: () => fake.context }).open(format);
  await session.write(new Int16Array(2400));
  expect(session.firstAudioMs()).toBeUndefined();
  fake.advance(1.03);
  expect(session.firstAudioMs()).toBeCloseTo(30);   // (1.02 + 0.01 − 1.0) × 1000
});

it("prefers outputLatency over baseLatency", async () => { /* outputLatency 0.05 → 70 */ });
```

In `browser-host.test.ts`:

```ts
describe("createBrowserHostServices", () => {
  const connectivity = { async isOnline() { return true; } };
  it("includes an audio output service without touching AudioContext", () => {
    expect(createBrowserHostServices({ connectivity }).audioOutput).toBeDefined();   // node has no AudioContext: eager construction would throw
  });
  it("keeps a supplied audio output service", () => {
    const audioOutput = createFixtureAudioOutput().service;
    expect(createBrowserHostServices({ connectivity, audioOutput }).audioOutput).toBe(audioOutput);
  });
});
```

- [ ] **Step 2: Run them to verify they fail**

Run: `pnpm --filter @independo/inderun-web test -- browser-audio-output browser-host`
Expected: FAIL — `Cannot find module './browser-audio-output.js'`; `audioOutput` undefined on the host bundle.

- [ ] **Step 3: Implement the service and wire it**

`browser-audio-output.ts` per Interfaces. `createBrowserHostServices`: after the streaming client block (line 324), `hostServices.audioOutput = options.audioOutput ?? createWebAudioOutputService();`. Export from `provider.ts`.

- [ ] **Step 4: Run the tests**

Run: `pnpm --filter @independo/inderun-web test && pnpm --filter @independo/inderun-web typecheck && pnpm --filter @independo/inderun-web lint`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/inderun-web/src/core/browser-audio-output.ts packages/inderun-web/src/core/browser-audio-output.test.ts packages/inderun-web/src/core/browser-host.ts packages/inderun-web/src/core/browser-host.test.ts packages/inderun-web/src/provider.ts
git commit -m "feat(web): play PCM through Web Audio as the default audio output"
```

---

### Task 5: Apple default service, wiring and the real-engine catalog run

**Files:**
- Create: `ios/IndeRun/Sources/IndeRunCore/AudioOutputGate.swift`
- Create: `ios/IndeRun/Sources/IndeRunCore/AVAudioEngineAudioOutputService.swift`
- Modify: `ios/IndeRun/Sources/IndeRunCore/AppleHostServices.swift:245-267`
- Create: `ios/IndeRun/Tests/IndeRunTests/AudioOutputGateTests.swift`
- Modify: `ios/IndeRun/Tests/IndeRunTests/AudioOutputLifecycleConformanceTests.swift` (real-engine run)
- Test: `ios/IndeRun/Tests/IndeRunTests/IndeRunTests.swift` (one `DefaultHostServices` assertion)

**Interfaces:**
- Produces:
  ```swift
  /// Counts scheduled and played-back buffers for one session and parks writers and drainers.
  actor AudioOutputGate {
      init(limit: Int = 3)
      /// Returns once fewer than `limit` buffers are in flight; at once after `end`.
      func reserve() async throws
      func markScheduled()
      func markPlayedBack()
      /// Returns once played == scheduled; at once after `end`.
      func awaitDrained() async throws
      /// Settles every waiter: throwing `error` when given, returning otherwise. Idempotent.
      func end(_ error: IndeRunException?)
  }

  #if canImport(AVFoundation)
  public final class AVAudioEngineAudioOutputService: AudioOutputService {
      public init()
      public func open(format: AudioOutputFormat) async throws -> any AudioOutputSession
  }
  final class AVAudioEngineAudioOutputSession: AudioOutputSession, @unchecked Sendable {
      let engine: AVAudioEngine        // internal, read by the interruption test
      func write(_ samples: [Int16]) async throws
      func drain() async throws
      func stop()
      func firstAudioMs() -> Double?
  }
  #endif
  ```
- Produces: `DefaultHostServices.make(…, artifactDestinations: ArtifactDestinationService? = nil, audioOutput: AudioOutputService? = AVAudioEngineAudioOutputService())`.
- Consumes: `createUnavailable(message:details:)` (`Errors.swift:166`), `createCapabilityMismatch`, `JSONAny`, the `AudioOutputFormat` rule from Task 2.

Session behaviour the signatures leave open: one `AVAudioEngine` and `AVAudioPlayerNode` per session, connected to `mainMixerNode` with `AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)`; `open()` applies the format rule, `prepare()`s and `start()`s the engine (no sound: the player is not playing), mapping a thrown `start()` to `audio_output_failed`; `write()` converts to Float32 into an `AVAudioPCMBuffer`, `reserve()`s the gate, schedules with `completionCallbackType: .dataPlayedBack` (one completion type per scheduled buffer serves both the in-flight budget and `drain()`); the first `write()` installs the tap on the player node (`installTap(onBus: 0, …)`) immediately before calling `play()` — not at `open()`, because a tap on a non-playing node would see silence buffers and define `firstAudioMs` before any write — and the tap records the wall-clock time of the first rendered buffer with `frameLength > 0`, then is removed; `drain()` is `awaitDrained()`; `stop()` removes the tap, `player.stop()`, `engine.stop()`, `end(nil)`, idempotent; an `.AVAudioEngineConfigurationChange` observer for this engine calls `end(createUnavailable(…, details: ["code": JSONAny("audio_output_interrupted")]))` and stops. `AVAudioSession` is never touched.

- [ ] **Step 1: Write the failing gate tests**

```swift
final class AudioOutputGateTests: XCTestCase {
    func testReserveWaitsWhenThreeBuffersAreInFlight() async throws {
        let gate = AudioOutputGate(limit: 3)
        for _ in 0 ..< 3 { try await gate.reserve(); await gate.markScheduled() }
        let fourth = Task { try await gate.reserve(); return true }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(fourth.isCancelled)                       // still parked
        await gate.markPlayedBack()
        XCTAssertTrue(try await fourth.value)
    }
    func testAwaitDrainedReturnsWhenPlayedEqualsScheduled() async throws { /* two scheduled; drained resolves after the second markPlayedBack */ }
    func testEndWithErrorThrowsInPendingWaiters() async throws {
        // a parked reserve() and a parked awaitDrained() both throw Unavailable / audio_output_interrupted
    }
    func testEndWithoutErrorReleasesWaiters() async throws { … }
    func testReserveAndAwaitDrainedReturnAtOnceAfterEnd() async throws { … }
}
```

The "still parked" check uses a bounded poll on a flag set after `reserve()` returns, as `waitUntilWriteStarted` does (`ArtifactLifecycleConformanceTests.swift:542-546`).

- [ ] **Step 2: Write the failing real-engine tests**

In `AudioOutputLifecycleConformanceTests.swift`:

```swift
/// Opens the real service, writes 200 ms and waits up to 2 s for firstAudioMs(); skips when the host
/// cannot open an output (audio_output_failed) or renders nothing (no first audio).
private func probeRealEngine() async throws -> AVAudioEngineAudioOutputService { … XCTSkip … }

func testAVAudioEngineMatchesTheSharedCatalog() async throws {
    let service = try await probeRealEngine()
    try await run(AudioOutputTarget(service: service, now: { Date().timeIntervalSince1970 * 1000 }), label: "AVAudioEngine")
}

func testInterruptionEndsPendingDrain() async throws {
    let service = try await probeRealEngine()
    // open, write(2000 ms), drain in a Task, then
    NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: (session as! AVAudioEngineAudioOutputSession).engine)
    // drain throws Unavailable / audio_output_interrupted within 1 s; a following write() returns at once
}
```

In `IndeRunTests.swift`, next to the existing host tests: `func testDefaultHostServicesIncludeAudioOutput() { XCTAssertNotNil(DefaultHostServices.make().audioOutput) }`.

- [ ] **Step 3: Run them to verify they fail**

Run: `swift test --filter "AudioOutputGateTests|AudioOutputLifecycleConformanceTests|testDefaultHostServicesIncludeAudioOutput"`
Expected: compile error — `cannot find 'AudioOutputGate' in scope`, `cannot find 'AVAudioEngineAudioOutputService' in scope`.

- [ ] **Step 4: Implement**

`AudioOutputGate.swift` (actor with `CheckedContinuation` arrays for writers and drainers), `AVAudioEngineAudioOutputService.swift` per Interfaces, `DefaultHostServices.make` gains the parameter and passes it through.

- [ ] **Step 5: Run the tests on macOS and the simulator**

Run: `swift test --filter "AudioOutputGateTests|AudioOutputLifecycleConformanceTests|IndeRunTests" && (cd ios/IndeRun && swiftlint lint --strict)`
Expected: gate tests PASS; the real-engine tests PASS on a Mac with an output device and SKIP on a runner without one; lint clean.

Run: `xcodebuild test -scheme IndeRun-Package -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:IndeRunTests/AudioOutputLifecycleConformanceTests` (the device name `swift.yml:188-190` resolves)
Expected: PASS or SKIP, never a hang; the catalog's `timeoutMs` bounds every wait.

- [ ] **Step 6: Commit**

```bash
git add ios/IndeRun/Sources/IndeRunCore/AudioOutputGate.swift ios/IndeRun/Sources/IndeRunCore/AVAudioEngineAudioOutputService.swift ios/IndeRun/Sources/IndeRunCore/AppleHostServices.swift ios/IndeRun/Tests/IndeRunTests
git commit -m "feat(apple): play PCM through AVAudioEngine as the default audio output"
```

---

### Task 6: Android default service, wiring, instrumented catalog run

**Files:**
- Create: `android/inderun-core/src/main/kotlin/app/independo/inderun/core/AudioTrackAudioOutputService.kt`
- Modify: `android/inderun-core/src/main/kotlin/app/independo/inderun/core/HostServices.kt:144-153` (`HostServicesFactory.create`)
- Create: `android/inderun-core/src/test/kotlin/app/independo/inderun/core/AudioTrackAudioOutputServiceTest.kt`
- Modify: `android/inderun-kotlin/build.gradle.kts:8-14` (second static asset directory)
- Create: `android/inderun-kotlin/src/androidTest/kotlin/app/independo/inderun/sdk/AudioTrackAudioOutputConformanceTest.kt`
- Modify: `docs/ci.md:107-132` ("Real speech on an emulator")

**Interfaces:**
- Produces:
  ```kotlin
  class AudioTrackAudioOutputService(
      private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
  ) : AudioOutputService {
      override suspend fun open(format: AudioOutputFormat): AudioOutputSession
  }
  internal class AudioTrackAudioOutputSession(
      private val track: AudioTrack, private val format: AudioOutputFormat,
      private val ioDispatcher: CoroutineDispatcher, private val openedAt: Long,
  ) : AudioOutputSession
  ```
- Produces: `HostServicesFactory.create` adds `audioOutput = AudioTrackAudioOutputService()`.
- Consumes: `AudioTrack.Builder`, `AudioAttributes(USAGE_ASSISTANCE_ACCESSIBILITY, CONTENT_TYPE_SPEECH)`, `AudioFormat(ENCODING_PCM_16BIT, CHANNEL_OUT_MONO, sampleRate)`, `MODE_STREAM`, `createUnavailable`/`createCapabilityMismatch` (`Errors.kt`).

Session behaviour the signatures leave open: `open()` applies the format rule, then `getMinBufferSize` (an error value is `audio_format_unsupported`), buffer `max(min, 200 ms × 2 bytes)`, builds the track, `state != STATE_INITIALIZED` releases and throws `audio_output_failed`; no `play()` at open. The first `write()` calls `play()`; `write()` runs `track.write(samples, 0, n, WRITE_BLOCKING)` under `withContext(ioDispatcher)`; a short or negative result after `stop()` is ignored, `ERROR_DEAD_OBJECT` is `audio_output_interrupted`, other negatives `audio_output_failed`. `firstAudioMs()` comes from `setNotificationMarkerPosition(1)` and `setPlaybackPositionUpdateListener(listener, Handler(Looper.getMainLooper()))` (chosen over `getTimestamp()` because the emulator has no HAL timestamps); the value is `markerAt − openedAt` on `SystemClock.elapsedRealtime()`. `drain()` returns at once when stopped or nothing written, else polls `playbackHeadPosition >= framesWritten` every 10 ms under `withTimeoutOrNull(remainingMs + 2000)`, throwing `audio_output_failed` on timeout, then `track.stop()` and resets the frame count (the head position resets with `stop()`; a later `write()` calls `play()` again). `stop()` is `pause(); flush(); stop(); release()` once (an `AtomicBoolean`), which also returns a blocking write. No audio focus.

- [ ] **Step 1: Write the failing JVM tests**

`AudioTrackAudioOutputServiceTest.kt` (Robolectric for `Context`; nothing here constructs an `AudioTrack`):

```kotlin
@RunWith(RobolectricTestRunner::class)
class AudioTrackAudioOutputServiceTest {
    @Test
    fun factoryProvidesAudioOutput() {
        val host = HostServicesFactory.create(ApplicationProvider.getApplicationContext())
        assertTrue(host.audioOutput is AudioTrackAudioOutputService)
    }

    @Test
    fun openRefusesAnUnsupportedFormatBeforeTouchingAudioTrack() = runTest {
        val error = runCatching { AudioTrackAudioOutputService().open(AudioOutputFormat(sampleRate = 4000)) }
            .exceptionOrNull() as? IndeRunException ?: fail("expected an IndeRunException")
        assertEquals(IndeRunErrorClass.CapabilityMismatch, error.errorClass)
        assertEquals("audio_format_unsupported", error.details?.get("code"))
    }
}
```

- [ ] **Step 2: Write the failing instrumented test**

`AudioTrackAudioOutputConformanceTest.kt` (`AndroidJUnit4`, `runBlocking` so settles are real):

```kotlin
@RunWith(AndroidJUnit4::class)
class AudioTrackAudioOutputConformanceTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private fun catalogJson() = context.assets.open("audio-output-lifecycle.json").bufferedReader().use { it.readText() }
    private fun target() = AudioOutputTarget(AudioTrackAudioOutputService()) { SystemClock.elapsedRealtime().toDouble() }

    private val headIndependent = setOf(
        "unsupported_format_refused", "open_makes_no_sound", "stop_is_idempotent",
        "write_after_stop_is_ignored", "drain_after_stop_resolves_at_once", "stop_discards_buffered_audio",
    )
    private val playback = setOf("first_write_starts_playback", "drain_waits_for_everything_written", "sessions_are_independent")

    @Test
    fun implementsEveryCaseInTheSharedCatalogAndNoOthers() {
        val ids = audioOutputCatalogCases(catalogJson()).map { it.getString("id") }.sorted()
        assertEquals(ids, audioOutputHandlers.keys.sorted())
        assertEquals(ids, (headIndependent + playback).sorted())
    }

    @Test
    fun headIndependentCasesMatchTheSharedCatalog() = runBlocking {
        val failures = runAudioOutputCatalog(catalogJson(), target(), headIndependent)
        assertTrue("Conformance failures:\n${failures.joinToString("\n")}", failures.isEmpty())
    }

    @Test
    fun playbackCasesMatchTheSharedCatalogWhenTheDeviceRendersAudio() = runBlocking {
        // probe: open, write 200 ms, wait up to 2 s for firstAudioMs(); stop
        assumeTrue("AudioTrack's playback head does not advance on this device (emulator -noaudio?)", probeRenders())
        val failures = runAudioOutputCatalog(catalogJson(), target(), playback)
        assertTrue("Conformance failures:\n${failures.joinToString("\n")}", failures.isEmpty())
    }
}
```

Every wait is bounded by the catalog's `timeoutMs`, and `drain()` itself times out, so the test cannot hang on a silent HAL. `stop_discards_buffered_audio` is head-independent on purpose: it is the case that proves `stop()` returns a blocking `write`.

- [ ] **Step 3: Run them to verify they fail**

Run: `cd android && ./gradlew :inderun-core:testDebugUnitTest --tests "app.independo.inderun.core.AudioTrackAudioOutputServiceTest"`
Expected: FAIL — `Unresolved reference: AudioTrackAudioOutputService`.

- [ ] **Step 4: Implement and wire**

`AudioTrackAudioOutputService.kt` per Interfaces; `HostServicesFactory.create` adds `audioOutput = AudioTrackAudioOutputService()`. In `android/inderun-kotlin/build.gradle.kts:8-14`, add a second call `variant.androidTest?.sources?.assets?.addStaticSourceDirectory(File(rootProject.projectDir.parentFile, "contracts/fixtures/host").path)` and widen the comment: the corpus and the audio output catalog are read as assets.

- [ ] **Step 5: Run the JVM tests, then the instrumented run**

Run: `cd android && ./gradlew spotlessApply && ./gradlew test && cd .. && pnpm verify:android-api-deps`
Expected: PASS; no POM scope changes.

Run (emulator or device attached): `cd android && ./gradlew :inderun-kotlin:connectedDebugAndroidTest`
Expected: `implementsEveryCase…` and `headIndependentCases…` PASS; `playbackCases…` PASS on a device, SKIPPED on a `-noaudio` emulator.

- [ ] **Step 6: Document the emulator step**

`docs/ci.md`, in "Real speech on an emulator" (after the first paragraph, line 115): the same test APK runs `contracts/fixtures/host/audio-output-lifecycle.json` against the real `AudioTrack` (`AudioTrackAudioOutputConformanceTest`); the cases that need the playback head to advance skip under the job's `-noaudio` emulator and run on a real device; the stop and refusal cases run everywhere. Update the local-run sentence at line 130-132 to name both suites.

- [ ] **Step 7: Commit**

```bash
git add android/inderun-core/src/main/kotlin/app/independo/inderun/core android/inderun-core/src/test/kotlin/app/independo/inderun/core/AudioTrackAudioOutputServiceTest.kt android/inderun-kotlin/build.gradle.kts android/inderun-kotlin/src/androidTest docs/ci.md
git commit -m "feat(android): play PCM through AudioTrack as the default audio output"
```

---

### Task 7: ADR 021 and the documentation

**Files:**
- Create: `docs/architecture/decisions/021-audio-output-host-service.md`
- Modify: `docs/architecture/decisions/README.md:20` (new row after 020)
- Modify: `docs/architecture/architecture.md` (new `## Host Services` between `## Layers` and `## Execution Model`, line 18; bullet at line 25)
- Modify: `docs/architecture/providers.md:80`
- Modify: `packages/inderun-web/README.md:109-112`, `ios/IndeRun/README.md:133-138`, `android/README.md:54-58`
- Modify: `CLAUDE.md:35-38` and the same sentence in `AGENTS.md` §3
- Modify: `docs/migration.md` (new `### Audio output host service` before `### Capacitor`, line 184)

- [ ] **Step 1: Write ADR 021** (template from `decisions/README.md:22-42`; Status: Accepted; voice of ADR 020)

Context: PR 3's neural provider synthesizes PCM and has to play it; the three system speech providers never needed this because the platform synthesizer plays; ADR 017 §6 says playback is not an artifact and §7 keeps media out of events, so the audio must leave through the playback path; OS access belongs in host services (spec "Decisions" 4, CLAUDE.md §4.1); one definition of "nothing audible after cancel" and of time-to-first-audio is needed for the benchmark to compare families.

Decision, numbered:
1. **The service and its guarantees.** `HostServices.audioOutput`, optional like `streamingHttpClient`; `open` validates and is silent; `write` resolves once buffered and is the first audible effect; `drain` resolves when everything written has played; `stop` is immediate, discards, releases, idempotent, and nothing renders after it; sessions of one service are independent; the shared format rule (mono, `pcm_s16le`, 8–48 kHz); cancellation is `stop()` (TS `signal` on `open` only; Task cancellation on Swift and Kotlin). The catalog in `contracts/fixtures/host/audio-output-lifecycle.json` is the executable form.
2. **Absent service.** A provider that needs it refuses a playback request before commit with `CapabilityMismatch` `details.code: "audio_output_unavailable"` (ADR 016 §4), so routing falls through to the profile's next target; PR 3 implements it. Per-delivery availability on `ProviderTaskAvailability`, so the planner could reject earlier, is the flagged follow-up (spec B).
3. **Timing origin.** `firstAudioMs()` counts from `open()` and is the host's observation of the first frame leaving the output (web: scheduled time plus reported output latency); the provider converts it to the request-received origin that ADR 020 §3 defines before reporting `PlaybackTiming.firstAudioMs`.
4. **Audio session and focus stay app-owned.** The defaults set no `AVAudioSession` category and request no Android audio focus; an interruption ends the session with `audio_output_interrupted`, as `speech_interrupted` does for system speech.
5. **Error codes.** `audio_format_unsupported` (`CapabilityMismatch`), `audio_not_allowed`, `audio_output_failed`, `audio_output_interrupted` (`Unavailable`), `audio_output_unavailable` (`CapabilityMismatch`, provider, PR 3).

Consequences: one playback seam for every PCM-producing provider; a host can replace it (the fixture is the test double); a host without it still routes to system speech; an application that already owns an audio session keeps owning it, so ducking and interruption policy are not the SDK's; the web default needs a user gesture before `open()`, and `audio_not_allowed` is how a page learns that; the catalog proves lifecycle, not what a listener hears, which stays a manual check.

- [ ] **Step 2: Architecture docs**

`decisions/README.md`: row `| [021](./021-audio-output-host-service.md) | Audio output host service | Accepted |`. `architecture.md`: a short `## Host Services` section — the layer and why platform access lives there; `connectivity` required, the rest optional; the rule that an absent optional service makes the dependent provider refuse before commit so routing falls through (streaming HTTP, artifact destinations, audio output); links to ADR 017 and ADR 021; no implementation detail (CLAUDE.md §8). Extend the bullet at line 25 with "and, optionally, audio output". `providers.md:80`: after the streaming-client paragraph, one sentence per the same pattern: hosts may expose an optional `AudioOutputService`; all three defaults provide it; a host that does not is supported, and a provider that synthesizes audio refuses before commit with `audio_output_unavailable` (ADR 021).

- [ ] **Step 3: READMEs, guides, migration**

Each README's streaming note gains a sentence naming the default (`createBrowserHostServices`, `DefaultHostServices.make()`, `HostServicesFactory.create(context)`) and that the web default needs a user gesture before the first `open()`. `CLAUDE.md:37-38` and `AGENTS.md` §3: "hosts expose an optional streaming HTTP capability and an optional audio output capability". `docs/migration.md`: `### Audio output host service` — additive: `HostServices.audioOutput` on all three SDKs; the browser, Apple and Android default bundles now include it; a hand-built `HostServices` needs nothing; the Swift `DefaultHostServices.make` and Kotlin `HostServicesFactory.create` signatures grew by one defaulted parameter.

- [ ] **Step 4: Check and commit**

Run: `pnpm format:check`
Expected: PASS (Prettier does not cover Markdown here; eyeball the tables).

```bash
git add docs/architecture docs/migration.md packages/inderun-web/README.md ios/IndeRun/README.md android/README.md CLAUDE.md AGENTS.md
git commit -m "docs(adr): record the audio output host service (ADR 021)"
```

---

### Task 8: Whole-branch verification, squash and PR

- [ ] **Step 1: Automated**

Run: `pnpm test:js && swift test && (cd android && ./gradlew test) && (cd ios/IndeRun && swiftlint lint --strict) && (cd android && ./gradlew spotlessCheck) && pnpm format:check && pnpm build && pnpm verify:packaging && pnpm verify:android-api-deps && git diff --exit-code`
Expected: all PASS; no generated file changed; publint/attw unchanged.

- [ ] **Step 2: Manual**

- Web: `pnpm --filter @independo/inderun-web-demo dev`; in the browser console, `createBrowserHostServices()` then after a click `open()` a session and `write()` a tone: it plays; `stop()` half-way is silent at once; `open()` before any click rejects with `audio_not_allowed`.
- iOS simulator: `xcodebuild test -scheme IndeRun-Package -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:IndeRunTests/AudioOutputLifecycleConformanceTests` passes (not skipped) and a tone is audible from the simulator.
- Android device: `./gradlew :inderun-kotlin:connectedDebugAndroidTest`; `playbackCasesMatchTheSharedCatalogWhenTheDeviceRendersAudio` passes, not skipped.

- [ ] **Step 3: Squash, push and open the PR into `dev`**

Squash the task commits into one: `feat(core): add the optional audio output host service (#260)` with a body naming the three defaults, the fixture, the catalog and ADR 021, trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` last.

```bash
git push -u origin feat/m5-audio-output-host-service
gh pr create --base dev --title "feat(core): optional audio output host service on all three SDKs (#260, PR 2)" --body-file <(cat <<'BODY'
Part of #260. Lands `docs/superpowers/specs/2026-11-04-neural-speech-design.md` §B: `HostServices.audioOutput` (PCM playback) on TypeScript, Swift and Kotlin with identical semantics, defaults on Web Audio, `AVAudioEngine` and `AudioTrack`, a recording fixture per SDK, and the shared lifecycle catalog `contracts/fixtures/host/audio-output-lifecycle.json` run on every SDK (plus the real engines on macOS/iOS and the Android emulator). ADR 021. No provider uses it yet; the absent-service refusal is PR 3.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)
```

---

### Critical Files for Implementation

- `contracts/fixtures/host/audio-output-lifecycle.json` (new; the shared catalog every task runs)
- `packages/contracts/src/host.ts` (TS types; the semantics' canonical wording)
- `ios/IndeRun/Sources/IndeRunCore/HostServices.swift` and `android/inderun-core/src/main/kotlin/app/independo/inderun/core/HostServices.kt` (native types and factories)
- `packages/inderun-web/src/core/browser-audio-output.ts` (new; the web default and its scheduling math)
- `ios/IndeRun/Sources/IndeRunCore/AVAudioEngineAudioOutputService.swift` (new; tap placement and the gate)
- `android/inderun-kotlin/build.gradle.kts` (the `sharedTest` source set and the catalog asset copy)
