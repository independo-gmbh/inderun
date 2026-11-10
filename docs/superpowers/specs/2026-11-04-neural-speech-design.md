# #260 — On-device neural TTS: provider family, Core AI runtime, bilingual benchmark demo

Status: approved design (2026-11-04). Multi-PR programme, sequenced below; each phase lands value on its own
and the programme can stop after any of them. Implementation plans live in `docs/superpowers/plans/`.

## Context

Issue #260 asks for an opt-in DE/EN benchmark demo comparing five on-device neural TTS families
(Piper, Kokoro-82M, Articulino, Kyutai Pocket TTS, Supertonic 3) on real iOS and Android devices.
The product reason (this session): Independo's accessibility apps ship via Capacitor and get
recurring feedback that system voices sound bad. Goal: IndeRun as the apps' TTS engine, neural
voices as selectable options on capable devices, system voices as the reliable fallback
everywhere else, the fallback expressed declaratively through IndeRun routing, and the end user
still picks a specific voice. The same demo is the public "availability-resilient execution"
story (OS-shipped model → own model → system fallback) from the strategy page.

Strategy constraints (Notion 09 Strategy, ADR 007/008/013/014/019):

- Provider admission criterion 1 (an Independo product needs it) is satisfied.
- "TTS is not a reason to build a speech inference engine": two runtimes only — ONNX Runtime
  (already a dependency on all three platforms) and Apple Core AI (iOS/macOS 27+, owner's hard
  requirement). No GGUF/candle/ggml/MLX.
- IndeRun downloads and stores nothing (ADR 019 §5). Apps own model assets.
- Routing stays provider-agnostic in the shared Rust planner; profiles stay ordered allow-lists;
  no model ids on requests (api-layering).
- Effort rule: this is far beyond "a day a week"; it needs an owner.

Verified in code:

- Speech contracts (ADR 016–019), `speak()/generateSpeech()/listVoices()/prepare()` on all three
  SDKs, voice handles `{providerId, id}` with `preferred|required`, readiness, model profiles,
  provenance with locality.
- System speech providers on Web/Apple/Android; the OS synthesizer plays. **No host service plays
  raw PCM.** ADR 017 §7 forbids media bytes in stream events.
- ONNX family is `text_to_text` only; `ModelPackage.format` is `onnx|ort|genai`; `tasks` is a
  free string array; no voice/sample-rate/frontend fields; `ProviderVoice.locale` is one tag and
  the planner (`voice_fits`, `locale_rank`, `select_voice`, `locale_matches` in `planner.rs`)
  compares only it.
- Benchmarks: `SpeechBenchmarkTests.swift` / `SpeechBenchmarkTest.kt` with a `targets` list, the
  shared corpus `contracts/fixtures/speech/utterance-corpus.json`, log-line output only, no web.
