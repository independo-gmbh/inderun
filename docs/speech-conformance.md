# Speech Conformance and Cross-Platform Validation

Text-to-speech is implemented three times, once per SDK (TypeScript, Swift, Kotlin), over one Rust route planner and
three system speech providers. This document says what proves those implementations agree, and what does not, in the
same three layers as [streaming-conformance.md](./streaming-conformance.md):

| | What it covers | Where it runs |
| --- | --- | --- |
| **Automated, shared** | Contracts, facade translation, routing, artifact lifecycle, locality provenance | CI, every push |
| **Automated, real engine** | That the platform synthesizer renders, stops and cleans up as the adapters assume | CI and local runs, per platform |
| **Real-device** | What a person hears, on real hardware and audio routes | A human, on a device |

---

## Shared fixtures

Each fixture below is read by every SDK that the third column names. A data-driven fixture is run case by case and any
difference fails; a scenario catalog has one handler per case id behind a guard test that fails when the ids differ.

| Fixture | What it holds | Loaded by |
| --- | --- | --- |
| [`facade/speech.json`](../contracts/fixtures/facade/speech.json) | `speak` / `generateSpeech` options and the exact `TaskRequest` each compiles to | `packages/inderun-web/src/facade/speech.test.ts`, `SpeechGenerationTests.swift`, `SpeechGenerationTest.kt` |
| [`facade/list-voices.json`](../contracts/fixtures/facade/list-voices.json) | `listVoices()` snapshots in, entries out | `packages/inderun-web/src/facade/speech.test.ts`, `SpeechGenerationTests.swift`, `SpeechGenerationTest.kt` |
| [`task-contracts/text-to-speech.json`](../contracts/fixtures/task-contracts/text-to-speech.json) | Valid speech requests, results and terminals, and requests the per-kind rules reject | `packages/contracts/src/task-contract-fixtures.test.ts`, `packages/inderun-web/src/core/task-profiles.test.ts`, `TaskContractFixtureTests.swift`, `TaskContractFixtureTest.kt` |
| [`execution/voice-locality.json`](../contracts/fixtures/execution/voice-locality.json) | The locality provenance a run reports for each provider type and voice | `packages/inderun-web/src/core/provenance.test.ts`, `SpeechGenerationTests.swift`, `SpeechGenerationTest.kt` |
| [`execution/artifact-lifecycle.json`](../contracts/fixtures/execution/artifact-lifecycle.json) | Scenario catalog: ranged reads, disposal, limits, discarded artifacts | `packages/inderun-web/src/core/artifacts.conformance.test.ts`, `ArtifactLifecycleConformanceTests.swift`, `ArtifactLifecycleConformanceTest.kt` |
| [`host/audio-output-lifecycle.json`](../contracts/fixtures/host/audio-output-lifecycle.json) | Scenario catalog: what the audio output host service guarantees at open, write, drain and stop | `packages/inderun-web/src/core/audio-output.conformance.test.ts` (fixture), `AudioOutputLifecycleConformanceTests.swift` (fixture and `AVAudioEngine`), `AudioOutputLifecycleConformanceTest.kt` (fixture), `AudioTrackAudioOutputConformanceTest.kt` (real `AudioTrack`, instrumented) |
| [`speech/neural-frontend.json`](../contracts/fixtures/speech/neural-frontend.json) | Text → sentences → grapheme token ids over an embedded vocab | `packages/inderun-web/src/providers/neural-speech/frontend.test.ts`, `NeuralSpeechFrontendTests.swift`, `SpeechTextFrontendTest.kt` |
| [`speech/german-frontend.json`](../contracts/fixtures/speech/german-frontend.json), [`speech/english-frontend.json`](../contracts/fixtures/speech/english-frontend.json) | Scenario catalogs: German and English speech text frontend, input text and locale in, spoken-form text out | `rust/inderun-route-core/src/speech_text/tests.rs`, `packages/inderun-web/src/providers/neural-speech/speech-text-frontend.conformance.test.ts` (WASM), `SpeechTextFrontendConformanceTest.kt` (Kotlin, through the JNI export), `SpeechTextFrontendConformanceTests.swift` (Swift, through the C export in the XCFramework) |
| [`speech/neural-speech-lifecycle.json`](../contracts/fixtures/speech/neural-speech-lifecycle.json) | Scenario catalog: commit placement, cancel, missing audio output, artifact cap, timing | `packages/inderun-web/src/providers/neural-speech/lifecycle.conformance.test.ts`, `NeuralSpeechLifecycleConformanceTests.swift`, `NeuralSpeechLifecycleConformanceTest.kt` |
| [`speech/articulino-pipeline.json`](../contracts/fixtures/speech/articulino-pipeline.json) | Articulino host math: letters, durations, frame condition, flow steps, decode and post-processing, long-sentence split, empty sentence, cancel between graphs, against scripted executor outputs | `packages/inderun-web/src/providers/neural-speech/articulino/pipeline.conformance.test.ts`, `ArticulinoPipelineConformanceTests.swift`, `ArticulinoPipelineConformanceTest.kt` |
| [`artifacts/media-artifacts.json`](../contracts/fixtures/artifacts/media-artifacts.json) | Valid and invalid `MediaArtifact` references | `packages/contracts/src/task-contract-fixtures.test.ts` |
| [`routing/planner-conformance.json`](../contracts/fixtures/routing/planner-conformance.json) | Planner inputs and exact plans, `text_to_speech` cases included | `rust/inderun-route-core/src/tests.rs`, `packages/inderun-route-core-wasm/test/conformance.mjs`, `RoutePlannerConformanceTests.swift`, `SharedCoreRoutePlannerConformanceTest.kt`, `packages/contracts/src/routing-conformance.test.ts` |
| [`provider/capability-snapshots.json`](../contracts/fixtures/provider/capability-snapshots.json) | Capability snapshots that must round-trip without gaining or losing a key | `packages/contracts/src/validators.test.ts`, `ProviderCapabilitySnapshotTests.swift` |
| [`speech/neural-model-catalog.json`](../contracts/fixtures/speech/neural-model-catalog.json) | The Voices lab demo catalog: entries, files, voices, checksums, review status | `packages/contracts/src/neural-model-catalog.test.ts` (shape) |
| [`speech/catalog-to-package.json`](../contracts/fixtures/speech/catalog-to-package.json) | Catalog entry to `ModelPackage` mapping: entry and ref in, exact package out | `packages/contracts/src/neural-model-catalog.test.ts` (with a reference mapping), `packages/inderun-web-demo/src/neural-catalog.test.ts`, `NeuralCatalogTest.kt` (`android/inderun-demo-app`), `NeuralCatalogTests.swift` (`IndeRunDemoTests`) |
| [`speech/utterance-corpus.json`](../contracts/fixtures/speech/utterance-corpus.json) | Real-audio corpus: German and English utterances, a refused locale, repeat and cancel scenarios | `packages/contracts/src/utterance-corpus.test.ts` (shape), `AppleSystemSpeechCorpusTests.swift`, `AndroidSystemSpeechCorpusTest.kt` (real engines) |

