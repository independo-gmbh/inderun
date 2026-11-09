# Neural Speech Benchmark Implementation Plan (#276)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every platform the same JSON report for neural speech latency. Produce it from the Swift and Kotlin
gated tests, the iPhone harness and the web Voices lab. Then record real numbers in two verification docs.

**Architecture:** One JSON Schema under `contracts/fixtures/speech/` and a vitest guard over it and over every
committed report. Each harness has a small report builder in its own source set: Swift test target, Kotlin
`sharedTest`, web demo module and the iPhone patch. A builder groups samples by `(scenario, step, utteranceId)`,
computes nearest-rank p50/p95 and writes the schema shape. No public SDK API changes.

**Tech Stack:** JSON Schema 2020-12 + ajv 8 (vitest), XCTest (Swift 6), JUnit4 + AndroidX test (Kotlin), vitest +
happy-dom (web demo), bash + `git apply` (iPhone harness).

**Spec:** `docs/superpowers/specs/2026-11-09-neural-speech-benchmark-design.md`

## Global Constraints

- Report `schema` value is exactly `"inderun-speech-benchmark/1"`. `harness` is one of `"sdk_tests"`,
  `"ios_device_bench"` or `"web_voices_lab"`.
- No invented numbers. A cell without a real measurement says `pending`.
- `benchmark.scenarios` and `utterances` in `utterance-corpus.json` stay byte-identical. New sentences go in
  `extendedUtterances` with ids prefixed `ext_`.
- Reports and log lines never contain utterance text, prompt audio, or a user-assigned device name. `device` is a
  hardware model id:
  - macOS: `hw.model` sysctl;
  - iOS: `utsname.machine`;
  - Android: `Build.MANUFACTURER + " " + Build.MODEL`;
  - web: browser family + platform.
- Percentile is nearest-rank: sort ascending, take index `ceil(q·n) − 1`. Groups are keyed by
  `(scenario, step, utteranceId)`.
- The peak RSS sampler polls every 20 ms. `peakRssDeltaBytes = max(observed) − value at sample start`, clamped at
  ≥ 0. It is omitted on web.
- Tests that assert on durations use injected clocks or fixed inputs, never wall time.
- No backtracking regex on user text.
- No public API change, no new published dependency, no change under `rust/`.
- Never commit `tmp/`, model packages, voice bundles or weights. Committed reports go under
  `docs/verification/reports/`.
- Every command's exit status is checked directly. Do not pipe a gate through `| tail` or `| head`.
- Commit messages: Conventional Commits, scope `speech`, subject ends `(#276)`. The trailer is
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A target that declares no matching delivery, or throws `CapabilityMismatch`, must put the scenario in `skipped`
   with a reason. The report must still be written. Test: in each report builder (Tasks 3–5), a run with one
   skipped scenario serializes `skipped` and its p50/p95 lack that scenario.
2. A group with a single sample must give p50 == p95 == that value. An empty `samples` list must give empty
   `p50`/`p95`, not a crash. Test: builder unit tests in Tasks 3, 4 and 5.
3. A serialized report must never contain any corpus utterance text. Test: Tasks 3, 4 and 5 serialize a report built
   from corpus utterances and assert that no `text` value occurs in the output.
4. When `INDERUN_SPEECH_BENCHMARK_OUT` names a directory that does not exist, it must be created, and two targets
   must write two files. Test: Task 3's writer test against a temp dir. Task 4 does the same with `speechBenchmarkOut`.
5. A second "Run corpus" click while a run is in progress must start nothing. The button stays disabled until the
   run ends, success or failure. Test: Task 5 panel test.

---

### Task 1: Report schema and guard test

**Files:**
- Create: `contracts/fixtures/speech/speech-benchmark-report.schema.json`
- Create: `packages/contracts/src/speech-benchmark-report.test.ts`
- Create: `docs/verification/reports/.gitkeep`