- Demos: `ios/SampleApps/IndeRunDemo` (Speech tab, app-owned downloader `DemoOnnxModel.swift`),
  `android/inderun-demo-app` (speech section, `DemoOnnxModel.kt`), `packages/inderun-web-demo`
  (browser only, `VITE_*` flags in `config.ts`). Capacitor bridge (separate repo) has no speech
  (#250) and its `configure()` is JSON-only (#213).
- `Package.swift` floor iOS 16 / macOS 14 must not move; umbrella `IndeRun` re-exports only
  `IndeRunCore`; consumers import provider modules explicitly; the two consumer smoke test
  targets must not gain dependencies.

## Decisions

Owner (this session):

1. Both product path and five-family comparison.
2. Core AI is a hard requirement as the second runtime, iOS 27+, for one PyTorch-sourced model.

My calls (overridable):

3. **One neural speech provider class, pipelines per model family, executors per runtime.**
   `NeuralSpeechProvider` lives in a runtime-free module; a model package names a `pipeline`
   (text frontend + graph plan + PCM post-processing); the pipeline runs against a
   `SpeechGraphExecutor`; ORT and Core AI are the two executors. Five families = five pipelines;
   Core AI = one executor + packaging + specialization glue, not a second copy of anything.
4. **PCM playback is an optional host service** (`HostServices.audioOutput`) with default
   implementations per platform: OS access belongs in host services (CLAUDE.md §4.1), one place
   for "nothing audible after cancel", one definition of time-to-first-audible. ADR 017 §7 stays:
   no media chunks in events; streaming happens inside the playback path.
5. **No "neural" marker on the wire.** "Neural" is not a fact a provider can honestly assert
   (Apple premium voices are neural). The facade's `SpeechVoiceInfo` derives
   `kind: "platform" | "model"` from `descriptor.model`, which is the grouping the app needs.
6. **No GPL phonemizer.** Grapheme-input families first (Articulino, Supertonic 3). Phoneme
   families (Kokoro, Piper) wait for a non-GPL G2P increment (neural G2P ONNX on the same
   executor, or a ported lexicon/rule frontend), decided by a time-boxed spike.
7. **First model: Articulino DE/EN** — the only candidate meeting all four: Apache-2.0 code and
   weights, letter input with its own DE normalizer (no phonemizer), DE primary + EN present,
   PyTorch source for `coreai-torch`. Voices ship as precomputed speaker embeddings; the demo
   uses the upstream sample voice (in the Apache-2.0 package, author's consent); no cloning UI.
   Supertonic 3 is second and the fallback if the spike shows Articulino's ONNX graphs fail on
   mobile ORT.
7a. **Legal sign-off and own voice recordings are shipping concerns, not demo concerns.** The
   demo downloads weights at runtime from upstream after consent and redistributes nothing;
   evaluation use is within every candidate's licence. Catalog entries stay `benchmark_only`
   until a review marks them `admitted`; that review (OpenRAIL-M for Supertonic, CC-BY-4.0 +
   per-voice terms for Pocket TTS, voice licences for Piper) happens when Independo apps bundle
   or redistribute a model. No restricted weights are ever committed or bundled in this repo.
   Gated weights (Pocket TTS) cannot be fetched anonymously → catalog marks `manual_install`.
   Recording Independo's own consented German voices happens for the apps, later.
8. **Demo lives in the three existing demo apps** behind an opt-in "Voices lab" switch; the
   Capacitor reference app follows in the bridge repo after #250. All new configuration is
   JSON + file paths so the bridge can forward it.
9. **Catalog + downloads stay app-side**, with consent, size and licence shown before any fetch.

(Items 7, 7a and 8 confirmed by the owner in this session.)

## Architecture

### A. Contracts (`contracts/schemas/`, then `pnpm generate`)

`model-package.schema.json`:

- `format` gains `"coreai"` (Apple `.aimodel` bundle); the runtime seam switches on it like
  `onnx|ort` today.
- `variant` (optional string, e.g. `onnx-int8`, `coreai-fp16`); `id` stays the logical model and
  `license` the weights licence (strategy: identity/licence vs artifact variant).
- `runtime.minOsVersion` (optional string).
- `speech` (optional object; validators require it when `tasks` contains `text_to_speech`):
  - `pipeline`: open string (`$comment` lists `articulino`, `supertonic`, later `kokoro`,
    `piper`, `pocket_tts`). Not an enum: an enum would force schema + three-language codegen +
    `kotlin-enum-wire-values.mjs` churn per family; the provider refuses unknown values with
    `capability_unavailable: unsupported pipeline`.
  - `sampleRate` (required with `speech`), `channels`.
  - `graphs`: `{ role: file }` — roles defined by the pipeline (Articulino `text`, `dit_step`,
    `decoder`, with `encoder` and `voice` run offline by the tool; Supertonic `text_encoder`, `duration`, `estimator`, `vocoder`). Same map
    for ONNX files and `.aimodel` inference functions.
  - `frontend`: `{ kind: "grapheme" | "phoneme", assets: { role: file }, license? }`.
  - `voices[]`: `{ id, name, locales: [BCP47…] (minItems 1), gender?, file, license: {spdx,url} }`;
    `file` is the style/speaker tensor, so no speaker encoder runs on-device. Ids unique.
- Validation in `packages/contracts/src/validators.ts`, `ModelPackageValidation.swift/.kt`.

`provider-dynamic-capabilities.schema.json` — `ProviderVoice`: add optional `locales: string[]`
(`locale` stays required as the primary; the hand-patched Swift convenience init in
`IndeRunContracts/Compatibility.swift` stays valid; ADR 018 anticipated this).
`route-planner-input.schema.json` candidate voice gains the same `locales[]`; `planner.rs`
`voice_fits` / `locale_rank` / exact-region tiebreak in `select_voice` test `locale` or any of
`locales`. Regenerates `generated/contracts.rs` → `pnpm build:route-core-apple` + commit the
XCFramework and provenance in the same PR. New cases in
`contracts/fixtures/routing/planner-conformance.json` (multilingual voice bound for `en-US` and
`de-DE`; exact-region preference via `locales`).

`task-output.schema.json` — `PlaybackOutput` carries `timing`, a `PlaybackTiming` with optional
`durationMs`, `firstAudioMs` (first audible frame) and `firstChunkMs` (provider-measured first PCM
chunk), both counted from the provider starting to handle the request. Issue #260 wants both,
separately.

Facade (hand-written, all three SDKs): `SpeechVoiceInfo` gains `kind: "platform" | "model"` and
`model?: string` derived from the capability snapshot (`descriptor.model != null` → `model`).
Fixture case added to `contracts/fixtures/facade/speech.json`.

New fixtures: `speech/neural-frontend.json` (text → sentences → token ids per pipeline, embedded
mini vocab), `speech/neural-speech-lifecycle.json` (scenario catalog: commit-before-first-write,
cancel-while-waiting plays nothing, cancel mid-stream → one `cancelled` outcome, missing
`audioOutput` refuses before commit, artifact over cap fails before commit),
`speech/neural-model-catalog.json` (demo catalog, see E), `speech/benchmark-report.schema.json`
(validated by contracts tests, not codegen'd). Corpus additions with stable ids:
`de_de_aac_{hunger,help,yes,no}`, `de_at_aac_*`, `en_us_aac_*`, `en_gb_short`, `de_de_names`,
`en_us_names`, `de_de_mixed`, `en_us_mixed` (synthetic names only); category list in
`packages/contracts/src/utterance-corpus.test.ts`.

ADRs in `docs/architecture/decisions/`: `020-neural-speech-and-model-packages.md`,
`021-audio-output-host-service.md`, `022-core-ai-runtime.md` (includes the ADR 019 amendment:
a "compile" preparation that needs no download consent).

### B. Audio output host service (all three platforms)

`audioOutput?: AudioOutputService` on `HostServices` (`packages/contracts/src/host.ts`,
`ios/IndeRun/Sources/IndeRunCore/HostServices.swift`, `android/inderun-core/.../HostServices.kt`),
optional like `streamingHttpClient`.

```
AudioOutputService.open(format: {sampleRate, channels: 1, encoding: "pcm_s16le"}, signal?) -> AudioOutputSession
AudioOutputSession.write(samples)   // resolves once buffered (backpressure); first write = first possible audible effect
AudioOutputSession.drain()          // resolves when everything written has played
AudioOutputSession.stop()           // immediate, discards buffered audio, idempotent; nothing renders after it
AudioOutputSession.firstAudioMs()   // host observation of the first frame leaving the output, relative to open(); undefined until then; converted to the request-received origin before it is reported
```

Guarantees: `open()` makes no sound; a failed `open()` throws before commit (fallback-eligible);
the provider calls `context.commit()` immediately before the first `write()` and calls `stop()`
without writing when commit returns false; abort ≡ `stop()`. Defaults:
`AVAudioEngineOutputService` (`IndeRunCore/AppleHostServices.swift`; player node + tap for first
rendered frame; does **not** set the `AVAudioSession` category — the session stays app-owned, as
today), `AudioTrackOutputService` (`MODE_STREAM`, `USAGE_ASSISTANCE_ACCESSIBILITY`,
`CONTENT_TYPE_SPEECH`, `getTimestamp()`; no audio focus by default),
`createWebAudioOutputService()` (`packages/inderun-web/src/core/browser-host.ts`; lazy
`AudioContext`; suspended context → `Unavailable` `details.code: "audio_not_allowed"`, mirroring
`speech_not_allowed`). `createFixtureAudioOutput()` records writes for tests. Host without
`audioOutput`: the provider refuses a playback request before commit with `CapabilityMismatch`
`details.code: "audio_output_unavailable"` (ADR 016 §4) so the profile's system target takes
over. Flagged follow-up, not built: per-delivery availability on `ProviderTaskAvailability` so
the planner can reject earlier. `architecture.md` host-services section updated.

### C. Neural speech provider family

Ids `local.onnx.speech.web|apple|android`, `local.coreai.speech.apple` (same
`<placement>.<runtime>.<family>.<platform>` convention as `local.onnx.genai.*`); apps register
`<default>:<modelPackage.id>` per model, as the OpenAI factory does.

Options mirror `OnnxProviderOptions`: `{ id?, modelPackage, runtime?: NeuralSpeechRuntime,
timeoutMs? }`. Seams:

```
NeuralSpeechRuntime.availability(pkg) / prepare(pkg) -> {available, reason?}
NeuralSpeechRuntime.synthesize({pkg, text, locale, voiceId, signal}) -> AsyncIterable<PcmChunk>   // PcmChunk {samples s16le, sampleRate, isLast}
SpeechGraphExecutor.load(graphs: {role: path}); run(role, inputs: {name: SpeechTensor}) -> {name: SpeechTensor}   // SpeechTensor {shape, f32 | i64}
```

The default runtime = pipeline (from `speech.pipeline`, in `articulino/`, with the safetensors voice reader and the
`SpeechPackageFiles` seam) over an executor, composed per SDK in the ORT module; `createFixtureNeuralSpeechRuntime()`
emits deterministic tone chunks for tests and demos.

Descriptor: `type: local`, `transport: in_process`, `model: modelPackage.id`, `cancel: hard`
(audio stops at once; residual compute bounded to one chunk, never audible — doc comment),
`taskCapabilities: [{ kind: text_to_speech, inputs: [text], interaction: {prepare, run, stream},
outputs: [playback, artifact audio/wav], locales: union of voices[].locales }]`,
`privacy.dataLeavesDevice: false`. Capabilities: package validation → source type →
`runtime.availability` → remembered load failure → `readiness: cold` until loaded (pattern from
`OnnxRuntimeAppleProvider.capabilities`); voices from `speech.voices` with `locale = locales[0]`,
`locales`, `gender`, `networkRequired: false`; below `limits.memBytes` → `available: false` with
reason (the composed ONNX runtime on Apple and Android; the web has no host memory API). Execution: shared sentence splitter; per sentence run the pipeline and either write chunks
to the audio session (playback: commit before first write; `timing.firstChunkMs` from the pipeline,
`timing.firstAudioMs` from the sink, `timing.durationMs` from samples) or append to an `ArtifactWriter`
(WAV header + s16 chunks; stop at the existing 16 MiB cap before `finish()` — ≈5.5 min at
24 kHz; never resample up). `stream()` emits only `.result`, like
`AppleSystemSpeechProvider.stream`; one utterance at a time per instance (`SpeechTurns` pattern).
A cancelled run reports no `timing` today: every engine builds the cancelled playback output itself. A
provider-to-engine path for partial timing on cancel (how long played before the stop) is a follow-up of this PR.

Placement:

- Web: `packages/inderun-web/src/providers/neural-speech/{provider,runtime,frontend,wav,
  safetensors,ort-executor,onnx-runtime}.ts` and `articulino/{config,math,runtime}.ts`; subpath `./neural-speech` in `package.json`
  `exports`; `createIndeRunWeb({ neuralSpeech: [...] })` in `web-sdk.ts`; `onnxruntime-web` as
  an optional peer reached structurally, like `TransformersModule`; COOP/COEP headers already set
  by the web demo for WASM threads. `pnpm verify:packaging` covers the new subpath.
- Apple: new target + product `IndeRunNeuralSpeech` (`ios/IndeRun/Sources/IndeRunNeuralSpeech/`:
  `NeuralSpeechProvider.swift`, `NeuralSpeechRuntime.swift`, `SpeechGraphExecutor.swift`,
  `SpeechTextFrontend.swift`, `Safetensors.swift`, `SpeechPackageFiles.swift`,
  `Articulino/{ArticulinoConfig,ArticulinoMath,ArticulinoRuntime}.swift`, `PcmChunk.swift`,
  `FixtureNeuralSpeechRuntime.swift`, `Exports.swift` with `@_exported import IndeRunCore`);
  depends on `IndeRunCore` only. `OnnxSpeechGraphExecutor.swift` goes into
  `IndeRunOnnxProviders` (already links ORT and `SharedOnnxEnvironment`), which gains a
  dependency on `IndeRunNeuralSpeech`. `SpeechWAV` moves from `AppleSpeechRuntime.swift` to
  `IndeRunCore` as `public enum SpeechWAV`. `IndeRunTests` adds the new modules; smoke targets
  untouched.
- Android: new module `android/inderun-neural-speech` (`api(project(":inderun-core"))`);
  `OnnxSpeechGraphExecutor.kt` in `inderun-onnx-providers` with
  `api(project(":inderun-neural-speech"))`; `pnpm verify:android-api-deps --update`.

Parity: the two new fixtures above are loaded by a TS/Swift/Kotlin suite each with the guard-test
pattern from `docs/speech-conformance.md`. Docs: new
`docs/architecture/neural-speech-provider-family.md`, provider-matrix rows in `providers.md`
(two: ONNX speech, Core AI speech), fix the stale "carries no `taskCapabilities`" line in
`onnx-runtime-provider-family.md`, `api-layering.md` for `SpeechVoiceInfo.kind`, `CLAUDE.md` §3
scope line, package READMEs.

### D. Core AI module (Apple)

- `Package.swift`: target + product `IndeRunCoreAIProviders` at
  `ios/IndeRun/Sources/IndeRunCoreAIProviders/`, dependencies
  `["IndeRunNeuralSpeech", "IndeRunCore", "IndeRunContracts"]`; platforms unchanged. Files: `CoreAISupport.swift`,
  `CoreAIGraphReference.swift`, `CoreAITensorBridge.swift`, `CoreAISpeechGraphExecutor.swift`
  (`#if canImport(CoreAI)` … `@available(iOS 27, macOS 27, *)`; one `AIModel` per distinct file, one function per
  role), `CoreAINeuralSpeechRuntime.swift` (the composed runtime) and `CoreAINeuralSpeechProvider.swift`
  (`makeCoreAINeuralSpeechProvider(options:) -> NeuralSpeechProvider`, id `local.coreai.speech.apple`; in the `#else`
  branch and on older OS the runtime reports `available: false, reason: "Core AI requires iOS 27 / macOS 27"`, so demos
  compile on any Xcode and route to the system voice on older devices). There is no `CoreAIModelLoading.swift`.
- Readiness: `not_prepared` while any graph file is missing from `AIModelCache.default`, `cold` once every file is
  cached, `ready` after `prepare`. Only `prepare` specializes; there is no `fractionCompleted` because the API reports
  no progress. Specialization does require `autoDownload` / `allowDownload`, which reverses the earlier "needs no
  allowDownload" sentence of this spec: ADR 022 amends ADR 019 so that consent covers a long preparation, not only a
  download. Specialized artifacts are device+OS bound (documented).
- Conversion: the `coreai-torch` chain, the entrypoint names and the `text_mask` dtype are recorded in ADR 022 and in
  `docs/architecture/neural-speech-provider-family.md`; the asset hash, shape bounds and device numbers are pending
  spike 0b. Ships `bundled|app_managed`, never downloaded by IndeRun.
- CI (`swift.yml`): `canImport` keeps existing steps green; a step selects the newest Xcode on the runner and runs
  `swift build --target IndeRunCoreAIProviders`, `continue-on-error` until `macos-latest` has Xcode 27; executor tests
  skip unless macOS 27 + `INDERUN_COREAI_MODEL_DIR`. `docs/ci.md` updated.

### E. Routing, voice selection, fallback (no engine change expected)

Profile per app, e.g. `speech:resilient = [local.coreai.speech.apple:articulino,
local.onnx.speech.apple:articulino, apple_system_speech]` (Android/Web analogues).
`listVoices()` over the profile returns system and model voices with readiness; the app shows
`not_prepared` model voices with a download action. The user's chosen voice goes in as
`voice: {providerId, id, requirement: "preferred"}`; if its provider is unavailable on this
device (old OS, missing files, low memory, no `audioOutput`) the planner (or the pre-commit
refusal) falls through to the next provider in profile order and provenance records why.
`required` pins it and fails explicitly. The demo "model selector" is one single-target profile
per model — never a model id on the request.

### F. Demo ("Voices lab", opt-in) and benchmark

- Catalog `contracts/fixtures/speech/neural-model-catalog.json`: entries `{ id, family,
  pipeline, version, variant, license: {spdx, url, restrictions, attribution}, review: {status:
  benchmark_only|admitted|blocked|manual_install, notes}, runtime: {format, platforms, minOsVersion},
  sampleRate, files: [{role, path, url, sha256, bytes}], voices: [...] }`, each mapping 1:1 onto
  a `ModelPackage` (`source: app_managed`, `integrity.checksums`); shape-tested in
  `packages/contracts/src/`; copied to Android assets like the corpus. Nothing bundles all five.
- iOS: `VoicesLabScreen.swift`, `DemoNeuralModelDownloader.swift` (generalizes
  `DemoOnnxModelDownloader`: consent sheet with size + licence, sha256 check), registration in
  `DemoViewModel.swift` of one target per installed model plus profiles
  `voices-lab:<modelId>` = `[neural target, apple_system_speech]`. Android: `VoicesLabScreen.kt`,
  `DemoNeuralModelDownloader.kt`, wiring in `AndroidDemoRuntime.kt`. Web:
  `packages/inderun-web-demo/src/voices-lab-panel.ts` behind `VITE_INDERUN_VOICES_LAB=1`, models
  fetched into OPFS → `app_managed`. All opt-in (settings toggle / env). Controls per #260:
  language (de-DE, de-AT, en-US, en-GB) independent of model; model (+ "OS TTS (control)");
  voice grouped by `kind`; editable presets from the corpus; Speak/Stop/Repeat/A-B;
  download/warm with size + consent; status card (provider, model id/variant/hash, voice,
  resolved locale, locality, runtime, artifact-vs-playback); export.
- Benchmark: gated targets in `SpeechBenchmarkTests.swift` / `SpeechBenchmarkTest.kt` (skip
  unless `INDERUN_SPEECH_BENCHMARK_MODEL_DIR` points at a catalog entry); record `firstChunkMs`
  and peak RSS delta per sample; with `INDERUN_SPEECH_BENCHMARK_OUT` set, write
  `{ schema: "inderun-speech-benchmark/1", device, os, sdkVersion, target: {providerId, model,
  variant, checksums, voiceId}, requestedLocale, resolvedLocale, locality, samples, p50, p95 }`
  as JSON (schema in fixtures). Scenarios stay the seven existing ones so numbers remain
  comparable. Web benchmark = the lab page's "run corpus" button with a JSON download. The demo
  export writes the same shape plus optional audio samples.
- Results: `docs/verification/neural-speech.md` (family × locale × platform × device, `pending`
  cells) and `docs/verification/neural-speech-admission.md` (per asset: weights, voices,
  frontend, runtime; SPDX; redistribution; GPL/NC/OpenRAIL flags; review status). Links to #251
  and #252.

### G. Model families — order and admission notes

| Order | Family | Why here | Record as blocker |
| --- | --- | --- | --- |
| 1 | Articulino DE/EN | Apache-2.0, DE-first, grapheme, ONNX + PyTorch (Core AI) | EN limited; consented clips needed for more voices; DE normalizer port with fixtures; `torch.export` unproven |
| 2 | Supertonic 3 | grapheme, 31 languages, preset voices, iOS/Swift sample, fast | OpenRAIL-M weights + archived upstream → legal/maintenance review before `admitted`; ONNX only |
| 3 | Kokoro-82M (EN + kikiri DE Martin/Victoria) | best-known quality, Apache-2.0, PyTorch | non-GPL phonemizer reproducing the espeak-ng/misaki convention; separate DE/EN checkpoints |
| 4 | Piper | tiny, many DE voices | espeak-ng GPL → same G2P increment; per-voice licences; lower quality |
| 5 | Pocket TTS | streaming LM | CC-BY-4.0 gated weights, per-voice licences, community-only ONNX, ~1× realtime on Pixel 8a; may end "documented unavailable" |

## Phases / PRs

| PR | Scope | Effort | Depends on |
| --- | --- | --- | --- |
| 0 | Spikes (throwaway, not merged): (a) Articulino + Supertonic ONNX graphs on one iPhone and one Android via scripts — op support, int8 status, RTF; (b) `coreai-torch` export of Articulino. Findings into the family doc; confirm first family | 3–5 d | — |
| 1 | Contracts + planner `locales` + facade `kind` + fixtures + ADR 020 (XCFramework rebuild + provenance) | 2–3 d | — |
| 2 | `audioOutput` host service ×3 + defaults + fixture + ADR 021 | 3–4 d | 1 |
| 3 | Neural speech family (first step: move `getModelPackageValidationIssues` into Core and add the structural speech rules natively): modules ×3, provider, seams, fixture runtime, parity fixtures, family doc, matrix rows | 5–7 d | 1, 2 |
| 4a | ORT executors ×3 + Articulino pipeline + safetensors voices + preparation tool + env-gated real-model tests | 5–8 d | 0, 3 |
| 4b | German frontend: pre-split hook; numbers, ordinals, decimals, times, dates (incl. Jänner), money, units, abbreviations, acronyms, digit fallback | 3–5 d | 4a |
| 5 | Core AI module + CI step + conversion record + ADR 022 (ADR 019 amendment) | 4–6 d | 0b, 3, 4a (reuses its pipeline and seams; parallel with 4b) |
| 6 | Catalog + downloaders + Voices lab ×3 | 5–7 d | 4a |
| 7 | Corpus extension + benchmark targets + JSON export + verification docs + first device numbers (ORT vs Core AI on the same iPhone) | 3–4 d | 4a, 5 |
| 8 | Supertonic 3 pipeline (`benchmark_only` until legal sign-off) | 3–4 d | 4a |
| 9 | Non-GPL G2P increment + Kokoro pipeline (DE + EN) | 10–15 d | 4a |
| 10 | Piper pipeline (reuses G2P) | 3–5 d | 9 |
| 11 | Pocket TTS viability spike → implement or document unavailable | 3–8 d | 4a |
| 12 | Device campaign (one Apple-Intelligence iPhone, one older iPhone, one midrange Android), listening scores per locale, write-up | ongoing | 7+ |
| 13 | Capacitor bridge (bridge repo, after #250): `configure({speech:{models:[{modelPackage, runtime:"onnx"|"coreai"}]}})`, `listVoices`, `speak/stopSpeaking`, `prepare` | separate | 6 |

PR 0–8 ≈ 7–10 weeks for one person; 9–12 add roughly the same again.

## Verification

- `pnpm generate` then `git diff --exit-code` on generated outputs; `pnpm verify:enum-wire-parity`;
  `pnpm verify:packaging` (new subpath).
- `pnpm test:js`, `swift test`, `cd android && ./gradlew test`, `cargo test -p inderun_route_core`,
  `pnpm verify:android-api-deps`, `pnpm verify:route-core-apple` after the XCFramework rebuild.
- Guard tests: frontend/lifecycle fixture ids, benchmark scenario ids, catalog entries validate
  against the model-package schema, report JSON validates against its schema.
- Real engine: `swift test` with `INDERUN_SPEECH_BENCHMARK_MODEL_DIR` runs the corpus on ORT;
  `./gradlew :inderun-kotlin:connectedAndroidTest` on a device; JSON reports produced on both.
- Demo apps on devices: audio plays; stop mid-utterance leaves nothing audible; removing the
  model files makes the same request fall back to the system voice with provenance saying so;
  Core AI path on an iOS 27 iPhone vs ORT on the same phone.
- Privacy: airplane mode under `local_required`, network inspection, provenance `on_device`.

## Risks and open items

- `torch.export`/`coreai-torch` of Articulino (dynamic shapes, custom ops) — PR 0b spike; the ORT
  path does not depend on it. If it fails, the Core AI model becomes Kokoro after PR 9.
- Mobile ORT op coverage for int8 graphs — fall back to fp16/fp32, CPU EP.
- Core AI first-load specialization time vs ADR 019 consent model — ADR 022 amendment.
- Non-GPL phonemizer for Kokoro/Piper is real work; German must match the kikiri convention.
- Supertonic OpenRAIL-M + archived upstream: benchmark yes, product use needs sign-off.
- Audio session ownership stays with the app (ducking, interruptions: reuse the
  `speech_interrupted` observer); Web `AudioContext` gesture requirement.
- 16 MiB artifact cap bounds long passages in artifact mode only.
- CI runner Xcode version for Core AI; device runs are the source of truth.
- Programme size vs the effort rule — needs an owner.

## Out of scope

Voice cloning UI, STT, Mode 3, GGUF/candle/MLX runtimes, IndeRun-owned downloads or a model hub,
per-request speaking rate (ADR 018 §3a, separate follow-up), media chunks in stream events,
per-delivery availability in capabilities (flagged follow-up), text-to-text streaming parity
(milestone 6).
