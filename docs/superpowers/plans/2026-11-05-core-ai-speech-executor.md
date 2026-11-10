# Neural Speech: Apple Core AI Executor (PR 5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Swift SDK a second neural speech runtime, Apple Core AI: a `SpeechGraphExecutor` over `.aimodel` assets, a composed `CoreAINeuralSpeechRuntime` with specialization-aware readiness, a provider factory with id `local.coreai.speech.apple`, the preparation tool for Core AI packages, a CI build step, and ADR 022 — compiling on every Xcode (stub without `CoreAI`) and running on iOS 27 / macOS 27.

**Architecture:** A new SwiftPM target `IndeRunCoreAIProviders` depends on `IndeRunNeuralSpeech` and reuses the Articulino pipeline, `DirectoryPackageFiles` and the safetensors reader unchanged; only the executor and the composed runtime are Core AI-aware, behind `#if canImport(CoreAI)` and `@available(iOS 27, macOS 27, *)`. The model-directory resolver moves from the ORT module into `IndeRunCore` so both runtimes share it. Readiness: `not_prepared` while the device has no specialized model in `AIModelCache`, `cold` after specialization, `ready` after the first run; a `readiness` hint on `NeuralSpeechAvailability` carries it to the provider. No contract schema changes; ADR 022 amends ADR 019 in prose.

**Tech Stack:** Swift 5.9 manifest, Xcode 27.2 SDK (`CoreAI` umbrella: `CoreAIRuntime`, `CoreAIDelegates`, `CoreAIAsset`), XCTest; Python tool under `tools/neural-speech/`; GitHub Actions `swift.yml`.

**Spec:** `docs/superpowers/specs/2026-11-04-neural-speech-design.md` section D (Core AI module), section E (routing), PR table row 5; proxy ruling Q5 (scratchpad `pr4-decision.md`); PR 4a's family doc `docs/architecture/neural-speech-provider-family.md` for the seams.

## Global Constraints

