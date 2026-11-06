# Voices Lab (PR 6) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The three demo apps get an opt-in "Voices lab" that downloads the Articulino model and the seven own
voices with consent and checksums, and speaks them next to the OS voice.

**Architecture:** A shared catalog fixture describes downloadable model packages; a Python tool builds the derived
assets (int64-mask `text.onnx`, voice bundles from committed seeds) and the catalog's file entries; each demo maps a
catalog entry onto a `ModelPackage` (`app_managed`), downloads it after consent, registers one neural target plus a
`voices-lab:<modelId>` profile, and drives it through public SDK APIs only. The web demo reaches GitHub release
assets through a demo-proxy route because GitHub sends no CORS.

**Tech Stack:** Python 3.13 tooling; TypeScript/Vite + Vitest + OPFS; SwiftUI + XCTest; Kotlin/Compose + JUnit.

**Spec:** `docs/superpowers/specs/2026-11-06-voices-lab-design.md` (read in full, including "Settled after the builder
check"); parent `docs/superpowers/specs/2026-11-04-neural-speech-design.md` §E–§F.

## Global Constraints

- Commit only the seven `*.seed.wav` seeds (ids `de-at-m-1`, `de-at-m-1-alt`, `de-at-m-2`, `de-de-f-1`, `de-de-f-2`,
  `de-de-f-3`, `en-us-f-1`), to `tools/neural-speech/voice-seeds/`. Never commit `candidates/`, `*.hop1.safetensors`,
  `*.check-hop*.wav`, voice bundles, ONNX files or recordings; never write recording file names into the repository.
- Upstream: `eigenhand/Articulino-DE-EN-Realtime-Stream-TTS-ONNX` at revision
  `a760ce8d513534111c7679751869fa4c45ef0e54`, URLs
  `https://huggingface.co/eigenhand/Articulino-DE-EN-Realtime-Stream-TTS-ONNX/resolve/<rev>/<path>`.
- Derived assets: GitHub release tag `neural-speech-assets-1` on `independo-gmbh/inderun`, URLs
  `https://github.com/independo-gmbh/inderun/releases/download/neural-speech-assets-1/<name>`. Do not create or
  upload the release; the tool prints the `gh release create` command for the owner.
- Package layout and checksum keys: `config.json`, `text.onnx`, `dit_step.onnx`, `decoder.onnx`,
  `voices/<id>.safetensors`. Entry id `articulino-de-en-int8`, version `1`, variant `onnx-int8`.
- Voices licence: `spdx: "LicenseRef-Independo-Demo-Voices"`, restrictions "demo and evaluation use; consented
  speakers; legal sign-off pending (#260)"; entry `review.status: "benchmark_only"`. Weights: Apache-2.0, upstream
  NOTICE attribution.
- Consent before any request; sha256 + byte size checked after each file; a mismatch deletes the file and fails with
  `checksum mismatch: <path>`; all-or-nothing per entry; resume skips verified files.
- The lab is opt-in on every demo (iOS settings toggle, Android settings toggle, web `VITE_INDERUN_VOICES_LAB=1`) and
  uses public SDK APIs only; no SDK source changes in this PR.
- Branch `feat/m5-voices-lab` off `dev`; PR into `dev`; Conventional Commits; trailers
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_01HKCoLXyV9eTB812cpAucTi` last.
- Formatting: Prettier, `swiftlint lint --strict` where the demo is linted, `./gradlew spotlessApply`.

## Review Focus

1. A download interrupted half-way and resumed: verified files are kept, the rest re-fetched; no half file is ever
   accepted (Tasks 4–6 downloader tests `resume_skips_verified_files`, `partial_file_is_not_accepted`).
2. Storage full or quota exceeded during download (OPFS quota, iOS/Android disk): a clear error, partial files removed
   (Tasks 4–6 `storage_error_is_reported`).
3. Consent declined: no network request at all (Tasks 4–6 `declined_consent_makes_no_request`).
4. The lab switched off: no catalog fetch, no provider registration, demo unchanged (Tasks 4–6).
5. Proxy misuse: the asset route refuses any URL not in the catalog and never forwards request headers such as
   cookies (Task 3 `refuses_unlisted_url`, `strips_request_headers`).

---

### Task 1: Seeds, asset tool, catalog

**Files:**
- Create: `tools/neural-speech/voice-seeds/{<id>.seed.wav ×7,README.md}`, `tools/neural-speech/build_demo_assets.py`,
  `tools/neural-speech/test_build_demo_assets.py`, `contracts/fixtures/speech/neural-model-catalog.json`
- Modify: `tools/neural-speech/README.md` ("Build the demo assets"), `CONTEXT.md` §6 (command line)

**Interfaces:**
- Produces: CLI `build_demo_assets.py --models <onnx-release-dir> --seeds tools/neural-speech/voice-seeds --out <dir>
  [--catalog contracts/fixtures/speech/neural-model-catalog.json]`: writes `<out>/text.onnx` (rewritten),
  `<out>/<id>.safetensors` ×7, `<out>/SHA256SUMS`, updates the catalog entry's `files`/`voices` (url, sha256, bytes),
  prints the `gh release create neural-speech-assets-1 <out>/* --title ... --notes ...` command.
- Catalog shape per spec ("Catalog shape" + settled 3, 5, 9): entries `articulino-de-en-int8` (ONNX) and
  `articulino-de-en-coreai` (`manual_install`, no files/voices).

- [ ] Copy the seven seeds from `tmp/voice-seeds-2026-11-05/` (seeds only); README per spec settled 6.
- [ ] Tests (stub `VoiceTool` and the graph rewrite as `test_prepare_coreai_package.py` does): files and SHA256SUMS
  written; catalog entries updated with the exact URL pattern; refuses a seed id that is not a valid voice id; never
  reads outside `--seeds`; printed command lists every output file.
- [ ] Implement, reusing `prepare_articulino_voice.VoiceTool` and `rewrite_text_graph.rewrite_text_mask_to_int64`.
- [ ] Run the tool once for real against `tmp/articulino-onnx` (output under the session scratchpad, not the repo) so
  the committed catalog carries real sha256/bytes; `tools/neural-speech/.venv/bin/python -m unittest discover -s
  tools/neural-speech -p 'test_*.py'` → OK. Commit `feat(tools): build the neural speech demo assets and catalog`.

### Task 2: Catalog contract and package mapping fixture

**Files:**
- Create: `packages/contracts/src/neural-model-catalog.test.ts`, `contracts/fixtures/speech/catalog-to-package.json`
  (`{ "$comment", "cases": [{ "id", "entry", "ref", "expected" }] }`, at least: the ONNX entry with ref
  `voices-lab/articulino-de-en-int8/1`, and an entry with one voice)
- Modify: `docs/speech-conformance.md` (two rows)

- [ ] Shape test per spec Testing §1 (and settled 9 for `manual_install`). Mapping cases written by hand from spec
  settled 3. Commit `test(contracts): pin the neural model catalog and its package mapping`.

### Task 3: Demo proxy asset route

**Files:** Modify `packages/inderun-demo-proxy/src/{server.ts,handler.ts,config.ts}`, tests next to them, README.

**Interfaces:** `GET /assets?url=<encoded catalog url>` → streams the upstream body with `Content-Type`,
`Content-Length`, `Access-Control-Allow-Origin: <configured demo origin>`; 403 for a URL not in the catalog's file
and voice URLs; follows the GitHub redirect server-side; never forwards client headers.

- [ ] Tests (fake upstream server as `server.test.ts` does): listed URL streamed with CORS; unlisted 403; client
  cookie/authorization not forwarded; upstream 404 passed through as 404. Implement; `pnpm --filter
  @independo/inderun-demo-proxy test`. Commit `feat(demo-proxy): forward catalog assets for the web Voices lab`.

### Task 4: Web Voices lab

**Files:** Create `packages/inderun-web-demo/src/{voices-lab-panel.ts,voices-lab-panel.test.ts,neural-catalog.ts,
neural-catalog.test.ts,opfs-package-files.ts,opfs-package-files.test.ts}`; modify `src/app.ts`, `src/config.ts`,
README.

**Interfaces:** `catalogEntryToModelPackage(entry, ref): ModelPackage` (runs the Task 2 fixture);
`downloadEntry(entry, { fetch, storage, consent, onProgress })`; `createOpfsPackageFiles(dir): SpeechPackageFiles`;
`mountVoicesLabPanel(root, inderun, options)`; GitHub URLs go through `<proxy>/assets?url=`, Hugging Face direct.

- [ ] Tests: mapping fixture; downloader (Review Focus 1–3 with fake fetch/storage); panel DOM tests (lab off → no
  fetch; controls of spec "Goals"; A/B runs neural then control). Implement; `pnpm --filter
  @independo/inderun-web-demo test && pnpm lint && pnpm format:check:js && pnpm build`. Commit
  `feat(web-demo): add the opt-in Voices lab`.

### Task 5: Android Voices lab

**Files:** Create `android/inderun-demo-app/src/main/kotlin/app/independo/inderun/demo/{VoicesLabScreen.kt,
DemoNeuralModelDownloader.kt,NeuralCatalog.kt}`, tests in `src/test/...`; modify `AndroidDemoRuntime.kt`,
`DemoSettingsStore.kt`, `DemoScreen.kt`, `build.gradle.kts` (catalog asset copy and `:inderun-neural-speech` if not
reachable transitively).

- [ ] Tests: mapping fixture; downloader (Review Focus 1–3, fake transport, temp `filesDir`); view-model tests (lab
  off → no registration; profile `voices-lab:articulino-de-en-int8` = `[neural target, android system speech]`).
  Implement; `cd android && ./gradlew spotlessApply :inderun-demo-app:testDebugUnitTest spotlessCheck` and
  `:inderun-demo-app:assembleDebug`. Commit `feat(android-demo): add the opt-in Voices lab`.

### Task 6: iOS Voices lab

**Files:** Create `ios/SampleApps/IndeRunDemo/IndeRunDemo/{VoicesLabScreen.swift,DemoNeuralModelDownloader.swift,
NeuralCatalog.swift}` and a demo unit-test target `IndeRunDemoTests` (project file); modify `DemoViewModel.swift`,
`ContentView.swift`, the project (catalog resource, test target).

- [ ] Tests (new target): mapping fixture; downloader (Review Focus 1–3, fake `URLSession` protocol, temp dir);
  view-model registration (lab off → none; profile `[neural target, apple_system_speech]`). Implement; `xcodebuild
  test -project ios/SampleApps/IndeRunDemo/IndeRunDemo.xcodeproj -scheme IndeRunDemo -destination
  "platform=iOS Simulator,name=iPhone 17 Pro"` and a device build. Commit `feat(ios-demo): add the opt-in Voices lab`.

### Task 7: Docs

- [ ] Family doc (demo section), `docs/ci.md` if demo tests are new CI steps, READMEs of the three demos and
  `tools/neural-speech`, `docs/migration.md` (nothing user-facing: say so only if a section expects it), CONTEXT.md §3
  one clause. Commit `docs: describe the Voices lab and the neural model catalog`.

### Task 8: Verification and PR

- [ ] `pnpm test:js && pnpm lint && pnpm format:check && pnpm build && (cd android && ./gradlew test spotlessCheck)
  && swift test --skip AudioOutputLifecycleConformanceTests` plus the Task 6 `xcodebuild test`; squash; push; PR into
  `dev` whose body lists the owner's `gh release create` command and the manual phone check list.