The Swift suites live in `ios/IndeRun/Tests/IndeRunTests/`; the Kotlin ones in `android/inderun-kotlin/src/test/`,
`android/inderun-core/src/test/` and `android/inderun-neural-speech/src/test/`, except the corpus test and the `AudioTrack` catalog run, which are instrumented (`android/inderun-kotlin/src/androidTest/`).

## Real engines

The utterance corpus is not a vector with expected bytes: two synthesizers never produce the same audio. Its tests check
what must hold everywhere instead:

- every utterance the host has a voice for renders to a WAV whose header, size and duration agree, reads back in
  ranges, and is gone after `disposeArtifact`;
- the unsupported locale is refused by routing on `speak` and `generateSpeech`, before any provider is entered;
- repeated renders give independent artifacts;
- a stop mid-utterance ends once as `cancelled`, a second registered speech provider is never asked to say the text
  again, and the next utterance plays.

- a long utterance's audio lasts in proportion to its text, so a render cut off after one chunk fails.

A locale the host has no voice for is skipped by id, never passed. The Apple suite runs in `swift.yml` on macOS and on an
iOS simulator; the Android suite runs in the `Android emulator speech` job ([docs/ci.md](./ci.md#real-speech-on-an-emulator)).
The Web has no real-engine suite: headless browsers list no voices, so browser behaviour is checked by hand.

## Latency scenarios

The corpus's `benchmark` section holds seven opt-in latency scenarios — cold first call, after `prepare()`, repeated
calls, a language switch, speaking after Stop, short against long text, and render speed. `SpeechBenchmarkTests.swift`
and `SpeechBenchmarkTest.kt` run them against a list of targets, so a future provider is compared by adding a target,
not by writing new scenarios. Each has a guard test that fails when its handler ids and the fixture's scenario ids
differ; the guard runs in CI, the scenarios do not. How to run them, and the recorded results, are in
[docs/verification/system-speech.md](./verification/system-speech.md#latency-scenarios).

## Known differences

These are by design and are part of each provider's declared capability, not drift:

- **Retrievable audio.** Apple and Android return `audio/wav`; the browser speech provider plays only, so
  `generateSpeech()` is refused there.
- **Locality.** The browser provider never satisfies `local_required` and reports locality `unknown`. Apple has no
  per-voice network flag; Android trusts the engine's.
- **Sample rate and voice names** differ per engine (22,050 Hz on the macOS compact voices, 24,000 Hz on Google TTS in
  the recorded runs).
- **`timing.firstAudioMs`** comes from each platform's own word callback, counted from the provider starting to handle
  the request, and is absent where the engine or browser sends none.

One gap is not by design: the Kotlin SDK does not yet round-trip `provider/capability-snapshots.json`, while TypeScript
and Swift do.

## Real-device checks

What a listener hears, real audio routes, interruptions, background and foreground, and browsers other than the one
recorded are checked by hand. The steps and every recorded result are in
[docs/verification/system-speech.md](./verification/system-speech.md); a step that has not been run is marked
**pending** there, never assumed.
