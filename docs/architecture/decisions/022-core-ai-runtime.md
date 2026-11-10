# ADR 022 — Apple Core AI speech runtime

## Status

Accepted. Recorded for Milestone 5 (issue #260). It amends [ADR 019](./019-prepare-and-readiness.md) for runtimes that
must specialize a model, and builds on the package format of
[ADR 020](./020-neural-speech-and-model-packages.md) and the seams of the
[neural speech family](../neural-speech-provider-family.md).

## Context

The neural speech family has one real runtime, ONNX Runtime with the Articulino pipeline, on every SDK. The programme
also needs a second runtime for the same PyTorch-sourced model on Apple platforms: Core AI, which runs `.aimodel`
assets on the device's own accelerators and is the hard requirement for the Apple demo. The pipeline, the seams
(`SpeechGraphExecutor`, `NeuralSpeechRuntime`) and the package format already exist, so the work is one more executor
and one more composed runtime.

Core AI differs from ONNX Runtime in two ways that matter here. Its framework ships first in the macOS 27 SDK, so an
older Xcode cannot even compile a reference to it. And a `.aimodel` has to be specialized for the device and OS before
it runs. Specialization was expected to take minutes; for the Articulino asset it took 1.22 s on an M2 Max (section 5), and the first `prepare` on an iPhone 15, which specializes, loads and warms up, took about 9 s (see [the verification record](../../verification/neural-speech.md#core-ai-apple-fp32)). Its result lives in a system cache, so it is neither a file the developer
ships nor a network download, yet it is a long preparation that needs the application's consent in the way ADR 019
section 4 describes for downloads.

## Decision

### 1. Placement and gating

The runtime lives in its own SwiftPM product and target, `IndeRunCoreAIProviders`, depending on `IndeRunNeuralSpeech`,
`IndeRunCore` and `IndeRunContracts`. The package platforms stay iOS 16 and macOS 14. Every Core AI symbol sits in
`#if canImport(CoreAI)` and `@available(iOS 27, macOS 27, *)`. On an Xcode whose SDK lacks the framework the module
builds to a stub; on an older OS the runtime reports `available: false` with the reason
`Core AI requires iOS 27 / macOS 27` (`CoreAISupport.unavailableReason`). So an app compiles on any Xcode and routes to
the next target on an older device. No Core AI type appears in a public signature. Nothing registers the module by
default: an app builds a provider with `makeCoreAINeuralSpeechProvider(options:)`, whose id is
`local.coreai.speech.apple:<model id>`.

### 2. Graph references

A package with `format: "coreai"` names its graphs in `speech.graphs` as `<file>.aimodel`, which loads the function
named after the role, or `<file>.aimodel#<function>`, which names it. One `AIModel` is loaded per distinct file and one
function per role. The asset name may not contain `#`; the preparation tool refuses it, and the file name passes the
same package rules as every other (not empty, not absolute, no `..`). An `.aimodel` may be a file or a directory. A
malformed reference is `graph reference invalid: <role>: <value>`.

### 3. Readiness is the specialization state

For a `coreai` package, `not_prepared` means "not yet specialized on this device": some graph file is missing from
`AIModelCache.default`. `cold` means every file is cached, and the provider reports `ready` after a successful
`prepare` or run. The runtime sets this through the optional `readiness` hint on `NeuralSpeechAvailability`
(additive on all three SDK seams).

**Amendment to ADR 019 section 4.** `autoDownload` at registration and `prepare({ allowDownload: true })` authorize
specialization exactly as they authorize a download. The consent is for a long preparation, not only for bytes. Without
them the planner skips the package as it does today for any `not_prepared` provider. No engine, planner or contract
change is needed, and the consent wording in an app's UI should say "prepare" rather than "download". A typed
preparation kind on the contracts ("download" versus "compile") is a recorded follow-up.

Only `prepare` specializes. `availability` and `synthesize` never do: a package that is not prepared is refused by
`synthesize` with `model not prepared: <id@version>`, followed by the last `prepare` failure when there was one. An
incomplete package (a missing role, a missing frontend config, a voice without its file) is refused by the Articulino
metadata check, and a config or voice file absent from the directory by `model files missing: <file>`, before any
specialization starts, so a long compile is never spent on a package that cannot run. For the same reason `prepare` reads each asset's
function list (its `AIModelAsset` summary) before specializing and refuses a role whose function the asset does not
declare.

The cache keeps Core AI's `.default` (purgeable) policy. After the OS purges it, the next `availability` (before a
`prepare` in this process) reports `not_prepared` again and the next consented `prepare` specializes again. Models
already loaded stay in memory for the session. After a successful `prepare` the runtime reports `cold` without
consulting the cache, so the routing hot path probes nothing; a purge is observed by a runtime that has not prepared the
package in this process.

### 4. Error strings

The runtime's refusals mirror the ONNX runtime's wording: `unsupported format '<x>'`, `unsupported pipeline '<x>'`,
`insufficient memory: ...`, `model files missing: <file>`, `graph failed to load: <role>: <message>`,
`graph failed: <role>: <message>`, `graph not loaded: <role>`, `graph output unsupported: <role>.<name>`,
`graph function missing: <role>: <function> in <file>` and `graph reference invalid: <role>: <value>`. Core AI adds
`specialization failed: <file>: <message>`, and `model asset invalid: <file>` for an asset Core AI does not recognize;
`prepare` reports `graph function missing` from the asset's function list before specializing. `limits.memBytes` is
enforced against `ProcessInfo.physicalMemory`, as in the ONNX runtime.

### 5. Conversion record

The `.aimodel` is produced offline from the upstream PyTorch checkpoint with Apple's `coreai-torch`. It was run once on
2026-11-09 (spike 0b, [#279](https://github.com/independo-gmbh/inderun/issues/279)) on an Apple M2 Max (32 GB, Core AI
device architecture `h14c`), macOS 27.2 (26B123) and Xcode 27.2 (27B52). The tables below are that run and no other.

**Verdict: the export works.** All three stages export with `torch.export` using bounded dynamic dims, and
`coreai-torch` converts them into **one** asset with three entrypoints, `text`, `dit_step` and `decoder`, with the same
tensor names as the ONNX graphs. The asset specializes, loads and runs through the Swift `CoreAI` API. There were no
`torch.export` failures and no converter failures.

#### Procedure

1. `torch.export.export(module, args, dynamic_shapes, strict=False)` for each stage, with `Dim("letters", 2, 257)` on
   axis 1 of the `text` inputs, `Dim("new_frames", 2, 1024)` on `x` and `frame_cond`, and `Dim("frames", 2, 1036)` on
   `latents`.
2. `run_decompositions(coreai_torch.get_decomp_table())`.
3. `TorchConverter(mode=Mode.RELEASE).add_exported_program(exported, input_names, output_names, entrypoint_name=<role>)`,
   three times on one converter.
4. `to_coreai()`, then `save_asset(Path(...))` (a `pathlib.Path`; a `str` raises `AttributeError`).

Export, convert and save take about 8 s. [`prepare_coreai_package.py`](../../../tools/neural-speech/README.md) wraps the
asset into a package; it does not run the export.

#### Pinned sources and versions

| What            | Pin                                                                                                                     |
| --------------- | ----------------------------------------------------------------------------------------------------------------------- |
| coreai-torch    | `github.com/apple/coreai-torch`, commit `7a18c005deb3e791ac35f201a3d955b77034e947` (2026-10-22), v0.4.3                 |
| articulino      | `github.com/eigenhand/articulino`, commit `66f79f602d3421aee7a7f8cfb8990faa0e88cc2a` (2026-10-15), v1.0.0               |
| PyTorch weights | Hugging Face `eigenhand/Articulino-DE-EN-Realtime-Stream-TTS`, revision `38ad5471d4e6a20b70ce708f0f3c35e3d2e86523`      |
| ONNX reference  | Hugging Face `eigenhand/Articulino-DE-EN-Realtime-Stream-TTS-ONNX`, revision `a760ce8d513534111c7679751869fa4c45ef0e54` |
| Voice           | `de-de-f-1` from the `neural-speech-assets-1` release (P = 125)                                                         |

The PyTorch weights, codec, config, LICENSE and NOTICE were checked against the upstream `SHA256SUMS`. Python 3.13 in a
fresh virtual environment, torch 2.13.0 (PyPI), coreai-core 1.0.0b3 (PyPI), coreai-torch 0.4.3 and articulino 1.0.0 (both
editable installs of the pinned clones), numpy 2.4.6 (coreai-torch pins `<2.5`), safetensors 0.8.0, onnxruntime 1.31.1
and onnx 1.23.2.

#### Install-file review

Done before installing anything.

- **coreai-torch.** `pyproject.toml` only, plain `setuptools.build_meta`; no `setup.py`, `setup.cfg`, CMake, `build.rs`
  or post-install hook. Package data is `py.typed`. No network or subprocess calls in the package. Dependencies:
  coreai-core==1.0.0b3, ml-dtypes, networkx, numpy<2.5, packaging, scipy, sympy, torch>=2.8.0, typing-extensions,
  strenum and rich.
- **articulino.** `pyproject.toml` only, `setuptools.build_meta`, no hooks. Package data is `frontend/data/*.json`, with
  one console script, `articulino`. Dependencies: torch>=2.1, numpy, soundfile and num2words<0.6.
  `TTS.from_pretrained` calls `huggingface_hub` only for a repository id; it was not installed and the run passed a local
  folder. Its `tools/listen_check.py` shells out to curl and `tools/export_safetensors.py` uses
  `torch.load(weights_only=False)`; neither was run.
- **A binary wheel.** coreai-core, a transitive dependency from PyPI, is a **binary** wheel (cp313, macOS 26 arm64,
  BSD-3) with compiled modules, and pulls in pillow and yuvio. The review above could not read compiled code, so this
  is the one piece that was trusted on the strength of its source and licence rather than read. On macOS 27 or later,
  `coreai.runtime` from that wheel binds to the OS `CoreAI.framework` (`_use_os_coreai == True`), so the Python
  validation ran on the same framework as the SDK.

#### Wrapper changes

The stages are wrapped so that voice-dependent work is inlined and the graph inputs match the ONNX ones.
`TextStage` computes `mask = text_mask != 0` before the text encoder and duration predictor. `DiTStepStage` inlines
`DiT.velocity`, taking block `i`'s prompt keys and values from `voice_cache[i, 0/1]`. `DecoderStage` de-normalizes with
the config mean and std baked in. Three changes beyond that:

1. **Time-embedding frequencies are a precomputed float32 buffer** (required for correctness). Core AI evaluated the
   in-graph `exp(-ln(10000)·i/128)` with about 1e-4 relative error, which dropped the velocity for `t > 0` to 58 to
   68 dB. With the buffer, every step is at 117 to 120 dB.
2. **`torch.istft` is replaced by real arithmetic:** one matmul against a windowed inverse-rDFT basis (built in float64),
   an overlap-add of 4 shifted adds and a window-squared envelope. It matches upstream `torch.istft` at 125.7 dB.
3. **The overlap-add is the matmul form, for speed.** A `conv_transpose1d` overlap-add took 56 ms on the GPU and 3.0 s
   CPU-only; the matmul form takes 5.3 ms on the GPU and 1.15 s CPU-only.

The asset is therefore not the upstream graph unchanged. It is a modified Apache-2.0 derivative and ships with the
upstream NOTICE and a modification note
([`MODIFICATIONS.md`](../../../tools/neural-speech/coreai-release/MODIFICATIONS.md)).

#### Signatures and bounds

Batch is fixed at 1 and P = 125 is fixed. All outputs are float32 and C-contiguous.

| Function   | Inputs                                                                                                                                                   | Outputs                                                  |
| ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| `text`     | `text_ids` **int32** [1,N], `language` **int32** [1,N], `text_mask` **int32** [1,N] (0/1, cast to bool inside), `voice_vector` f32 [1,768]               | `text_features` f32 [1,N,512], `log_durations` f32 [1,N] |
| `dit_step` | `x` f32 [1,L,96], `t` f32 [1], `frame_cond` f32 [1,L,512], `voice_tokens` f32 [1,32,768], `voice_vector` f32 [1,768], `voice_cache` f32 [8,2,1,6,125,64] | `velocity` f32 [1,L,96]                                  |
| `decoder`  | `latents` f32 [1,F,96]                                                                                                                                   | `waveform` f32 [1,?]                                     |

- **Bounds.** `text` N is in [1, 257], `dit_step` L in [1, 1024] and `decoder` F in [1, 1036]; the export declared 2 as
  the lower bound, but the spike measured L = 1 correct against eager (125 dB; `dit_step` runs at L = 1 when one new
  frame is left), so the executor accepts 1 and refuses 0. `voice_cache` is exactly [8, 2, 1, 6, 125, 64]. The executor
  checks every input's rank and fixed dimensions before any Core AI call (`capability`), and a package whose voice has a
  prompt length other than 125 is unavailable at `availability` and `prepare`, with a reason naming the voice and P.
- **Int32, not int64.** Core AI has no 64-bit dtypes and `coreai-torch` narrows every int64 input, so the asset declares
  `int32` for `text_ids`, `language` and `text_mask`. Feeding an int64 `NDArray` **aborts the process** with an MPSGraph
  assertion (`Incompatible element type for parameter at index 0, mlir module expected element type si32 but received
si64`, exit 134); it does not throw.
- **Core AI does not enforce the bounds.** A size past the export bound runs without error and returns wrong numbers:
  `text` at N = 300 gave `log_durations` at 8.9 dB SNR while the features stayed correct. `dit_step` at L = 1100 and
  `decoder` at F = 1100 stayed correct by chance, which is not a guarantee.

#### Numeric table

Sentence "Guten Morgen, die Systeme laufen stabil und es gibt nichts Dringendes." (N = 71, L = 121, F = 133, 4.99 s of
audio), voice `de-de-f-1`, speed 1.0, noise from `numpy.random.default_rng(279).standard_normal` (float32), one draw per
step. The ONNX fp32 run was recorded and its inputs were fed unchanged to every runtime. Values are max abs error / SNR
against ONNX fp32, on the Apple M2 Max above.

| Output        | eager torch vs ONNX          | Core AI Swift (default) vs ONNX | Core AI CPU-only vs ONNX     |
| ------------- | ---------------------------- | ------------------------------- | ---------------------------- |
| text_features | 1.05e-5 / 119.9 dB           | 1.10e-5 / 120.5 dB              | 6.2e-6 / 121.2 dB            |
| log_durations | 5.0e-6 / 124.2 dB            | 3.3e-6 / 125.4 dB               | 4.8e-6 / 124.9 dB            |
| velocity 0..3 | <=1.8e-5 / 118.6 to 120.2 dB | <=2.2e-5 / 117.7 to 120.3 dB    | <=9.5e-6 / 120.4 to 120.8 dB |
| waveform      | 1.6e-5 / 104.2 dB            | 3.7e-6 / 112.7 dB               | 1.7e-5 / 105.1 dB            |

End to end with seed 279 the Core AI waveform is 63.9 dB against ONNX fp32 (max abs 2.6e-3, at most 86 int16 LSB
apart). For comparison, eager torch against ONNX fp32 is 60.6 dB, and ONNX int8 against fp32 is -1.6 dB. These are
numeric matches, not listening scores.

#### Timing table (Apple M2 Max, macOS 27.2)

| What                                                         | Value                                                          |
| ------------------------------------------------------------ | -------------------------------------------------------------- |
| `AIModel.specialize(.default)`, cold                         | 1.22 s                                                         |
| with `expectFrequentReshapes = true`                         | 7.71 s                                                         |
| `AIModelCache` lookup, miss / hit                            | 3 to 8 ms / under 1 ms                                         |
| `loadFunction` text / dit_step / decoder                     | 106 / 1.4 / 1.3 ms                                             |
| First run per function, first process after specialization   | text 2,761, dit_step 1,167, decoder 773 ms                     |
| First run per function, later processes (same shapes)        | 176 / 275 / 80 ms                                              |
| First run on an unseen shape, warm process                   | text 90 to 245, dit 140 to 230, decoder 50 to 390 ms           |
| Steady run (Swift, median of 10), N = 71 / L = 121 / F = 133 | 4.8 / 6.3 to 8.3 / 5.3 ms                                      |
| Steady run, CPU-only (Python)                                | 8.9 / 20 / 1,173 ms                                            |
| Whole sentence, warm shapes (Python)                         | Core AI 99 ms against ORT CPU fp32 178 ms, for 4.99 s of audio |

- **Compute units.** The defaults allow CPU, GPU and ANE. The work runs on the GPU; `--prefer=ane` gives identical
  numbers and speed, so the ANE is apparently not used for an fp32 graph. An fp16 variant is separate work.
- **Shape compile.** Each new (N, L, F) adds about 0.3 to 0.6 s per new sentence on top of about 40 ms of compute.
  `expectFrequentReshapes` lowers that to 5 to 90 ms, but not reliably, and it makes specialization take 6 times as long
  and the cache twice as big, so the executor keeps `.default`.
- **Cache.** `~/Library/Caches/coreai-cache/<OS build>/<bundle id>/<sha256 of main.mlirb>/<options hash>/model.aimodelx`.
  The default options take 262 MB on disk per specialized asset per app; `expectFrequentReshapes` takes 515 MB. The
  `.default` policy purges on storage pressure and when the asset changes.

These are Mac numbers from the export run. The pipeline measurements on a Mac and an iPhone 15 are in
[the verification record](../../verification/neural-speech.md#core-ai-apple-fp32); they are slower than the executor-only
numbers above because they include the pipeline and a new shape per sentence.

#### The asset

`articulino.aimodel` is a **directory** of three files, 274,359,859 bytes in total:

| File            | Bytes       | sha256                                                             |
| --------------- | ----------- | ------------------------------------------------------------------ |
| `main.mlirb`    | 274,359,722 | `7deb5fbe2f5fd68fd2a7ebd516628e9fc50e71bb26af494326a1c324413d4a26` |
| `main.hash`     | 32          | `159aa9c3a574b506da83d34d4897ec961f07dfb9c2ce5cc2164a1e53eb84c3b2` |
| `metadata.json` | 105         | `f4eb9a49e2b53190118a819eee32ae8ece68f66d91e87d4a5363ef5bb74d9187` |

Producer coreai-core 1.0.0b3, assetVersion 2.0, converter mode RELEASE. Weights are float32 (68,539,722 Float32 storage
elements); compute types are Float32, Int32 and Bool. **The export is not byte-reproducible**: two exports from the same
code and seeds differ in the last 16 KB of `main.mlirb`, and `metadata.json` carries a `creationDate`. The validated
asset is published and checksummed as it is (release
[`neural-speech-assets-2`](https://github.com/independo-gmbh/inderun/releases/tag/neural-speech-assets-2)) and is not
rebuilt. It ships `bundled` or `app_managed`; the demo catalog entry `articulino-de-en-coreai` is `benchmark_only`
(legal sign-off pending, #260), and no demo links a Core AI runtime path, so the entry shows unavailable in all three
demos.

### 6. What the executor does for this asset

`CoreAISpeechGraphExecutor` differs from the ONNX executor in four ways, all forced by the record above.

- **Int32.** An integer input is narrowed to int32 and the executor never hands Core AI an int64 `NDArray`. A value
  outside the int32 range throws.
- **Bounds are checked before every run.** `text` N at most 257, `dit_step` L at most 1024 and `decoder` F at most 1036
  (each at least 1, with `voice_cache` exactly [8,2,1,6,125,64]); a violation throws a `.capability` error, which maps to
  `CapabilityMismatch`, so routing can fall back to another provider. In a multi-sentence text, earlier sentences may
  already have played when a later one is refused.
- **Warm-up in `prepare`.** After specialization, `prepare` runs each function once at the minimum shapes, because the
  first run per function is slow. A failure reports the provider unavailable with `warm-up failed: <role>: <message>`
  and leaves no half-loaded runtime.
- **Consent covers specialization.** `prepare` without `allowDownload` or `autoDownload` is skipped on a device whose
  specialization cache is empty, with "A download is needed, and neither autoDownload nor allowDownload permits it."
  An app must call `prepare({ allowDownload: true })` (or register with `autoDownload`) for a Core AI package.

## Consequences

- One more runtime goes through the same seams. The pipeline, the provider and the fixtures are unchanged, and the
  composed runtime is the only new thing an app passes as `runtime`.
- Consent now covers a compile. An app that asks "download this voice?" has to word it as preparation until the typed
  preparation kind exists.
- A specialized artifact is bound to the device and the OS version. It is not portable, it can be purged, and an OS
  update can make a package `not_prepared` again.
- The stub keeps every build green on any Xcode, at the price that the real path is type-checked only where Xcode 27 is
  available. CI builds it in an advisory step (see [ci.md](../../ci.md#core-ai-module)).
- The conversion is recorded, but the asset is not byte-reproducible, so the published bytes are the reference. The
  real-model path is verified by the gated tests (`INDERUN_COREAI_MODEL_DIR`) and by the benchmark reports.
- Core AI fp32 is slower than ONNX int8 in the pipeline on the Mac and the iPhone 15 (warm RTF about 0.06 to 0.10
  against about 0.03 to 0.04), and its first `prepare` on the phone is much longer because it specializes. The numbers are
  in the verification record. In these measurements ONNX int8 is the faster runtime on both devices; Core AI is the Apple-native path.
- The specialization cache costs about 262 MB per specialized asset per app.
- Input size is bounded (text at most 257 letters per sentence, 1024 DiT frames, 1036 decoder frames). A longer one is
  refused with a mapped error rather than run on wrong numbers, so a very long word or a very slow speed can route away.

Follow-ups, none built:

- A typed preparation kind on the contracts, so consent UI can tell a download from a compile.
- A CI test of a successful `prepare` needs either a small asset or an executor seam; today only the gated real-model
  test covers it.
- Every `speech.graphs` entry is specialized, including one the pipeline does not use.
