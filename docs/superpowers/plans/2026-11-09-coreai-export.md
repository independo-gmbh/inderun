# Core AI Export Follow-through Implementation Plan (#279)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Swift Core AI runtime run the exported `articulino.aimodel` without crashing, then publish the
conversion record. Next, give the catalog's Core AI entry its files. Finally, measure Core AI against ONNX on the Mac
and on the iPhone.

**Architecture:** Spike 0b exported Articulino to one `.aimodel` with three entrypoints. The findings are in
`tmp/coreai-spike/findings.md`, which is not committed. Three findings bind the executor:
- the asset's integer inputs are int32, and int64 aborts the process;
- Core AI does not enforce shape bounds;
- the first call for each function or shape is slow.

The executor narrows integers, checks bounds before every run and warms up in `prepare`. The asset itself is never
committed. The catalog points at a release that the owner publishes.

**Tech Stack:** Swift 6 with Apple CoreAI (iOS 27 / macOS 27), XCTest, Python package tools, JSON fixtures, Markdown docs.

**Spec:** issue #279 ("Exit: Works"), ADR 022, and the spike record `tmp/coreai-spike/findings.md`.

## Global Constraints

- Never commit the `.aimodel`, weights, voice bundles or anything under `tmp/`.
- No invented numbers. A cell without a real measurement says `pending`.
- Core AI bounds for the Articulino asset: `text` N in [1, 257], `dit_step` L in [1, 1024], `decoder` F in [1, 1036].
  Batch is 1. `voice_cache` is exactly [8, 2, 1, 6, 125, 64].
- The Core AI executor never hands Core AI an int64 `NDArray`. An integer outside the int32 range throws a mapped
  error and never traps.
- The catalog Core AI entry stays `review.status: "manual_install"` until the owner publishes `neural-speech-assets-2`.
  Its asset URLs point at `https://github.com/independo-gmbh/inderun/releases/download/neural-speech-assets-2/<file>`.
- Asset files (the tmp/coreai-spike/articulino.aimodel directory):
  - `main.mlirb`: 274,359,722 bytes, sha256 `7deb5fbe2f5fd68fd2a7ebd516628e9fc50e71bb26af494326a1c324413d4a26`
  - `main.hash`: 32 bytes, sha256 `159aa9c3a574b506da83d34d4897ec961f07dfb9c2ce5cc2164a1e53eb84c3b2`
  - `metadata.json`: 105 bytes, sha256 `f4eb9a49e2b53190118a819eee32ae8ece68f66d91e87d4a5363ef5bb74d9187`
- Changing a provider's behaviour updates its Provider Matrix row and the family doc in the same issue commit
  (CLAUDE.md §8).
- Commits use Conventional Commits with scope `speech`, the subject ends in `(#279)`, and the trailer is
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Check every command's exit status directly.

## Review Focus

1. A single word longer than 256 letters (no separator) must give a mapped error, not wrong audio and not a crash.
   Test: Task 1, `testTextLongerThanTheBoundThrows`.
2. A very slow speed setting that pushes L above 1024 must give a mapped error before Core AI runs. Test: Task 1,
   `testFramesAboveTheBoundThrow`.
3. A failed warm-up in `prepare` must report unavailable with a reason and must not leave a half-loaded runtime. Test:
   Task 1, `testWarmUpFailureReportsUnavailable`.
4. If the catalog Core AI entry is downloaded before the release exists, the download fails with the proxy's "asset
   not published yet" message. Test: covered by the existing proxy and downloader tests; Task 2 confirms they cover
   it.
5. A purged specialization cache after an OS update must make `prepare` re-specialize. This behaviour exists; Task 1
   must not regress it (the existing test keeps passing).

---

### Task 1: Core AI executor fixes and the Core AI benchmark target

**Files:**
- Modify: `ios/IndeRun/Sources/IndeRunCoreAIProviders/CoreAITensorBridge.swift`. `makeNDArray` turns `.i64` into an
  int32 `NDArray`, and a value outside the Int32 range throws `NeuralSpeechRuntimeError` (kind `internalFailure`,
  message `tensor value out of int32 range`). Update the doc comments that say "f32 or i64".
