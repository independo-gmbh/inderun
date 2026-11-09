# Neural speech benchmarks, JSON report and verification docs (#276)

Part of #260 (programme PR 7). Programme spec: `2026-11-04-neural-speech-design.md` §F. Issue: #276.

## Intent

The owner wants this milestone done so v0.5.0 can ship. A neural voice is chosen over the OS voice for three reasons:
it sounds more natural, it sounds the same on every platform, and Articulino can make a new voice from a short sample.
The listening part of that is not built here; it is the PR 12 device campaign. The benchmark has one job here: show
with real numbers that a neural voice is fast enough and small enough to ship. It must report the same shape on every
platform, so numbers from any platform can be compared side by side.

Scope is the issue's acceptance list, nothing more.

## Non-goals

- No A/B listening page, voting or listening-score UI (owner, 2026-11-09).
- No automated quality score (MOS prediction or similar).
- No new public SDK API. Everything here is test code, demo code, fixtures, tools and docs.
- No Android device numbers. No Android device is attached. Android cells say `pending` and the PR says
  `Part of #276`.
- No Core AI numbers. Spike 0b (#279) comes after this. Core AI cells say `pending` (ruling below).

## Constraints

- No invented numbers. A cell without a real measurement says `pending`.
- The seven `benchmark.scenarios` and the `utterances` array of `utterance-corpus.json` stay byte-identical.
- Reports and logs never contain utterance text, prompt audio, or a user-assigned device name.
- Timing code in tests uses injected or fake clocks wherever a test asserts on a duration.
- Text handling avoids regexes that can backtrack on user text (the CodeQL lesson from #288).
- Parity: one schema and one corpus under `contracts/fixtures/speech/`, shared by Swift, Kotlin and Web.

## Decisions

### 1. Report schema `inderun-speech-benchmark/1`

File: `contracts/fixtures/speech/speech-benchmark-report.schema.json` (JSON Schema draft 2020-12, the draft the other
fixtures use). A run writes one report per target.

```
{
  schema: "inderun-speech-benchmark/1",
  harness: "sdk_tests" | "ios_device_bench" | "web_voices_lab",
  createdAt: ISO-8601 string,
  device: string,              // hardware model id (e.g. "iPhone15,4", "Mac16,10", a browser UA family);
                               // never the user-assigned device name
  os: string,                  // e.g. "iOS 27.2", "macOS 27.2", "Android 16"
  sdkVersion: string,
  target: {
    name: string,              // the benchmark target name, e.g. "apple_system_speech", "articulino_int8"
    providerId: string,
    model?: string,            // catalog entry id; absent for system speech
    variant?: string,
    checksums?: { [path]: "sha256:<hex>" },   // from the package's integrity.checksums
    voiceId?: string
  },
  requestedLocale: string[],   // the distinct locales the run requested, first-seen order
  resolvedLocale: string[],    // the distinct locales the provider reported speaking, first-seen order
  locality: "on_device" | "edge" | "cloud",
  samples: [{
    scenario: string, step: string, utteranceId: string,
    requestedLocale: string, resolvedLocale?: string,
    firstChunkMs?, firstAudioMs?, wallMs?, durationMs?, prepareMs?, stopLatencyMs?,
    renderMs?, audioMs?, realTimeFactor?, bytes?, peakRssDeltaBytes?   // numbers ≥ 0
  }],
  skipped: [{ scenario: string, reason: string }],   // required; [] when every scenario ran
  audio?: [{ utteranceId?: string, voiceId: string, locale: string, mimeType: string, base64: string }],
                               // Web lab export only (decision 6)
  p50: [{ scenario, step, utteranceId, metrics: { [metric]: number } }],
  p95: [ same shape as p50 ]
}
```

My calls:
- `requestedLocale` and `resolvedLocale` are arrays at the top level. A single string cannot describe
  `switch_language`, which speaks two locales in one run. Each sample also carries its own singular values.
- p50/p95 group by `(scenario, step, utteranceId)`, the same grouping the current `INDERUN-BENCH-SUMMARY` lines use.
  That way a cold call is never pooled with warm ones. Percentile = nearest-rank.
- `harness` exists because the iPhone numbers come from a different harness (decision 5). A reader must be able to
  tell harnesses apart.
- `resolvedLocale` comes from the speech result's `speech.locale` where the result reports one. Otherwise it is
  omitted.
- `firstChunkMs` and `firstAudioMs` come from the playback result's `timing`. They are absent when the provider does
  not report them (system speech has no `firstChunkMs`).

Guard: `packages/contracts/src/speech-benchmark-report.test.ts` (vitest + ajv, shaped like
`neural-model-catalog.test.ts`):
- the schema compiles;
- a minimal hand-written report validates;
- reports with a missing `schema`, an unknown `harness`, a negative metric, or a `samples` entry without `utteranceId`
  are rejected;
- every committed report under `docs/verification/reports/*.json` validates;
- every `utteranceId` in those reports exists in the corpus.

### 2. Committed reports

Real reports that back a number in `neural-speech.md` are committed under `docs/verification/reports/`. The file name
is `<harness>-<target>-<device>-<YYYY-MM-DD>.json`. The doc cites the file next to each number. My call: committing
them makes each number checkable and gives the guard test real input. The reports carry no text and no personal data.

### 3. Corpus extension

Add an `extendedUtterances` array to `contracts/fixtures/speech/utterance-corpus.json`. Each entry has the same shape
as `utterances`: id, locale, category, text, expect `speak`. The ids are prefixed `ext_`. About 20 entries cover
de-DE, de-AT and en-US:
- cardinal and ordinal numbers;
- dates, including "Jänner" for de-AT;
- times, money (€, $), units (km, kg, °C, %);
- abbreviations (z. B., usw., Dr., Nr.);
- two long passages (more than 400 characters);
- mixed German/English terms ("das Meeting", "der Laptop").

Draw the cases from `german-frontend.json` where they fit. They are new sentences, not copies of normalizer test
inputs.

Nothing in the existing suites iterates `extendedUtterances`. The system-speech corpus suites and the seven scenarios
are therefore unchanged. Users:
- the Web Voices lab presets list;
- the gated neural targets (Swift, Kotlin), which render each extended utterance once through `generateSpeech`. These
  render samples go under the scenario id `render_speed` with step `extended`, so no eighth scenario is invented;
- `utterance-corpus.test.ts`, which guards the new array: unique ids across both arrays, the `ext_` prefix, the
  allowed locales, non-empty text, and no `refuse` entries.

### 4. Gated neural targets (Swift, Kotlin)

Swift (`ios/IndeRun/Tests/IndeRunTests/SpeechBenchmarkTests.swift`):
- With `INDERUN_SPEECH_BENCHMARK_MODEL_DIR` set to a directory that contains `model-package.json`, add a target
  `articulino_<variant>`. Build it the way `ios-device-bench.patch` does: decode the package and rewrite `source` to
  `{sourceType: "filesystem", ref: <dir>}`. The provider is the ONNX neural speech provider with
  `OnnxNeuralSpeechRuntime`.
- The neural target's engine uses `DefaultHostServices.make()`, so playback has `audioOutput`. The system target keeps
  its current mock services.
- `INDERUN_SPEECH_BENCHMARK=1` still gates the whole suite.
- `INDERUN_SPEECH_BENCHMARK_OUT=<dir>` writes one report per target into that directory.
- Peak RSS delta: a sampler polls `task_vm_info.phys_footprint` every 20 ms during each sample. The value is the
  peak minus the value at sample start, in bytes.
- `sdkVersion` comes from `INDERUN_SPEECH_BENCHMARK_SDK_VERSION`, default `"dev"`. The device is the `hw.model`
  sysctl on macOS, `hw.machine` (`utsname.machine`) on iOS. Never `UIDevice.name`. The OS is
  `operatingSystemVersion`.

Kotlin (`android/inderun-kotlin/src/androidTest/.../SpeechBenchmarkTest.kt`):
- Same behaviour. Instrumentation arguments: `speechBenchmarkModelDir` and `speechBenchmarkOut`. Reports go to that
  directory on the device; `adb pull` fetches them.
- Peak RSS: poll `VmRSS` from `/proc/self/status` every 20 ms.
- `sdkVersion`: an androidTest `buildConfigField` from the Gradle `inderunVersion`.
- Device: `Build.MANUFACTURER + " " + Build.MODEL`. OS: `"Android " + Build.VERSION.RELEASE`.

Both:
- Move the report building (grouping, percentiles, JSON) into a small helper inside the test source set. Its
  percentile and grouping logic gets unit tests that are not gated.
- The existing `INDERUN-BENCH` log lines stay.
- A gated run that skips the neural target because the env var is absent still runs the system target as today.

### 5. iPhone numbers

Swift package tests do not run on a physical device. The iPhone harness is therefore the existing opt-in
`tools/neural-speech/ios_device_bench.sh` and `ios-device-bench.patch`. Both are changed:
- The hook goes through the public API instead of the runtime directly. It builds an `IndeRun` with the ONNX neural
  speech provider and `DefaultHostServices.make()`.
- It runs `first_call_after_prepare` and `render_speed` over the corpus utterances those scenarios name. It does not
  render `extendedUtterances`. The corpus is embedded in the patch as the ids and texts of exactly those utterances.
- `device` comes from `utsname.machine` (e.g. `iPhone15,4`), never from the device name.
- It writes `Documents/bench.json` in the `inderun-speech-benchmark/1` shape, with `harness: "ios_device_bench"`. The
  other five scenarios go in `skipped` with reason "not run by the device harness".
- The script copies `bench.json` back next to the text log. `--out` names the JSON file.

My call: running only two of the seven scenarios on the phone keeps the patch a single-file hook, with no Xcode
project edits. Those two answer the shipping question (prepare cost, cold/warm render, real-time factor, peak RSS).
The other five are measured on the Mac through `sdk_tests`.

The owner plugs in or unlocks the iPhone ("iPhone K") for this run. I ask when the code is ready.

### 6. Web Voices lab

In `packages/inderun-web-demo/src/voices-lab-panel.ts`:
- **Run corpus.** This button runs the seven scenarios against the selected model and voice, through the same
  `inderun` API the panel already uses. It shows progress, and at the end it downloads
  `speech-benchmark-<target>-<date>.json` with `harness: "web_voices_lab"`.
  - Playback scenarios play audio; the button's label says so.
  - `peakRssDeltaBytes` is omitted, because browsers expose no RSS.
  - `device` is the browser family and platform, from `navigator.userAgentData` when present, else a parsed UA. It
    is never the full UA string.
  - `sdkVersion` comes from `packages/inderun-web/package.json`.
- **Export.** This button downloads the last run's report. A checkbox, off by default, also includes the audio the
  lab rendered in this session as `audio: [{utteranceId?, voiceId, locale, mimeType, base64}]`. The schema allows
  `audio` as an optional property.
  - Voice prompt recordings are never included.
  - Nothing leaves the page unless the user clicks Export.
- The scenario runner lives in its own module, `voices-lab-benchmark.ts`, with happy-dom tests against a fake
  `inderun`. The tests check that the report validates against the schema, that each of the seven scenario ids is
  handled, and that the export without the checkbox has no `audio`.

### 7. Docs

- `docs/verification/neural-speech.md`: method, then a table of family × locale × platform × device.
  - Real cells: Mac (`sdk_tests`, ONNX Articulino int8), web (`web_voices_lab`, Chrome on this Mac) and iPhone 15
    (`ios_device_bench`).
  - `pending` cells: Android, every Core AI cell, and the families that are not yet implemented.
  - Every real number cites its report file.
  - The doc links #251, #252 and `system-speech.md`, so readers compare against the OS voice.
- `docs/verification/neural-speech-admission.md`: one row per catalog asset (weights, voices, frontend, runtime).
  Each row has the SPDX id, redistribution terms, GPL/NC/OpenRAIL flags and `review.status`, all taken from
  `neural-model-catalog.json`, plus the licence URL. It links #251 and #252.
- The family doc's "Timing" section points at `neural-speech.md`. Update `tools/neural-speech/README.md` and
  `CLAUDE.md`, because the script's output changes.

## Model package and who measures

- The int8 Articulino package for every real run is built locally with
  `tools/neural-speech/prepare_articulino_package.py`. Its inputs:
  - the ONNX release in `tmp/articulino-onnx`, checked against its `SHA256SUMS`;
  - one demo voice from `tmp/neural-speech-assets-1`, whose bytes match the catalog sha256.
  The package goes under `tmp/` and is never committed. The report's `target.checksums` records what ran.
- The agent runs the Mac and web measurements. These are timing numbers, not listening judgements. The web run uses
  the demo dev server in Chrome on this Mac. Nobody judges the audio there.
- Order: everything else lands first; the iPhone run is the last task. If the phone is not available by then, the
  iPhone cells say `pending`, no iPhone report is committed, and the PR status stays `Part of #276`.

## Rulings

- Ruling: ship ORT-only, Core AI cells `pending`. Why: spike 0b (#279) comes after this; the #279 commit fills the
  cells if the export works. Cost if wrong: none; the cells wait either way.
- Ruling: the iPhone runs 2 of 7 scenarios through the device harness. Why: no Xcode project edit and no device test
  target. Cost if wrong: a later device test target re-runs the other five.
- Ruling: `extendedUtterances` render under `render_speed`/`extended` in the neural targets only. Why: no eighth
  scenario, and system speech stays untouched. Cost if wrong: a rename in the reports.
- Ruling: commit real reports under `docs/verification/reports/`. Why: each cited number is checkable. Cost if wrong:
  delete a folder.

## Acceptance (from the issue) and expected status

- Gated Swift/Kotlin targets write the JSON; schema fixture and guard test. **Met.** Kotlin is compile-checked and
  unit-tested here; its device run is pending.
- Web lab "run corpus" plus export. **Met.**
- Corpus extension without changing the seven scenarios. **Met.**
- `neural-speech.md` and admission doc with real numbers from at least one iPhone and one Android device. **Partly
  met.** The iPhone is real; Android is `pending`. Hence `Part of #276`.

## Left to the builder

- Exact sentences of the extended corpus, within the categories above.
- Layout of the lab buttons, matching the panel's existing controls.
- Where the shared report helper sits in each test source set.
