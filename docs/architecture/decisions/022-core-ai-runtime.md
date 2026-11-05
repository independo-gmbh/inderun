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
it runs. Specialization takes minutes and its result lives in a system cache, so it is neither a file the developer
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
`synthesize` with `model not prepared: <id@version>`. An incomplete package (a missing role, a missing frontend config,
a voice without its file) is refused by the Articulino metadata check before any specialization starts, so a
minutes-long compile is never spent on a package that cannot run. For the same reason `prepare` reads each asset's
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

The `.aimodel` is produced offline from the upstream PyTorch checkpoint with Apple's `coreai-torch`:

1. `torch.export` of the three host-facing functions, with bounded `Dim`s.
2. `run_decompositions(coreai_torch.get_decomp_table())`.
3. `TorchConverter().add_exported_program(exported, input_names, output_names, entrypoint_name=<role>)`, once per role.
4. `to_coreai()`.
5. `save_asset("articulino.aimodel")`.

The entrypoints are `text`, `dit_step` and `decoder`, with the same tensor names and shapes as the ONNX graphs.
`text_mask` is an int64 input and is cast to bool inside the exported program, as the ONNX package does with a Cast
node. [`tools/neural-speech/prepare_coreai_package.py`](../../../tools/neural-speech/README.md) wraps the asset into a
package; it does not run the export.

Pending the export spike (spike 0b, run by the owner): the asset hash, the exact shape bounds, the specialization time
and the device realtime factor. This ADR records none of them until they are measured. The asset ships `bundled` or
`app_managed`; IndeRun never downloads it.

## Consequences

- One more runtime goes through the same seams. The pipeline, the provider and the fixtures are unchanged, and the
  composed runtime is the only new thing an app passes as `runtime`.
- Consent now covers a compile. An app that asks "download this voice?" has to word it as preparation until the typed
  preparation kind exists.
- A specialized artifact is bound to the device and the OS version. It is not portable, it can be purged, and an OS
  update can make a package `not_prepared` again.
- The stub keeps every build green on any Xcode, at the price that the real path is type-checked only where Xcode 27 is
  available. CI builds it in an advisory step (see [ci.md](../../ci.md#core-ai-module)).
- The conversion is reproducible from the recorded chain, but its numbers are pending spike 0b, and the real-model path
  is verified only by the gated tests (`INDERUN_COREAI_MODEL_DIR`) once an asset exists.

Follow-ups, none built:

- A typed preparation kind on the contracts, so consent UI can tell a download from a compile.
- A CI test of a successful `prepare` needs either a small asset or an executor seam; today only the gated real-model
  test covers it.
- Every `speech.graphs` entry is specialized, including one the pipeline does not use.