- Modify: `CoreAISpeechGraphExecutor.swift` and/or `CoreAINeuralSpeechRuntime.swift`. Before each run, the
  Articulino roles check their bounds: `text` checks `text_ids` axis 1 ≤ 257, `dit_step` checks `x` axis 1 ≤ 1024,
  and `decoder` checks `latents` axis 1 ≤ 1036. A violation throws `NeuralSpeechRuntimeError` with kind
  `invalidInput` if that kind exists; otherwise use the kind the runtime uses for a text it cannot speak. The message
  is `input exceeds the Core AI bound: <role>.<name> <n> > <max>`. Keep the bounds in one table keyed by role and
  input name, with a comment citing #279.
- Modify: `prepare`. After specialization succeeds, run one warm-up per function at the minimum shapes (N=2, L=2,
  F=2), with zero inputs of the declared dtypes. A warm-up error makes `prepare` report unavailable with
  `reason: "warm-up failed: <role>: <message>"`.
- Modify: `ios/IndeRun/Tests/IndeRunTests/SpeechBenchmarkTests.swift`. Add a Core AI target. When
  `INDERUN_COREAI_MODEL_DIR` points at a Core AI package directory, the target name is `articulino_coreai`, built
  with `NeuralSpeechProvider` over `CoreAINeuralSpeechRuntime`, with `DefaultHostServices`. `model` comes from
  `INDERUN_SPEECH_BENCHMARK_MODEL_ID_COREAI`, defaulting to the package id. Everything else matches the ONNX target.
- Test: the existing Core AI test files in `ios/IndeRun/Tests/IndeRunTests/`. Find them with
  `rg -l CoreAI ios/IndeRun/Tests`.

- [ ] Step 1: Write the failing tests:
  - `testInt64InputsAreNarrowedToInt32`, which asserts the NDArray scalar type is `.int32` with the same values;
  - `testInt64OutsideInt32RangeThrows`;
  - `testTextLongerThanTheBoundThrows`, with N=258;
  - `testFramesAboveTheBoundThrow`, with L=1025 and F=1037;
  - `testBoundsAllowTheMaximum`, with N=257, L=1024 and F=1036. It reaches the run through the existing executor test
    seam, so the bound check alone is tested;
  - `testPrepareWarmsUpEachFunctionOnce`;
  - `testWarmUpFailureReportsUnavailable`.

  Use the test seams the runtime already has (`specialize` injection and the executor factory). Where a test needs
  the real framework, gate it with `#if canImport(CoreAI)` and `@available`, as the existing Core AI tests do.
- [ ] Step 2: `swift test --filter CoreAI` → FAIL.
- [ ] Step 3: Implement.
- [ ] Step 4: Run each of these:
  - `swift test --filter CoreAI` → PASS;
  - `swift test --filter SpeechBenchmark` → PASS, with the gated test skipped;
  - `cd ios/IndeRun && swiftlint lint --strict` → exit 0.
- [ ] Step 5: Real asset smoke check, using the uncommitted asset. The controller builds the package in
  `tmp/coreai-package` with `tools/neural-speech/prepare_coreai_package.py` before dispatch. Run
  `INDERUN_COREAI_MODEL_DIR=$PWD/tmp/coreai-package swift test --filter CoreAINeuralSpeechRealModel`. If that test
  does not exist, add a gated one mirroring `OnnxNeuralSpeechRealModelTests`: it speaks a German sentence and
  asserts audio of 1–6 s with RMS > 300. Expected: PASS, with no SIGABRT.
- [ ] Step 6: Commit `fix(speech): run the exported Core AI asset: int32 inputs, shape bounds, warm-up (#279)`.

### Task 2: Catalog entry, package tool and release prep