- Branch `feat/m5-core-ai-speech`, stacked on `feat/m5-neural-speech-ort-articulino` (PR #272, base `48e2fc8`); PR into `dev` once #272 is merged (rebase with `git rebase --onto dev 48e2fc8`), else PR against the 4a branch. Conventional Commits, trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` last; one squashed commit before pushing.
- `Package.swift`: platforms stay `.iOS(.v16), .macOS(.v14)`. New target + product `IndeRunCoreAIProviders` at `ios/IndeRun/Sources/IndeRunCoreAIProviders/`, dependencies `["IndeRunNeuralSpeech", "IndeRunCore", "IndeRunContracts"]`; `IndeRunTests` gains it (comment "all eight"); consumer-smoke targets untouched.
- Every reference to a Core AI type sits inside `#if canImport(CoreAI)` and is `@available(iOS 27, macOS 27, *)`. The module compiles on an Xcode without the framework (CI's `macos-latest`) to a stub that reports `available: false, reason: "Core AI requires iOS 27 / macOS 27"` (constant `CoreAISupport.unavailableReason`, exact text).
- CLAUDE.md §4: no Core AI type in a public signature. Public options use IndeRun types only.
- Core AI API as verified in the macOS 27.2 SDK (probe type-checked): `AIModel(contentsOf: URL, options: SpecializationOptions = .default) async throws`; `AIModel.specialize(contentsOf:options:) async throws`; `AIModelCache.default.model(for: URL, options:) throws -> AIModel?` (nil = not specialized/cached); `model.loadFunction(named:) throws -> InferenceFunction?`; `model.functionNames`, `model.functionDescriptor(for:)`; `InferenceFunction.run(inputs: [String: NDArray]) async throws -> Outputs` with `outputs.names` and `outputs.remove(_:) -> InferenceValue?` → `.ndArray`; `NDArray(shape:scalarType:)` with `.float32`, `.int64` (also `.bool`, unused); bulk copy in via `mutableRawView().mutableBytes` (`MutableRawSpan`), out via `rawView().withUnsafeBytes { pointer, shape, strides in … }` or `view().withUnsafePointer`; `NDArray.scalarType/shape/strides`. Outputs with non-C-contiguous strides are copied stride-aware.
- `SpeechTensor` stays f32|i64. `text_mask` is int64 in IndeRun packages (the `.aimodel` wrapper casts to bool inside; spike 0b).
- `speech.graphs` values for `format: "coreai"`: `<file>.aimodel` (function named after the role) or `<file>.aimodel#<function>`; file names pass `checkPackageFileName`; an `.aimodel` may be a file or a directory (`FileManager.fileExists` either way).
- Readiness hint: `NeuralSpeechAvailability.readiness: NeuralSpeechReadiness?` (`.notPrepared`, `.cold`), optional and additive on all three SDKs (web `readiness?: "not_prepared" | "cold"`, Kotlin `NeuralSpeechReadiness?`); the provider reports the hint when present and the runtime is not yet loaded, its own `ready` after a successful prepare/run.
- ADR 019 amendment (ADR 022): `not_prepared` for a Core AI package means "not specialized on this device"; `autoDownload` / `prepare({ allowDownload: true })` authorize specialization as they authorize a download (consent for a long preparation); without them the planner skips the package as today. No engine or planner change. A typed preparation kind on the contracts is a recorded follow-up.
- Error strings mirror the ORT executor: load `(.unavailable, "graph failed to load: <role>: <message>")`, run `(.unavailable, "graph failed: <role>: <message>")`, unknown role `(.internalFailure, "graph not loaded: <role>")`, unsupported output `(.internalFailure, "graph output unsupported: <role>.<name>")`, missing function `(.capability, "graph function missing: <role>: <function> in <file>")`, format `(available: false, reason: "unsupported format '<x>'")`.
- `limits.memBytes` enforced like `OnnxNeuralSpeechRuntime` (`deviceMemoryBytes` option, `ProcessInfo.physicalMemory` default).
- Env-gated real-model tests read `INDERUN_COREAI_MODEL_DIR` (a directory written by `prepare_coreai_package.py`); absent, or `CoreAI` unavailable, → `XCTSkip`. No `.aimodel`, model or voice file is committed. Spike 0b (the export) may not have finished when this PR lands: the conversion record in ADR 022 / the family doc states what is pinned and marks the rest "pending spike 0b".
- Lint: `(cd ios/IndeRun && swiftlint lint --strict)` (line length 140); `swift build` and `swift test` green on this Mac (Xcode 27.2) and must stay green on CI's older Xcode (stub path); `pnpm format:js`/`lint` for the web seam edit; `./gradlew spotlessApply` for the Kotlin seam edit.

## Review Focus

1. On a device/Xcode without Core AI the whole chain degrades cleanly: provider `capabilities` → `available: false` with the exact reason, routing falls through to the next profile target, nothing throws (Task 4 tests with the availability override; Task 3 stub compile).
2. A package whose `.aimodel` is not specialized yet reports `not_prepared`; a `prepare` specializes it (minutes on large models) and reports `cold`; the first `synthesize` reports `ready` (Task 4 readiness tests with the injected cache lookup; Task 2 provider passthrough).
3. A `graphs` value with an unknown function name, a missing file, a traversal name, or a non-`coreai` format refuses before Core AI is touched (Task 3/4 tests).
4. An output `NDArray` with non-contiguous strides or an unexpected scalar type never produces silently wrong audio: stride-aware copy or a named `internalFailure` (Task 3 unit test on the copy helper with synthetic strides).
5. `prepare` twice does not re-specialize (cache hit) and `synthesize` after a failed prepare reports the remembered reason (Task 4).

---

### Task 1: Move the model-directory resolver into `IndeRunCore`

**Files:**
- Create: `ios/IndeRun/Sources/IndeRunCore/ModelPackageDirectory.swift`
- Modify: `ios/IndeRun/Sources/IndeRunOnnxProviders/OnnxSessionLoading+ModelResolution.swift` (delegate; keep `LoadedSessionBox.resolveDirectory`/`verifyChecksums` as thin wrappers mapping to `OnnxRuntimeError` with unchanged messages), `ios/IndeRun/Sources/IndeRunOnnxProviders/OnnxNeuralSpeechRuntime.swift` (call the Core API directly)
- Create: `ios/IndeRun/Tests/IndeRunTests/ModelPackageDirectoryTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct ModelPackageDirectoryError: Error, Sendable { public enum Kind: Sendable { case capability, unavailable }; public let kind: Kind; public let message: String; public let originalErrorDescription: String? }
  public enum ModelPackageDirectory {
      /// bundled → Bundle.main.resourceURL + ref; filesystem → URL(fileURLWithPath: ref); app_managed → Application Support + ref; programmatic/registry/remote → .capability (messages verbatim from the ORT resolver, minus the "OnnxGenAiRuntime" wording: programmatic reads "model source unavailable: 'programmatic' sources are resolved by the application.").
      public static func resolve(_ modelPackage: ModelPackage) throws -> URL
      /// `integrity.checksums` `sha256:<hex>` for files under `directory`; same messages as today.
      public static func verifyChecksums(_ modelPackage: ModelPackage, directory: URL) throws
  }
  ```
- Consumes: `ModelPackage`, `CryptoKit`.

- [ ] **Step 1: Write the failing tests** — `ModelPackageDirectoryTests`: filesystem ref resolves; missing `source` → `.capability` "model package declares no source"; `programmatic` → `.capability`; `registry`/`remote` → `.capability` "deferred on Apple platforms"; checksum match passes; mismatch → `.capability` "does not match its declared checksum"; unsupported algorithm → `.capability`; a declared file that does not exist is skipped (current behaviour).
- [ ] **Step 2: Run** `swift test --filter ModelPackageDirectoryTests` → compile error `cannot find 'ModelPackageDirectory'`.
- [ ] **Step 3: Implement**, then make the ORT wrappers delegate (`catch let error as ModelPackageDirectoryError` → `OnnxRuntimeError(kind: error.kind == .capability ? .capability : .unavailable, message: error.message)`), and `OnnxNeuralSpeechRuntime` use `ModelPackageDirectory` directly (its `available: false` messages unchanged).
- [ ] **Step 4: Run** `swift test` (full) and lint → PASS, 0 violations; the ORT real-model tests still skip cleanly.
- [ ] **Step 5: Commit** `refactor(apple): share the model package directory resolver in IndeRunCore`.

---

### Task 2: Readiness hint on the runtime seam (three SDKs) and provider passthrough

**Files:**
- Modify: `ios/IndeRun/Sources/IndeRunNeuralSpeech/NeuralSpeechRuntime.swift` (`public enum NeuralSpeechReadiness: String, Sendable { case notPrepared = "not_prepared", cold }`; `NeuralSpeechAvailability.readiness: NeuralSpeechReadiness?` with a defaulted init parameter), `NeuralSpeechProvider.swift` (capabilities: when the runtime is not loaded and the hint is present, report it; existing behaviour otherwise), `ios/IndeRun/Tests/IndeRunTests/NeuralSpeechProviderTests.swift`
- Modify: `packages/inderun-web/src/providers/neural-speech/runtime.ts` (`readiness?: "not_prepared" | "cold"`), `provider.ts`, `provider.test.ts`
- Modify: `android/inderun-neural-speech/.../NeuralSpeechRuntime.kt` (`enum class NeuralSpeechReadiness(val rawValue: String) { NotPrepared("not_prepared"), Cold("cold") }`, `val readiness: NeuralSpeechReadiness? = null`), `NeuralSpeechProvider.kt`, `NeuralSpeechProviderTest.kt`
- Modify: `docs/architecture/neural-speech-provider-family.md` ("The seams": the hint; "Capabilities": readiness table)

**Interfaces:** the hint only narrows what the provider already reports (`cold` until loaded, `ready` after): `not_prepared` is new and means "a `prepare` is required before a run can succeed"; the contract `readiness` value is the same wire string.

- [ ] **Step 1: Write the failing tests** per SDK: a fixture/scripted runtime whose `availability` returns `readiness: not_prepared` → the provider's capability snapshot reports `readiness == not_prepared` for the task and its voices; after a successful `prepare` → `ready`; without a hint → unchanged (`cold`).
- [ ] **Step 2: Run** each SDK's provider test → FAIL on the missing field.
- [ ] **Step 3: Implement** (additive; `FixtureNeuralSpeechRuntimeOptions.availability` already carries a `NeuralSpeechAvailability`, so the fixture needs no change).
- [ ] **Step 4: Run** `swift test --filter NeuralSpeech`, `pnpm --filter @independo/inderun-web test`, `(cd android && ./gradlew spotlessApply && ./gradlew :inderun-neural-speech:testDebugUnitTest)`; lint all three.
- [ ] **Step 5: Commit** `feat(neural-speech): let a runtime report not_prepared readiness`.

---

### Task 3: The `IndeRunCoreAIProviders` target and the Core AI executor

**Files:**
- Modify: `Package.swift` (product + target + `IndeRunTests` dependency)
- Create: `ios/IndeRun/Sources/IndeRunCoreAIProviders/Exports.swift` (`@_exported import IndeRunNeuralSpeech`), `CoreAISupport.swift`, `CoreAIGraphReference.swift`, `CoreAISpeechGraphExecutor.swift`, `CoreAITensorBridge.swift`
- Create: `ios/IndeRun/Tests/IndeRunTests/CoreAIGraphReferenceTests.swift`, `CoreAITensorBridgeTests.swift`, `CoreAISpeechGraphExecutorTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum CoreAISupport {
      public static let unavailableReason = "Core AI requires iOS 27 / macOS 27"
      /// true only when the framework was compiled in and the OS is new enough.
      public static var isAvailable: Bool
  }
  public struct CoreAIGraphReference: Equatable, Sendable {
      public let file: String; public let function: String
      /// "<file>" → function = role; "<file>#<function>"; empty parts or a second '#' throw NeuralSpeechRuntimeError(.capability, "graph reference invalid: <role>: <value>")
      public init(role: String, value: String) throws
  }
  #if canImport(CoreAI)
  @available(iOS 27, macOS 27, *)
  public final class CoreAISpeechGraphExecutor: SpeechGraphExecutor, @unchecked Sendable {
      public init(directory: URL)
      public func load(graphs: [String: String]) async throws   // per role: reference → checkPackageFileName → url; model = try AIModelCache.default.model(for: url, options: .default) ?? (specialize then AIModel(contentsOf:)); one AIModel per distinct file; function = loadFunction(named:) or .capability missing-function error
      public func run(role: String, inputs: [String: SpeechTensor]) async throws -> [String: SpeechTensor]
      public func close() async
      /// Internal hook for tests: whether `load` found every file already specialized.
      var specializedOnLoad: Bool { get }
  }
  #endif
  // CoreAITensorBridge.swift (internal, #if canImport(CoreAI)): makeNDArray(_ tensor: SpeechTensor) throws -> NDArray; makeSpeechTensor(_ array: NDArray, role: String, name: String) throws -> SpeechTensor (stride-aware copy; scalar types other than float32/int64 → "graph output unsupported")
  ```
- Consumes: `checkPackageFileName` (package-scoped in `IndeRunNeuralSpeech`; make it `public` if the module boundary needs it — ledger it), `NeuralSpeechRuntimeError`, `SpeechTensor`.

- [ ] **Step 1: Write the failing tests** — `CoreAIGraphReferenceTests` (plain file, `#function`, invalid forms); `CoreAITensorBridgeTests` (`#if canImport(CoreAI)` + `@available`, `XCTSkip` otherwise): f32 and i64 round trip `[1,3]`; a non-contiguous NDArray (`init(shape:scalarType:strides:)`) copies element-wise correctly; `.bool` output → unsupported error names role and name; `CoreAISpeechGraphExecutorTests`: run before load → `graph not loaded: text`; missing file → `graph failed to load: text: model files missing: text.aimodel`; traversal name → `model file name invalid`; env-gated `testLoadsAndRunsTheTextGraph` with `INDERUN_COREAI_MODEL_DIR` (loads, checks `functionNames` contains the roles, runs `text` on `[0, 9, 2, 13]` ids and asserts output shapes).
- [ ] **Step 2: Run** `swift test --filter "CoreAI"` → compile error on the missing target.
- [ ] **Step 3: Implement**; `swift build --target IndeRunCoreAIProviders` on this Mac compiles the real branch. Verify the stub path by building with `-Xswiftc -DINDERUN_FORCE_NO_COREAI`? No: the stub is selected by `canImport`, so instead keep `CoreAISupport.swift` and the runtime (Task 4) compilable without the framework by construction (review by reading; CI proves it).
- [ ] **Step 4: Run** `swift test --filter "CoreAI|NeuralSpeech"`, full `swift test`, lint.
- [ ] **Step 5: Commit** `feat(apple): add the Core AI speech graph executor`.

---

### Task 4: Composed runtime, readiness, provider factory

**Files:**
- Create: `ios/IndeRun/Sources/IndeRunCoreAIProviders/CoreAINeuralSpeechRuntime.swift`, `CoreAINeuralSpeechProvider.swift`
- Create: `ios/IndeRun/Tests/IndeRunTests/CoreAINeuralSpeechRuntimeTests.swift`, `CoreAINeuralSpeechRealModelTests.swift`
- Modify: `ios/IndeRun/README.md`

**Interfaces:**
- Produces:
  ```swift
  public struct CoreAINeuralSpeechRuntimeOptions: Sendable {
      public let noise: NoiseSource?; public let speed: Float; public let pauseMs: Int
      public let deviceMemoryBytes: (@Sendable () -> UInt64)?
      public init(noise: NoiseSource? = nil, speed: Float = 1.0, pauseMs: Int = 150, deviceMemoryBytes: (@Sendable () -> UInt64)? = nil)
  }
  public final class CoreAINeuralSpeechRuntime: NeuralSpeechRuntime, @unchecked Sendable {
      public init(options: CoreAINeuralSpeechRuntimeOptions = .init())
      // internal test hooks: isAvailableOverride: Bool?, isSpecialized: ((URL) -> Bool)?, specialize: ((URL) async throws -> Void)?
  }
  public let DEFAULT_COREAI_SPEECH_PROVIDER_ID = "local.coreai.speech.apple"
  public struct CoreAINeuralSpeechProviderOptions: Sendable { id: String?; modelPackage: ModelPackage; timeout: Duration?; runtime: CoreAINeuralSpeechRuntimeOptions }
  public func makeCoreAINeuralSpeechProvider(options: CoreAINeuralSpeechProviderOptions) -> NeuralSpeechProvider   // id default "<DEFAULT>:<pkg.id>"
  ```
  Behaviour of `availability(pkg)`: Core AI unavailable → `(false, CoreAISupport.unavailableReason)`; `pkg.format != .coreai` → `unsupported format '<x>'`; `speech.pipeline != "articulino"` → `unsupported pipeline '<x>'`; directory via `ModelPackageDirectory.resolve` (error → its message); every graph reference parses and its file exists else `model files missing: <file>`; memBytes; then `readiness: .notPrepared` if any distinct file is not specialized (`AIModelCache.default.model(for:options:) == nil`, via the hook), else `.cold`. `prepare(pkg)`: `verifyChecksums`, specialize each distinct unspecialized file (`AIModel.specialize(contentsOf:)`), then the cached `ArticulinoRuntime(executor: CoreAISpeechGraphExecutor(directory:), files: DirectoryPackageFiles(directory:), …).prepare`; a failure is remembered as in the ORT runtime; one runtime per `id@version`. `synthesize`: `unavailable` refusal when not prepared/failed, else delegate.
- Consumes: Tasks 1-3.

- [ ] **Step 1: Write the failing tests** — `CoreAINeuralSpeechRuntimeTests` (no model needed): unavailable override → reason verbatim, from `availability`, `prepare` and `synthesize` (the last throws `.unavailable`); format `onnx` → `unsupported format 'onnx'`; unsupported pipeline; missing file in a temp dir; readiness `.notPrepared` with `isSpecialized: { _ in false }` and `.cold` with `true`; provider factory: default id `local.coreai.speech.apple:<pkg.id>`, descriptor `model == pkg.id`, capabilities on an unavailable runtime `available: false` with the reason and no readiness; `prepare` twice calls the specialize hook once (second is a cache hit); memBytes refusal. `CoreAINeuralSpeechRealModelTests`: `XCTSkip` unless Core AI is available and `INDERUN_COREAI_MODEL_DIR` is set; `prepare` reports available; `synthesize("Ich habe Hunger.")` → 1-6 s of audio, RMS > 300, prints the wall time; readiness before prepare (`not_prepared` on a fresh cache or `cold`), after `ready` through the provider.
- [ ] **Step 2: Run** `swift test --filter CoreAINeuralSpeech` → compile error.
- [ ] **Step 3: Implement**; README section "Core AI" (`makeCoreAINeuralSpeechProvider`, package layout, readiness and consent, "write numbers as words").
- [ ] **Step 4: Run** `swift test` (full), lint.
- [ ] **Step 5: Commit** `feat(apple): add the Core AI neural speech runtime and provider`.

---

### Task 5: Tool support for Core AI packages

**Files:**
- Create: `tools/neural-speech/prepare_coreai_package.py`, `tools/neural-speech/test_prepare_coreai_package.py`
- Modify: `tools/neural-speech/README.md`, `CONTEXT.md` §6 (one command line)

**Interfaces:**
- `prepare_coreai_package.py --asset <path/articulino.aimodel> --config <config.json> --models <onnx-release-dir> --precision int8 --voice <wav>[:<id>]... --out <dir> [--package-id articulino-de-en-coreai] [--function-names text,dit_step,decoder]`: copies the asset (file or directory, recursively) and `config.json`, prepares voices with the existing `VoiceTool`, writes `model-package.json` with `format: "coreai"`, `variant: "coreai"`, `runtime: { minOsVersion: "27.0" }`, `graphs: { text: "articulino.aimodel#text", dit_step: "articulino.aimodel#dit_step", decoder: "articulino.aimodel#decoder" }`, `frontend.assets.config`, voices, `integrity.checksums` for every file (a directory asset lists each contained file with its relative path), and validates the required keys as the ONNX script does. Voice ids validated with the existing `validate_voice_id`.

- [ ] **Step 1: Write the failing tests** (a fake `.aimodel` directory with two files, a fake config, a stubbed `VoiceTool` via monkeypatch): the package JSON shape, the graphs references, recursive checksums, invalid voice id refused.
- [ ] **Step 2: Run** `tools/neural-speech/.venv/bin/python -m unittest discover -s tools/neural-speech -p 'test_*.py'` → FAIL (import).
- [ ] **Step 3: Implement**; README section; CONTEXT.md §6 line.
- [ ] **Step 4: Run** the tool tests and `node -e` JSON sanity → PASS.
- [ ] **Step 5: Commit** `feat(tools): prepare Core AI speech packages`.

---

### Task 6: CI step and docs (ADR 022, family doc, matrix, migration, CONTEXT.md)

**Files:**
- Modify: `.github/workflows/swift.yml` (after the existing macOS test step: "Build the Core AI module with the newest Xcode": select the newest `/Applications/Xcode*.app` with `sudo xcode-select -s`, print `xcodebuild -version`, `swift build --target IndeRunCoreAIProviders`, `continue-on-error: true`, a comment saying why), `docs/ci.md` (the step, why it may fail, how to run the gated tests locally with `INDERUN_COREAI_MODEL_DIR`)
- Create: `docs/architecture/decisions/022-core-ai-runtime.md` (Status: Accepted; Context: second runtime for the PyTorch-sourced model, ADR 019 consent model vs specialization; Decision: 1 module placement and gating, 2 graph reference syntax, 3 readiness = specialization state and the ADR 019 amendment, 4 error codes, 5 conversion record: the coreai-torch chain (`torch.export` with bounded `Dim`s → `run_decompositions(get_decomp_table())` → `TorchConverter().add_exported_program(..., entrypoint_name=role)` ×3 → `to_coreai()` → `save_asset`), the three entrypoint names, dtype of `text_mask`, "pending spike 0b: asset hash, shape bounds, specialization time"; Consequences)
- Modify: `docs/architecture/decisions/README.md` (row 022), `docs/architecture/neural-speech-provider-family.md` (Ids: `local.coreai.speech.apple`; Options; "Core AI runtime" section: readiness, specialization, cache, graphs syntax, placement, follow-ups), `docs/architecture/providers.md` (new matrix row "Core AI speech (local.coreai.speech.apple)"), `docs/migration.md` (new product; readiness hint field), `CONTEXT.md` §3 (scope sentence: Core AI executor ships, conversion record pending), `docs/superpowers/specs/2026-11-04-neural-speech-design.md` (section D: real API names; PR table row 5 done)

- [ ] **Step 1: Edit**; `pnpm format:check` (markdown hand-aligned).
- [ ] **Step 2: Commit** `docs(adr): record the Core AI speech runtime (ADR 022)`.

---

### Task 7: Whole-branch verification, squash, PR

- [ ] **Step 1:** `pnpm test:js && swift test && (cd android && ./gradlew test) && (cd ios/IndeRun && swiftlint lint --strict) && (cd android && ./gradlew spotlessCheck) && pnpm format:check && pnpm build && pnpm verify:packaging && pnpm verify:android-api-deps && git diff --exit-code` → all PASS. `swift build --target IndeRunCoreAIProviders` on this Mac → PASS. If spike 0b has produced an asset, run the gated tests with `INDERUN_COREAI_MODEL_DIR` and record the numbers in the family doc.
- [ ] **Step 2:** squash to `feat(providers): add the Apple Core AI neural speech runtime (#260)`; push; `gh pr create` with base `dev` if #272 merged (rebase first), else base `feat/m5-neural-speech-ort-articulino`; body lists the readiness/consent decision, the pending conversion record, the owner's items.

---

### Critical Files for Implementation

- `ios/IndeRun/Sources/IndeRunCoreAIProviders/CoreAISpeechGraphExecutor.swift` and `CoreAITensorBridge.swift` (the only Core AI-aware code)
- `ios/IndeRun/Sources/IndeRunCoreAIProviders/CoreAINeuralSpeechRuntime.swift` (readiness and specialization)
- `ios/IndeRun/Sources/IndeRunCore/ModelPackageDirectory.swift` (shared resolver)
- `Package.swift`, `.github/workflows/swift.yml`