**Interfaces:**
- Produces: the schema file. Tasks 3–7 write reports that must validate against it. Its required top-level keys are
  `schema`, `harness`, `createdAt`, `device`, `os`, `sdkVersion`, `target`, `requestedLocale`, `resolvedLocale`,
  `locality`, `samples`, `skipped`, `p50` and `p95`. `audio` is optional.
- `target`: `name` and `providerId` are required. `model`, `variant`, `checksums` (string map, values match
  `^sha256:[0-9a-f]{64}$`) and `voiceId` are optional.
- `locality` is an enum: `on_device`, `edge`, `cloud`.
- `samples[]`: `scenario`, `step`, `utteranceId` and `requestedLocale` are required. `resolvedLocale` is optional.
  The metric keys are `firstChunkMs`, `firstAudioMs`, `wallMs`, `durationMs`, `prepareMs`, `stopLatencyMs`,
  `renderMs`, `audioMs`, `realTimeFactor`, `bytes` and `peakRssDeltaBytes`. Each metric is optional, a number and
  `minimum: 0`. `additionalProperties: false`.
- `skipped[]` is `{scenario, reason}`. `p50[]` and `p95[]` are `{scenario, step, utteranceId, metrics: {<metric>: number ≥ 0}}`.
- `audio[]` is `{utteranceId?, voiceId, locale, mimeType, base64}`.
- Use `$schema` `https://json-schema.org/draft/2020-12/schema`. Check which draft
  `contracts/fixtures/*/*.schema.json` use; if they use another draft, use theirs. Load ajv the way the contracts
  package already does. If the 2020 draft needs it, use `ajv/dist/2020`.

- [ ] **Step 1: Write the failing tests** in `speech-benchmark-report.test.ts`:
  - `compiles the schema`;
  - `accepts a minimal report`. Use an inline object with one sample
    `{scenario:"render_speed", step:"warm", utteranceId:"de_de_short", requestedLocale:"de-DE", renderMs:12.5}`,
    `skipped: []` and matching p50/p95.
  - `rejects …` cases, each a copy of the minimal report with one change. Each must be rejected:
    - `schema: "inderun-speech-benchmark/2"`;
    - `harness: "xcode"`;
    - `renderMs: -1`;
    - a sample without `utteranceId`;
    - an unknown sample key `text`;
    - a missing `skipped`.
  - `every committed report validates and names corpus utterances`. Glob `docs/verification/reports/*.json`; zero
    files passes. Every `samples[].utteranceId` must be in the union of `utterances[].id` and
    `extendedUtterances[].id` (treat a missing `extendedUtterances` as `[]`).
- [ ] **Step 2: Run** `pnpm --filter @independo/inderun-contracts test -- speech-benchmark-report`. Expected: FAIL,
  because the schema file is missing.
- [ ] **Step 3: Write the schema.** Each property gets a `description`, as the sibling fixtures do.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit** `test(speech): add the speech benchmark report schema and guard (#276)`.

### Task 2: Corpus extension

**Files:**
- Modify: `contracts/fixtures/speech/utterance-corpus.json`. Add top-level `extendedUtterances` after `utterances`.
  Extend `$comment` by one sentence: extended utterances serve renders and the lab, never the scenarios.
- Modify: `packages/contracts/src/utterance-corpus.test.ts`

**Interfaces:**
- Produces: `extendedUtterances: Utterance[]`, with the same shape as `utterances` and `expect` always `"speak"`.
  Tasks 3, 4 and 5 read it.