**Files:**
- Modify: `contracts/fixtures/speech/neural-model-catalog.json`, entry `articulino-de-en-coreai`. Add `files` for
  the three asset files under path `articulino.aimodel/<file>`, plus `config.json`, with the URL, sha256 and bytes of
  each. Its voices are the same seven as the int8 entry, with the same URLs. `review.notes` reads: "Exported in spike
  0b (#279). The asset is published in neural-speech-assets-2 by the owner; until then install it by hand."
- Modify: `packages/contracts/src/neural-model-catalog.test.ts`, `contracts/fixtures/speech/catalog-to-package.json`
  if the mapping needs a directory asset case, and each demo's `catalogEntryToModelPackage` only where the
  catalog-to-package fixture requires it.
- Modify: `tools/neural-speech/prepare_coreai_package.py` and its tests, only if the directory asset is not already
  handled (the spike says it is).
- Create: `tools/neural-speech/coreai-release/NOTICE-MODIFICATIONS.md`. It is the modification note for the
  Apache-2.0 derivative: the stages are re-traced with `torch.export`, the iSTFT is rewritten as a matmul with
  shifted adds, and the time-embedding frequencies are baked in. It names the upstream commit `66f79f60` and the
  weights revision `38ad5471`.

- [ ] Step 1: Write the failing tests. The catalog test asserts that the Core AI entry has files with sha256 and
  bytes, that every asset file path starts with `articulino.aimodel/`, and that the URLs point at
  `neural-speech-assets-2`. The catalog-to-package fixture case maps the entry onto a `coreai` ModelPackage whose
  `integrity.checksums` hold those files.
- [ ] Step 2: `pnpm --filter @independo/inderun-contracts test` → FAIL.
- [ ] Step 3: Implement. Run the demo test suites that consume the catalog: `pnpm --filter @independo/inderun-web-demo test`,
  the Swift demo test target (`xcodebuild test`, iOS simulator, as in swift.yml) and `:inderun-kotlin:testDebugUnitTest`.
  Kotlin and the web lab must still show the entry as unavailable on their platforms.
- [ ] Step 4: Run `pnpm --filter @independo/inderun-contracts test`, `pnpm test:js` and `pnpm format:check` → exit 0.
- [ ] Step 5: Commit `feat(speech): list the exported Core AI asset in the catalog (#279)`.

### Task 3: iPhone harness runs a Core AI package

**Files:**
- Modify: `tools/neural-speech/ios-device-bench.patch`. The patch may now also touch
  `ios/SampleApps/IndeRunDemo/IndeRunDemo.xcodeproj/project.pbxproj` to link the `IndeRunCoreAIProviders` product
  for the duration of the run.
  - The hook picks `CoreAINeuralSpeechRuntime` when the package's `runtime`/format is `coreai`, otherwise
    `OnnxNeuralSpeechRuntime`.
  - The target name is `articulino_coreai` or `articulino_onnx-<variant>`.
  - Everything else is unchanged.
- Modify: `tools/neural-speech/ios_device_bench.sh` (it reverts both files) and `README.md`.

- [ ] Step 1: Regenerate the patch the same way as before: apply it, edit both files, `git diff -- <both> > patch`,
  then check out both files.
- [ ] Step 2: Verify:
  - `git apply --check`;
  - the generic-simulator build with the patch applied → `BUILD SUCCEEDED`;
  - revert, and confirm both files are clean;
  - `bash -n`.
- [ ] Step 3: Commit `feat(speech): let the iPhone harness run a Core AI package (#279)`.

### Task 4: Measurements (controller, inline)

- [ ] Mac: run `INDERUN_SPEECH_BENCHMARK=1 INDERUN_COREAI_MODEL_DIR=$PWD/tmp/coreai-package INDERUN_SPEECH_BENCHMARK_MODEL_ID_COREAI=articulino-de-en-coreai INDERUN_SPEECH_BENCHMARK_OUT=... swift test --filter SpeechBenchmarkTests`.
  Commit only the `articulino_coreai` report, replacing nothing else.
- [ ] iPhone: ask the owner to unlock the phone, then run `ios_device_bench.sh --package tmp/coreai-package --model-id articulino-de-en-coreai ...`.
  Commit the report. If the device is not available, those cells say `pending`.
- [ ] Run the guard test → PASS. Commit `docs(speech): add Core AI benchmark reports (#279)`.

### Task 5: Conversion record and docs

**Files:** `docs/architecture/decisions/022-*.md` (§ conversion record: replace the "Pending the export spike"
paragraph), `docs/architecture/neural-speech-provider-family.md` ("Core AI runtime" and "Spike and device findings"),
`docs/architecture/providers.md` (Core AI row), `docs/verification/neural-speech.md` (the Core AI column and tables
from the committed reports), `docs/verification/neural-speech-admission.md` (Core AI asset row) and
`tools/neural-speech/README.md` (the export procedure, pointing at the record).

- [ ] Write the record from `tmp/coreai-spike/findings.md`:
  - the verdict and per-stage status;
  - the pinned commits, revisions and versions;
  - the install-file review and the binary-wheel note;
  - the three wrapper changes;
  - the shape bounds and the int32 note;
  - the numeric table;
  - the timing table, labelled Mac M2 Max;
  - not byte-reproducible;
  - what the executor does differently.

  Architecture docs hold durable text; detailed tables go in the ADR record and the verification doc. Every number
  comes from findings.md or a committed report.
- [ ] Run `npx prettier --check` on the changed markdown → exit 0.
- [ ] Commit `docs(speech): record the Core AI conversion (#279)`.