- [ ] **Step 1: Write the failing tests** in `utterance-corpus.test.ts`:
  - `extended utterances exist` (length ≥ 18);
  - `ids are unique across both arrays`;
  - every extended id matches `^ext_[a-z0-9_]+$`;
  - each locale is in `["de-DE", "de-AT", "en-US"]`;
  - `expect === "speak"` and `text.trim().length > 0`;
  - at least one entry per category in `["numbers", "dates", "money", "units", "abbreviations", "long", "mixed_language"]`;
  - every `long` text has more than 400 characters;
  - at least one de-AT entry contains `"Jänner"`;
  - `the seven scenarios are unchanged`. Assert that `benchmark.scenarios.map(s => s.id)` deep-equals
    `["first_call_cold","first_call_after_prepare","repeat_same_voice","switch_language","speak_after_stop","text_length","render_speed"]`.
    Assert that `utterances.length === 11`.
- [ ] **Step 2: Run** `pnpm --filter @independo/inderun-contracts test -- utterance-corpus`. Expected: FAIL.
- [ ] **Step 3: Add about 20 entries.** Write new, natural sentences in the categories above. Where a case fits,
  base it on a case from `contracts/fixtures/speech/german-frontend.json`, but do not copy normalizer inputs. Do
  not reorder or reformat existing JSON: `git diff` must show only additions plus the `$comment` line.
- [ ] **Step 4: Run** the same command, then `pnpm test:js`. Expected: both PASS. The system speech suites are
  unaffected.
- [ ] **Step 5: Commit** `feat(speech): extend the utterance corpus for neural speech (#276)`.

### Task 3: Swift report builder and neural target

**Files:**
- Create: `ios/IndeRun/Tests/IndeRunTests/SpeechBenchmarkReport.swift` (builder, writer, RSS sampler)
- Create: `ios/IndeRun/Tests/IndeRunTests/SpeechBenchmarkReportTests.swift` (not gated)
- Modify: `ios/IndeRun/Tests/IndeRunTests/SpeechBenchmarkTests.swift`

**Interfaces:**
- Consumes: the schema (Task 1) and `extendedUtterances` (Task 2).
- Produces:
  - `struct SpeechBenchmarkReport: Encodable`. Its fields mirror the schema. `static func build(harness: String,
    device: String, os: String, sdkVersion: String, target: Target, locality: String, samples: [Sample],
    skipped: [(scenario: String, reason: String)], createdAt: Date) -> SpeechBenchmarkReport`.
  - `func write(to directory: URL) throws -> URL`. It creates the directory and writes
    `sdk_tests-<target.name>-<device>-<yyyy-MM-dd>.json` with sorted keys.
  - `static func percentile(_ sorted: [Double], _ q: Double) -> Double` (nearest-rank).
  - `final class PeakRssSampler`: `init(read: @escaping @Sendable () -> UInt64 = PeakRssSampler.physFootprint,
    interval: Duration = .milliseconds(20))`, `func start()` and `func stop() -> UInt64` (the delta).
  - `static func hardwareModel() -> String`: `hw.model` on macOS, `utsname.machine` on iOS.
  - `Sample` gains `requestedLocale: String` and `resolvedLocale: String?`.

- [ ] **Step 1: Write the failing tests** in `SpeechBenchmarkReportTests.swift`:
  - `testPercentileNearestRank`: `[1,2,3,4,5,6,7,8,9,10]` gives q 0.5 → 5 and q 0.95 → 10; `[7]` gives 7 for both.
  - `testGroupsByScenarioStepUtterance`: two `cold` samples and three `warm` samples give two p50 entries. The cold
    samples are never pooled with the warm ones.
  - `testEmptySamplesGiveEmptyPercentiles`.
  - `testSkippedScenarioIsListedAndAbsentFromPercentiles`.
  - `testReportNeverContainsUtteranceText`: load the corpus, build samples for every utterance, encode, and assert
    that no utterance `text` is a substring.
  - `testRequestedAndResolvedLocalesAreDistinctFirstSeen`: samples de-DE, en-US, de-DE give `["de-DE","en-US"]`.
  - `testWriteCreatesMissingDirectoryAndOneFilePerTarget`: write to a temp dir that does not exist yet.
  - `testPeakRssSamplerReportsPeakMinusStart`: the injected reader returns 100, 180, 150. Expected delta: 80.
- [ ] **Step 2: Run** `swift test --filter SpeechBenchmarkReportTests`. Expected: FAIL (does not compile).
- [ ] **Step 3: Implement** `SpeechBenchmarkReport.swift`. `physFootprint` reads `task_vm_info.phys_footprint`, the
  same call as `tools/neural-speech/ios-device-bench.patch`.
- [ ] **Step 4: Change `SpeechBenchmarkTests.swift`:**
  - `targets` becomes a function. When `INDERUN_SPEECH_BENCHMARK_MODEL_DIR` is set, it appends
    `Target(name: "articulino_<variant>", …)`. The target's provider is
    `NeuralSpeechProvider(options: NeuralSpeechProviderOptions(modelPackage: <package>, runtime: OnnxNeuralSpeechRuntime()))`.
    The package is decoded from `<dir>/model-package.json` with `source` rewritten to
    `{sourceType:"filesystem", ref:<dir>}`.
  - `Target` gains `hostServices: () -> HostServices`. The neural target uses `DefaultHostServices.make()`; the
    system target keeps its mocks. It also gains `model`, `variant`, `checksums`, `providerId` and `locality`.
  - Each sample records `firstChunkMs` and `firstAudioMs` from `timing`, `resolvedLocale` from the result's speech
    locale, and `peakRssDeltaBytes` from `PeakRssSampler`.
  - The neural target alone renders every `extendedUtterances` entry once with `generateSpeech`, under scenario
    `render_speed`, step `extended`.
  - When `INDERUN_SPEECH_BENCHMARK_OUT` is set, each target writes one report.
    - `sdkVersion` comes from `INDERUN_SPEECH_BENCHMARK_SDK_VERSION`, default `"dev"`.
    - `harness` is `"sdk_tests"`.
    - Scenarios that were skipped or unavailable go in `skipped`, with the reason the code already prints.
  - The `INDERUN-BENCH` lines stay as they are.
- [ ] **Step 5: Run:**
  - `swift test --filter SpeechBenchmarkReportTests`. Expected: PASS.
  - `swift test --filter SpeechBenchmarkTests`. Expected: the gated test is skipped, and
    `testImplementsEveryBenchmarkScenarioAndNoOthers` passes.
  - `cd ios/IndeRun && swiftlint lint --strict`. Expected: exit 0.
- [ ] **Step 6: Commit** `feat(speech): write benchmark reports from the Swift speech benchmark (#276)`.

### Task 4: Kotlin report builder and neural target

**Files:**
- Create: `android/inderun-kotlin/src/sharedTest/kotlin/app/independo/inderun/sdk/SpeechBenchmarkReport.kt`
- Create: `android/inderun-kotlin/src/test/kotlin/app/independo/inderun/sdk/SpeechBenchmarkReportTest.kt`
- Create: `android/inderun-kotlin/src/androidTest/kotlin/app/independo/inderun/sdk/ModelPackageDirectory.kt`. Move
  `loadPackage` here from `OnnxNeuralSpeechRealModelTest.kt` as `fun loadModelPackage(directory: String): ModelPackage`.
  `OnnxNeuralSpeechRealModelTest` uses it.
- Modify: `android/inderun-kotlin/src/androidTest/kotlin/app/independo/inderun/sdk/SpeechBenchmarkTest.kt`
- Modify: `android/inderun-kotlin/src/androidTest/kotlin/app/independo/inderun/sdk/OnnxNeuralSpeechRealModelTest.kt`

**Interfaces:**
- Consumes: Tasks 1 and 2.
- Produces:
  - `SpeechBenchmarkReport.build(...)`, with the same parameters as Swift and `createdAt: Instant`.
  - `fun toJson(): JSONObject`, using `org.json`. The JVM unit tests get org.json from Robolectric; check that it
    is on the test classpath. If it is not, add `testImplementation("org.json:json:<version already in the catalog>")`.
  - `fun write(directory: File): File`, with the same filename rule as Swift.
  - `fun percentile(sorted: List<Double>, q: Double): Double`.
  - `class PeakRssSampler(read: () -> Long = ::vmRssBytes, intervalMs: Long = 20)`, with `start()` and
    `stop(): Long`. `vmRssBytes()` parses the `VmRSS:` line of `/proc/self/status`. Find the line with
    `startsWith` and split on whitespace, without a regex.
- `sdkVersion` comes from the instrumentation argument `speechBenchmarkSdkVersion`, default `"dev"`.
  - Ruling (deviates from spec §4 "buildConfigField"): a `buildConfigField` needs `buildFeatures.buildConfig = true`
    on the published library, which would add `BuildConfig` to the AAR's API. An argument mirrors the Swift env var.

- [ ] **Step 1: Write the failing tests** in `SpeechBenchmarkReportTest.kt`. They are the same eight cases as Task 3
  Step 1, with Kotlin names: `percentileNearestRank`, `groupsByScenarioStepUtterance`, and so on. The corpus is
  read from `../../contracts/fixtures/speech/utterance-corpus.json` relative to the module directory. Use the path
  pattern of an existing JVM test that reads fixtures; find it under `src/test`.
- [ ] **Step 2: Run** `cd android && ./gradlew :inderun-kotlin:testDebugUnitTest --tests '*SpeechBenchmarkReportTest'`.
  Expected: FAIL.
- [ ] **Step 3: Implement** `SpeechBenchmarkReport.kt` and `ModelPackageDirectory.kt`.
- [ ] **Step 4: Change `SpeechBenchmarkTest.kt`** the same way as Task 3 Step 4:
  - the arguments are `speechBenchmarkModelDir`, `speechBenchmarkOut` and `speechBenchmarkSdkVersion`;
  - the provider is `NeuralSpeechProvider` with `OnnxNeuralSpeechRuntime(context)`;
  - the neural target uses the full host services that `HostServicesFactory` builds for a context, including
    audio output;
  - the neural target renders the extended corpus under `render_speed`/`extended`;
  - log lines are unchanged.
  - Update the class KDoc with the new arguments.
  - In `CONTEXT.md` (`CLAUDE.md` symlinks to it), update the `connectedAndroidTest` paragraph to name the new
    arguments and the Swift environment variables (`INDERUN_SPEECH_BENCHMARK_MODEL_DIR`, `_OUT`, `_SDK_VERSION`).
- [ ] **Step 5: Run:**
  - the Step 2 command. Expected: PASS.
  - `cd android && ./gradlew :inderun-kotlin:compileDebugAndroidTestKotlin spotlessCheck`. Expected: BUILD
    SUCCESSFUL. No device is attached, so the instrumented run is not possible; say so in the report.
- [ ] **Step 6: Commit** `feat(speech): write benchmark reports from the Kotlin speech benchmark (#276)`.

### Task 5: Web Voices lab "Run corpus" and "Export"

**Files:**
- Create: `packages/inderun-web-demo/src/voices-lab-benchmark.ts`
- Create: `packages/inderun-web-demo/src/voices-lab-benchmark.test.ts`
- Modify: `packages/inderun-web-demo/src/voices-lab-panel.ts`, `voices-lab-panel.test.ts`, `voices-lab-main.ts`
  (pass the full corpus) and `packages/inderun-web-demo/package.json` (devDependency `ajv` `^8.20.0`, the version
  `packages/contracts` uses).

**Interfaces:**
- Consumes: Tasks 1 and 2. It also uses `speak` and `generateSpeech` from `@independo/inderun-web`, through the
  injectable `VoicesLabApi`. Add `generateSpeech: typeof sdkGenerateSpeech` to `VoicesLabApi` and its default.
- Produces:
  - `runCorpus(input: { api: VoicesLabBenchmarkApi; engine: IndeRunApi; profile?: string; voice?: SpeechVoice;
    corpus: BenchmarkCorpus; target: ReportTarget; now: () => number; onProgress?: (done: number, total: number) => void }): Promise<BenchmarkRun>`.
    - It runs the seven scenarios. Each handler mirrors the setup text of the Swift handlers.
    - `first_call_cold` and `first_call_after_prepare` need "a new engine per trial". Take it from a
      `newEngine: () => IndeRunApi` input, which the panel wires to the lab engine factory.
  - `buildReport(run: BenchmarkRun, meta: { device: string; os: string; sdkVersion: string; createdAt: string }): SpeechBenchmarkReport`.
    - `harness: "web_voices_lab"`; nearest-rank p50/p95; no `peakRssDeltaBytes`.
  - `withAudio(report, renders: RenderedAudio[]): SpeechBenchmarkReport`. `renders` are the warm `render_speed`
    artifacts, base64-encoded.
  - `describeBrowser(nav: Navigator): { device: string; os: string }`.
    - It uses `userAgentData.brands` and `platform` when present.
    - Otherwise it uses a scan of the UA string by `indexOf` (Chrome/Firefox/Safari/Edg), not a regex.
    - It never returns the full UA.
- Panel:
  - Buttons `#lab-run-corpus` ("Run corpus (plays audio)") and `#lab-export` ("Export report"). `#lab-export` is
    disabled until a run finishes.
  - A checkbox `#lab-export-audio` ("Include rendered audio"), off by default.
  - A status line `#lab-run-status` shows progress.
  - Downloads go through an injectable `download(name: string, json: string)` option, defaulting to a Blob plus an
    `<a download>` click. The file name is `speech-benchmark-<target.name>-<yyyy-mm-dd>.json`.
  - `sdkVersion` is the `version` from `packages/inderun-web/package.json` (JSON import).

- [ ] **Step 1: Write the failing tests.**
  - In `voices-lab-benchmark.test.ts`, against a fake `api`, fake engine and stepping `now`:
    - `handles each of the seven scenarios`;
    - `report validates against the schema` (ajv on `contracts/fixtures/speech/speech-benchmark-report.schema.json`);
    - the percentile, empty and skipped cases from Review Focus 1–2;
    - `never contains utterance text`;
    - `export without audio has no audio key`;
    - `export with audio carries base64 and mimeType`;
    - `describeBrowser never returns the user agent`.
  - In `voices-lab-panel.test.ts`:
    - `run corpus disables itself until the run ends`, which also covers a rejected run;
    - `export is disabled before a run`;
    - `export downloads the last report`.
- [ ] **Step 2: Run** `pnpm --filter @independo/inderun-web-demo test`. Expected: FAIL.
- [ ] **Step 3: Implement** `voices-lab-benchmark.ts` and the panel changes. In playback scenarios, stop through the
  existing `PlaybackHandle` cancel.
- [ ] **Step 4: Run:**
  - `pnpm --filter @independo/inderun-web-demo test`. Expected: PASS.
  - `pnpm --filter @independo/inderun-web-demo build`. Expected: PASS.
  - `pnpm lint` and `pnpm format:check:js`. Expected: exit 0.
- [ ] **Step 5: Commit** `feat(speech): run the benchmark corpus and export reports from the web Voices lab (#276)`.

### Task 6: iPhone harness writes the report

**Files:**
- Modify: `tools/neural-speech/ios-device-bench.patch`
- Modify: `tools/neural-speech/ios_device_bench.sh`
- Modify: `tools/neural-speech/README.md`

**Interfaces:**
- Consumes: the schema (Task 1). The patch reimplements the builder inline in the hook. The demo app cannot import
  test sources.
- Produces: `Documents/bench.json`, copied back by the script.
  - `--out <file>` names the JSON. The text log goes next to it as `<file>.txt`.
  - The default name is `ios_device_bench-<target>-<machine>-<date>.json`.

- [ ] **Step 1: Regenerate the patch.**
  - Run `git apply tools/neural-speech/ios-device-bench.patch`.
  - Edit `IndeRunDemoApp.swift`. The hook builds `IndeRun(registry:hostServices: DefaultHostServices.make())` with
    one `NeuralSpeechProvider(options:)` over `OnnxNeuralSpeechRuntime()`, then runs through the public API:
    - `first_call_after_prepare`: per round, a new engine, `prepare` timed as `prepareMs`, then `speak` of
      `de_de_short`, recording `firstChunkMs`, `firstAudioMs`, `wallMs` and `durationMs`.
    - `render_speed`: the utterance ids `render_speed` names in the corpus. Copy their ids and texts verbatim from
      `utterance-corpus.json`. Run one cold trial plus `-inderunBenchRounds` warm trials of `generateSpeech`,
      recording `renderMs`, `audioMs`, `realTimeFactor` and `bytes`.
    - Each sample records `peakRssDeltaBytes` (20 ms `phys_footprint` sampler).
    - The other five scenario ids go in `skipped` with reason `"not run by the device harness"`.
    - `device` is `utsname.machine`. `os` is `"iOS " + operatingSystemVersionString`'s numeric part, or build it
      from `operatingSystemVersion`. `sdkVersion` is the launch argument `-inderunBenchSdkVersion`, default
      `"dev"`. `harness` is `"ios_device_bench"`.
    - The hook still writes the text log lines, without utterance text, and writes `bench.json` at the end or on
      error. On error, `samples` holds what completed, and `skipped` gets `{scenario, reason: <error>}`.
  - Write the new patch with `git diff -- ios/SampleApps/IndeRunDemo/IndeRunDemo/IndeRunDemoApp.swift > tools/neural-speech/ios-device-bench.patch`.
  - Run `git checkout -- ios/SampleApps/IndeRunDemo/IndeRunDemo/IndeRunDemoApp.swift`.
- [ ] **Step 2: Change the script** so it waits for `bench.json`, copies it to `--out` and passes
  `-inderunBenchSdkVersion` through (new flag `--sdk-version`, default `dev`).
- [ ] **Step 3: Verify:**
  - `git apply --check tools/neural-speech/ios-device-bench.patch`. Expected: exit 0.
  - With the patch applied:
    `xcodebuild build -project ios/SampleApps/IndeRunDemo/IndeRunDemo.xcodeproj -scheme IndeRunDemo -destination 'generic/platform=iOS Simulator' -derivedDataPath <scratch>`.
    Expected: `** BUILD SUCCEEDED **`. Then revert the patch, and check that `git status` shows the app file
    unchanged.
  - `bash -n tools/neural-speech/ios_device_bench.sh`. Expected: exit 0.
- [ ] **Step 4: Update the README** section for `ios_device_bench.sh`: JSON output, `--sdk-version`, and the two
  scenarios it runs. Update the `ios_device_bench.sh` line in `CONTEXT.md` (`CLAUDE.md` symlinks to it) the same way.
- [ ] **Step 5: Commit** `feat(speech): write benchmark reports from the iPhone harness (#276)`.

### Task 7: Mac and web measurements (controller, inline)

The controller runs this task, not a subagent: it runs real hardware and a browser, and writes no code.

- [ ] Build `tmp/bench-package-int8` with `prepare_articulino_package.py`:
  - `--models tmp/articulino-onnx`. Before that, run `shasum -a 256 -c SHA256SUMS` in `tmp/articulino-onnx`.
  - `--precision int8`.
  - `--voice tmp/neural-speech-assets-1/de-de-f-1.safetensors:de-de-f-1`, after checking that its sha256 matches
    the catalog. If the tool does not accept a `.safetensors` voice, use the matching seed
    `tools/neural-speech/voice-seeds/<seed>.seed.wav`.
- [ ] Run `INDERUN_SPEECH_BENCHMARK=1 INDERUN_SPEECH_BENCHMARK_MODEL_DIR=$PWD/tmp/bench-package-int8 INDERUN_SPEECH_BENCHMARK_OUT=$PWD/tmp/bench-reports INDERUN_SPEECH_BENCHMARK_SDK_VERSION=<version from android/gradle.properties>-dev swift test --filter SpeechBenchmarkTests`.
  Copy both reports (system and neural) into `docs/verification/reports/`.
- [ ] Web: `pnpm --filter @independo/inderun-web-demo dev` with `VITE_INDERUN_VOICES_LAB=1`, in Chrome on this Mac.
  Install the Articulino entry from the catalog, click Run corpus, and save the downloaded report into
  `docs/verification/reports/`.
  - If the browser automation fails after 2–3 tries, the web cells say `pending`; record why in the ledger.
- [ ] Run `pnpm --filter @independo/inderun-contracts test -- speech-benchmark-report`. Expected: PASS with the real
  reports.
- [ ] Commit `docs(speech): add Mac and web neural speech benchmark reports (#276)`.

### Task 8: iPhone run (controller, owner)

- [ ] Ask the owner to connect and unlock "iPhone K". If the owner is not available, the iPhone cells say
  `pending`; go to Task 9.
- [ ] Run `tools/neural-speech/ios_device_bench.sh --device 00008120-0008653E2261A01E --package tmp/bench-package-int8 --rounds 5 --sdk-version <same> --out docs/verification/reports/ios_device_bench-articulino_int8-<machine>-<date>.json`.
  Delete the `.txt` log or keep it in `tmp/`; only the JSON is committed.
- [ ] Run the guard test (Task 7 command). Expected: PASS. Commit `docs(speech): add the iPhone neural speech benchmark report (#276)`.

### Task 9: Verification and admission docs

**Files:**
- Create: `docs/verification/neural-speech.md`
- Create: `docs/verification/neural-speech-admission.md`
- Modify: `docs/architecture/neural-speech-provider-family.md` (the "Timing" section links `neural-speech.md`), the
  Provider Matrix note for `local.onnx.speech.*` in `docs/architecture/providers.md` if it mentions benchmarks, and
  `docs/verification/system-speech.md` ("Running the scenarios on another provider" links the new doc).

**Interfaces:**
- Consumes: the committed reports from Tasks 7–8 and `contracts/fixtures/speech/neural-model-catalog.json`.

- [ ] **`neural-speech.md`.** Model it on `system-speech.md`: a "Method" section, then results.
  - Results are one table per platform. Rows are scenario/step; columns are p50 and p95 of the key metrics.
    Every number is copied from a committed report, and each table cites its report file.
  - A matrix shows family × locale × platform × device:
    - real cells are Mac, web and iPhone for Articulino int8;
    - `pending` cells are Android, all Core AI cells, and Supertonic until #277;
    - Kokoro, Piper and Pocket TTS are "deferred".
  - It links #251, #252, `system-speech.md` and the report schema.
  - It states that no listening scores exist yet (PR 12).
- [ ] **`neural-speech-admission.md`.** One row per catalog asset (weights, each voice, frontend config, runtime),
  generated by reading the catalog. Columns: SPDX, licence URL, redistribution, GPL/NC/OpenRAIL flags, and
  `review.status` with notes. Add the ONNX Runtime row (MIT) and the frontend row (the in-repo Rust normalizer,
  MIT). Link #251 and #252.
- [ ] **Check:** run `grep -n 'pending' docs/verification/neural-speech.md` and confirm that every cell without a
  report says `pending`. Every number must appear in a cited report. The implementer checks each number against
  its JSON and lists the checks in the report.
- [ ] Run `pnpm format:check:js`. Expected: exit 0. Prettier covers markdown; if it reformats, run `pnpm format:js`.
- [ ] Commit `docs(speech): add the neural speech verification and admission records (#276)`.
