# ONNX Runtime Provider Family

This document specifies the ONNX Runtime (ORT) provider family for IndeRun and the
provider-neutral model-loading contract used for developer-supplied/custom local models. It is the
architecture baseline for the platform implementation tickets: #85 (Web), #87 (Android), and #86
(Apple platforms). Those tickets implement providers; they must not re-decide the boundaries below.

This is a Milestone 2 specification. Field-level shapes live in the schema, not in this prose (see
[Model Package Contract](#model-package-contract)). The Web, Apple, and Android members are all
implemented (see [Web Implementation](#web-implementation), [Apple
Implementation](#apple-implementation), and [Android Implementation](#android-implementation)).

## Classification And Boundaries

ONNX Runtime is a **runtime**, not an IndeRun provider. IndeRun exposes a **provider family** of
adapters that wrap ORT per platform. The runtime is an implementation detail behind the adapter
boundary.

The app-facing IndeRun API stays provider-neutral: it exposes provider descriptors, task/mode
support, privacy behavior, dynamic capabilities, route explanations, cancellation behavior, and
normalized errors. It must not expose ORT session options, ORT `InferenceSession` details, or ORT
Execution Providers.

**ORT Execution Providers are not IndeRun routing concepts.** ORT Execution Providers (CPU, WebGPU,
WebGL, WebNN, CoreML, NNAPI, XNNPACK, …) are hardware/backend execution choices _inside_ ORT. They
are not equivalent to IndeRun providers and never appear as public routing targets. Their
availability feeds only into a provider's dynamic capability check and, indirectly, into a route
rejection `reason` string. The router selects an IndeRun provider, never an ORT backend.

## Provider Family Members

One adapter per platform, each wrapping the platform's ORT distribution:

- Web: ORT Web (`onnxruntime-web`) — tracked in #85
- Android: ORT Mobile (`onnxruntime-android`) — tracked in #87
- Apple platforms: ORT Mobile (`onnxruntime-c` / `onnxruntime-objc`) — tracked in #86

Provider ids follow the existing plain-string id convention: `local.onnx.genai.web` (confirmed by the
Web implementation), `local.onnx.genai.android`, `local.onnx.genai.apple`. The mobile ids remain a
proposal until those tickets land. Every family member is `type: local` with
`privacy.dataLeavesDevice: false`.

## Interaction Mode And Task

Initial support is **Mode 1 `run` only**, task `text_to_text`. This matches the current public
execution path (see `architecture.md`). Streaming (Mode 2) and sessions (Mode 3) are out of scope
for this family and remain future additive work; adapters declare `supports.run: true` and leave the
forward-looking flags false.

## Runtime Path Decision: GenAI First

The mandated first implementation path is **ONNX Runtime GenAI** for `text_to_text`. ORT GenAI
handles the generative loop for ONNX models — tokenization, inference, logits processing, search and
sampling, and KV-cache management — and ships tutorials for models such as Phi-3, Phi-2, and
DeepSeek-R1-Distill.

**Risk (accepted):** the ORT GenAI (`generate()`) API is documented as _"in preview and is subject
to change"_. Implementers must isolate the GenAI call behind an injectable runtime seam (below) so a
version change is contained in the adapter.

**Correction — GenAI has no browser build.** ORT GenAI ships Python, .NET, C/C++, and Java packages
only; there is no JavaScript/browser distribution, and `onnxruntime-web` provides raw inference
without a generative loop (tokenization, sampling, KV cache). The Web member therefore satisfies the
_role_ GenAI was mandated for — not the literal package — by defaulting to Transformers.js, which
runs ONNX models on `onnxruntime-web` and owns the generative loop. Source:
<https://onnxruntime.ai/docs/genai/howto/install.html>.

**Correction — the mobile members target raw ORT Mobile, not the ORT GenAI package.** Both shipped
mobile members (Apple, Android) default to the platform's raw ONNX Runtime Mobile bindings plus a
hand-written decode loop and an external tokenizer, rather than
`onnxruntime-genai`/`onnxruntime-extensions`. This keeps both defaults on the same well-established,
non-preview API surface used by the Web member's underlying runtime. Both mobile members now
auto-detect and reuse `past_key_values`/KV-cache export shapes where the graph and `config.json`
support it (falling back to full-sequence recompute otherwise) and configure an accelerated
execution provider (CoreML/XNNPACK on Apple, NNAPI/XNNPACK on Android) with a CPU fallback — this is
no longer a blanket "no KV-cache reuse, CPU-only" limitation, though none of it has been exercised
against a real model on a real device beyond the plain-path verification noted in each platform
section (#88). This is exactly what the injectable seam exists for regardless: the seam is the
contract, and any application (or a future IndeRun default) can supply an
ORT-GenAI-backed `OnnxGenAiRuntime`/`AndroidOnnxGenAiRuntime` implementation without changing the
provider.

**Deterministic fixture fallback.** IndeRun already makes on-device adapters testable without their
native backend via an injectable runtime interface (`AppleFoundationModelsRuntime`,
`AndroidMlKitGenAiRuntime`). The ORT family follows the same pattern: the adapter depends on an
injectable ORT runtime interface, and a deterministic in-memory fixture implementation proves the
model-package contract, capability checks, routing, and error normalization independently of ORT
GenAI stability. The fixture is the test seam and the fallback if GenAI proves too unstable for the
first release — it is not the mandated production path.

## Platform Implementation Order

1. Web (#85)
2. Android (#87)
3. Apple platforms (#86)

Web first avoids mobile binary/build complexity and validates the model source/package contract
quickly. Mobile follows once the contract is proven.

## Model Package Contract

A **model package** is provider-neutral bootstrap metadata that describes a developer-supplied model:
identity, version, format, task support, runtime compatibility, files, integrity, license/source
metadata, and known resource limits. It is configuration resolved before execution — not part of the
public `TaskRequest`/`TaskResult` surface — and it must not carry raw secrets (`authContextRef`
remains the credential pattern). That rule is enforced, not just documented: validation rejects
inline secret keys anywhere in the package, and `source.ref` additionally rejects URL userinfo
(`https://user:pass@host/…`), so a credential-bearing registry or download URL cannot be smuggled
through the model source. Adapters that need authenticated model fetches resolve credentials through
the host's secure storage via `authContextRef`.

The normative field shapes are defined by the `ModelPackage` schema
(`contracts/schemas/model-package.schema.json`), generated into the TypeScript, Kotlin, and Swift
contracts. The schema is intentionally lean and forward-compatible: only `id` and `format` are
required, and unknown fields are permitted. This document does not restate the fields; consult the
schema.

IndeRun does not own model download/update flows in Milestone 2. Host applications may bundle,
download, cache, or otherwise supply model files; the model package's `source` describes how.

## Model Source Support Matrix

The `ModelPackage.source.sourceType` discriminator enumerates where model files come from. Expected
support per platform for the first implementations:

| Source type    | Web         | Apple platforms | Android   |
| -------------- | ----------- | --------------- | --------- |
| `registry`     | Supported   | Deferred        | Deferred  |
| `bundled`      | Supported   | Supported       | Supported |
| `programmatic` | Supported   | Supported       | Supported |
| `app_managed`  | Supported   | Supported       | Supported |
| `remote`       | Deferred    | Deferred        | Deferred  |
| `filesystem`   | Unsupported | Supported       | Supported |

Notes:

- `registry` (Hugging Face-style repos) is Web-first because ORT Web loads model/WASM assets over
  HTTP; native registry resolution is deferred to a later iteration.
- `filesystem` is unsupported on Web because browsers do not expose arbitrary local paths; Web relies
  on `bundled`/`app_managed`/`programmatic`/`registry` instead.
- `remote` (host-managed download) is deferred everywhere: the host application performs the download
  and then supplies files as `bundled`/`app_managed`/`programmatic`. IndeRun does not own the
  download in Milestone 2.
- "Deferred" means the contract permits it but the first implementation need not support it;
  "Unsupported" means the platform cannot honor it.

## Dynamic Capability Checks

Each adapter implements `capabilities(host)` returning the standard
`{ available: boolean, reason?: string }` shape. The family recognizes the following internal
capability failure conditions, each surfaced through the `reason` string when `available` is false:

- runtime package unavailable
- runtime initialization failed
- model source unavailable
- model files missing
- model package malformed
- checksum/integrity mismatch
- unsupported model format
- unsupported task
- unsupported interaction mode
- incompatible opset/operator/runtime capability
- tokenizer/config missing
- execution backend unavailable
- insufficient memory or resource constraints
- platform/browser/API unsupported
- model output malformed (detected at run time)

This vocabulary is provider-internal. It is **not** a public enum and does not extend the routing
contract. It flattens into the coarse `{ available, reason }` capability snapshot the shared route
planner consumes.

## Route Rejection Reasons

The shared route planner uses a fixed rejection vocabulary
(`route-plan.schema.json` → `rejectedProviders[].reasons[].code`):
`task_not_supported`, `run_not_supported`, `privacy_constraint`, `cloud_constraint`, `offline`,
`capability_unavailable`. The ONNX family adds no new codes. Every capability failure above maps to
`capability_unavailable`, with the specific condition carried in the human-readable `reason`/
`message` string.

Routing stays deterministic and inspectable. Under a strict-local policy the ORT provider is selected
only when its capability check passes; otherwise the planner emits an explainable
`capability_unavailable` rejection. It must not silently fall back to a cloud provider unless policy
allows cloud execution.

## Provider Error Mapping

Raw ORT exceptions must never leak to app code. Adapters map failures into the normalized
`IndeRunError` taxonomy (`inderun-error.schema.json`: `CapabilityMismatch`, `Offline`, `AuthError`,
`RateLimited`, `Timeout`, `Unavailable`, `Internal`) using the existing error factories and the
`toIndeRunException` normalizer. Expected mappings:

| Failure condition                               | `errorClass`                                  |
| ----------------------------------------------- | --------------------------------------------- |
| Capability mismatch (checked before attempt)    | `CapabilityMismatch`                          |
| Provider/runtime unavailable                    | `Unavailable`                                 |
| Invalid request                                 | `Internal` (request-shaped)                   |
| Model unavailable / files missing               | `CapabilityMismatch`                          |
| Model incompatible (opset/operator/format)      | `CapabilityMismatch`                          |
| Runtime initialization failure                  | `Unavailable`                                 |
| Resource exhaustion (memory/backend)            | `Unavailable`                                 |
| Timeout                                         | `Timeout`                                     |
| Cancelled                                       | terminal cancellation (no post-cancel events) |
| Provider failure (unexpected runtime throwable) | `Internal`                                    |
| Internal error                                  | `Internal`                                    |

The precise class-to-cause mapping lives in the adapter code, consistent with `providers.md`. There
is no `RateLimited`/`AuthError`/`Offline` path for a purely local runtime; those remain cloud
concerns.

## Cancellation

Family members declare `cancel: soft`, matching the other on-device adapters (Apple Foundation
Models, ML Kit). ORT `run` is not hard-interruptible; cancellation produces a terminal cancellation
outcome with no user-visible events after the cancel point, per `architecture.md`.

## Web Implementation

The Web member ships in `@independo/inderun-web` under the `./onnx` subpath entry point, kept out of
the provider-agnostic root index like the OpenAI adapter. Provider id: `local.onnx.genai.web`.
Descriptor: `type: local`, `transport: in_process`, `supports.run: true` with all forward-looking
flags false, `cancel: soft`, `privacy.dataLeavesDevice: false`. Option shapes and the error table for
consumers live in the package README, not here.

**Runtime seam.** `OnnxTextGenerationRuntime` has two methods: `prepare(modelPackage)` returning the
`{ available, reason? }` snapshot, and `generate(input, signal)` returning normalized text. Three
implementations exist:

- `createTransformersJsRuntime()` — the default. Lazily imports `@huggingface/transformers`, which the
  application installs; IndeRun does not bundle it. Initialization failures are reported as
  _runtime package unavailable_ rather than thrown, so routing degrades to an explainable rejection
  rather than a crash. The import specifier stays statically resolvable so bundlers can find the
  package; apps that do not install it supply their own runtime instead.
- `createFixtureOnnxRuntime()` — the deterministic in-memory fixture mandated above. It is the test
  seam and lets demos exercise the on-device route offline.
- Any application-supplied implementation, for example a hand-rolled `onnxruntime-web` pipeline.

Runtime failures are signalled with `OnnxRuntimeError`, whose `kind` (`capability`, `unavailable`,
`timeout`, `internal`) selects the IndeRun error class per the mapping table above; anything else a
runtime throws normalizes to `Internal`. Allocation failures during model load (ONNX Runtime reports
these as `std::bad_alloc` from session creation) are resource exhaustion and map to `Unavailable`,
not `CapabilityMismatch`.

The default runtime loads quantized weights (`q4f16` on WebGPU, `q4` otherwise) because
Transformers.js would otherwise select `fp32` and exhaust browser memory. It covers models that load
through the `text-generation` pipeline, which is the Mode 1 `text_to_text` case this family targets.
Multimodal exports are split across separate vision/audio/embedding/decoder graphs and need
`AutoProcessor` plus a model-specific class; that is out of scope for `text_to_text` and, if ever
needed, belongs in a custom runtime behind the seam rather than in the provider.

**Model sources.** The Web member honors `registry`, `bundled`, `programmatic`, and `app_managed` and
rejects the other two in `capabilities()`, matching the matrix above: `filesystem` as unsupported
(browsers cannot read arbitrary local paths) and `remote` as deferred (the host downloads and then
re-declares the files). The Transformers.js runtime maps `registry` refs to hub model ids, points the
loader at locally served assets for `bundled`/`app_managed`, and requires an application-supplied
generator for `programmatic`.

**Capability gate order.** Model package schema validation (reusing `getModelPackageValidationIssues`
from the contracts package, including its inline-secret and URL-userinfo rules) → Web source-type
support → `runtime.platforms` includes `web` → declared tasks include `text_to_text` → delegate to
`runtime.prepare`. Every failure flattens to one `capability_unavailable` route rejection carrying
the reason string, for example:

- `capability_unavailable`: _model source unavailable: 'filesystem' model sources are unsupported on
  Web because browsers cannot read arbitrary local paths._
- `capability_unavailable`: _runtime package unavailable: install the optional dependency
  @huggingface/transformers (…)._
- `CapabilityMismatch` at run time when the same gate fails pre-attempt; `Timeout` when the
  generation budget (`constraints.timeoutMs`, else the provider's `timeoutMs`) elapses; `Unavailable`
  for runtime initialization failures and resource exhaustion. There is no `AuthError`,
  `RateLimited`, or `Offline` path.

**Browser constraints.** WASM is the CPU baseline; WebGPU is used when `navigator.gpu` exists.
Backend choice is an internal detail surfaced only in capability `reason` strings — never a routing
target. WASM threads require cross-origin isolation (`Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: require-corp`), and the host application is responsible for serving
and caching model and ORT WASM assets; IndeRun owns no download or cache layer in Milestone 2.

**Authoring a custom local provider.** Implement `OnnxTextGenerationRuntime` rather than a new
`ProviderAdapter` when the model is ONNX: the provider already owns descriptor semantics, model
package validation, source gating, timeouts, and error normalization. Implement `ProviderAdapter`
directly only for a different runtime family.

## Apple Implementation

The Apple member ships as its own SwiftPM library product, `IndeRunOnnxProviders`
(`ios/IndeRun/Sources/IndeRunOnnxProviders`), kept out of `IndeRunSwift`/`IndeRunAppleProviders`
like the Web member is kept out of the provider-agnostic root index. Provider id:
`local.onnx.genai.apple`. Descriptor: `type: .local`, `transport: .inProcess`, `supports.run:
true` with all forward-looking flags false, `cancel: .soft`, `privacy.dataLeavesDevice: false`.

**Platform minimums.** Landing this member raised the whole SDK's minimum platforms from iOS 15 /
macOS 12 to **iOS 16 / macOS 14**, because its dependencies require it: the official ONNX Runtime
SPM bindings (`microsoft/onnxruntime-swift-package-manager`, macOS 14 minimum) and
`swift-transformers`'s `Tokenizers` module (iOS 16 minimum). SwiftPM has no per-target platform
override in a single manifest, so this is a package-wide, breaking bump — every IndeRun Apple
consumer, not only ONNX users, now needs iOS 16 / macOS 14.

**Runtime seam.** `OnnxGenAiRuntime` has two methods: `prepare(_:)` returning the `{available,
reason?}` snapshot, and `generate(_:)` returning normalized text — the same shape as the Web
member's `OnnxTextGenerationRuntime`, adapted to Swift Concurrency (cancellation is ambient via
`Task` cancellation rather than an explicit `AbortSignal` parameter). Two implementations exist:

- `SystemOnnxGenAiRuntime()` — the default. Tokenizes with `swift-transformers`'s
  `AutoTokenizer.from(modelFolder:)`, applying the tokenizer's chat template
  (`Tokenizer.applyChatTemplate`) when `tokenizer_config.json` declares one and falling back to a
  plain `"role: content"` join otherwise; runs inference through the official ONNX Runtime SPM
  bindings (`OnnxRuntimeBindings` / `ORTSession`). **IO contract**: both supported decode paths
  below require `input_ids`/`attention_mask` inputs (`int64`) and a `logits` output (`float32`,
  `[1, sequenceLength, vocabSize]`). Which path a given model uses is auto-detected from the
  graph's declared input names at load time — no `ModelPackage` field or app-facing configuration
  selects it:
  - **Plain** (no `past_key_values.*` inputs): shape `[1, sequenceLength]`, the full sequence
    recomputed every decode step. Always supported; the fallback whenever KV-cache detection can't
    establish every assumption below.
  - **KV-cache** (`past_key_values.{layer}.key`/`.value` inputs present, the legacy (non-merged)
    Hugging Face Optimum `decoder_with_past_model` export convention): exactly one token is fed as
    `input_ids` per model call — this graph shape traces `input_ids`'s sequence-length axis fixed
    at 1, not dynamic, so (unlike a merged/optional-past graph) it cannot accept the whole prompt
    in a single call. The prompt is therefore replayed through the same session one token at a
    time (discarding logits) to build up `past_key_values` before the first real generated token,
    then generation proceeds one token per call the same way, with `attention_mask` covering the
    full running sequence and each call's `present.{layer}.key`/`.value` outputs threaded back in
    as the next call's `past_key_values.*` inputs directly (no copy). Detection additionally
    requires `num_hidden_layers` (or GPT-2-style `n_layer`), `num_attention_heads`/`n_head` (or
    `num_key_value_heads` for GQA models), and `hidden_size`/`n_embd` (or an explicit `head_dim`)
    to be readable from `config.json` in the model directory, and every expected
    `past_key_values.{layer}.{key,value}` input /
    `present.{layer}.{key,value}` output to be present by that naming convention; an optional
    `position_ids` input is fed the running absolute position when the graph declares it. Graphs
    that instead declare a `use_cache_branch` boolean input (merged Optimum exports, which accept
    the whole prompt on their first call) fall back to the plain path instead — the ONNX Runtime
    Objective-C bindings this runtime depends on (as of `onnxruntime-swift-package-manager`
    1.24.2) expose no `bool` tensor element type to feed it, and this runtime does not implement
    the merged graph's alternate calling convention. This path's one-token-per-call shape was
    corrected against a real device failure (`Got invalid dimensions for input: input_ids ...
    Expected: 1`) surfaced by a real exported model (LaMini-GPT, added to the iOS demo app);
    detection remains deliberately conservative — any unresolvable assumption falls back to the
    plain path rather than guessing. See #88 for remaining broader real-device verification (load
    time, memory, cancellation, other model families).

  **Graph file convention**: `ModelPackage.files.required` has no positional semantics of its own
  in the schema, so this runtime defines one — the _first_ entry is the ONNX graph file; any
  remaining entries (for example external weight shards) must be present alongside it but are not
  referenced directly. `ModelPackage.integrity.checksums` (`sha256:<hex>`) are verified for every
  file this runtime resolves, before load. The session cache key covers `id`, `version`, `source`,
  and `integrity.checksums` together, not `id` alone, so swapping a model's bytes without bumping
  `id` does not silently keep serving a stale session.

  **Execution.** A single `ORTEnv` is created once and shared process-wide across every session,
  per ORT's own guidance that one environment should exist per process rather than per session.
  Session creation and every `run()` call execute on a dedicated serial queue rather than inline on
  the Swift Concurrency cooperative thread pool, since `ORTSession.init`/`run()` are blocking
  synchronous calls. The CoreML execution provider is configured by default on the plain decode
  path (`ORTCoreMLExecutionProviderOptions` with its own defaults), falling back to XNNPACK and
  then ORT's default CPU EP if CoreML EP configuration fails on the host (availability and
  compilation behavior vary by device/OS); `setIntraOpNumThreads` is set explicitly, bounded by
  the device's active processor count, rather than left at ORT's implicit default. CoreML compiles
  the graph into an on-device `.mlmodelc` cache on first load — managed entirely by ORT/CoreML, not
  by IndeRun — keyed by the model and execution-provider options, and invalidated by a changed
  model file or EP option set. **The KV-cache path never uses CoreML**, regardless of host
  availability: its first decode call feeds a genuinely zero-length `past_key_values` tensor (see
  above), and ORT's CoreML EP rejects a dynamic-shaped input with zero elements at run time
  (`Input (past_key_values.0.key) has a dynamic shape (...) but the runtime shape (...) has zero
  elements. This is not supported by the CoreML EP.` — a real device failure surfaced by
  LaMini-GPT, not a hypothetical one); since ORT's execution provider list is fixed at
  session-creation time, not selectable per call, that graph's session is created directly on
  XNNPACK/CPU. The plain decode path preallocates its `input_ids`/`attention_mask`
  buffers once per generation (sized to the max possible sequence length) and writes into a
  subrange each step rather than allocating fresh buffers per token; the KV-cache path's per-call
  buffers are already fixed-size (exactly one token each), and its `past_key_values` reuse (above)
  is itself the buffer-reuse win for that path — though note the prompt-replay calls mean this
  path issues one ORT call per prompt token plus one per generated token, not one call per
  generated token as the plain path does.

  **Decoding** defaults to greedy (argmax). Setting `generation.temperature` switches to sampling:
  logits are scaled by `1 / temperature`, optionally narrowed to the smallest token set whose
  cumulative probability reaches `generation.topP` (nucleus sampling), then sampled — seeded
  (reproducibly) when `generation.seed` is set, otherwise drawn from
  `SystemRandomNumberGenerator`. `generation.stop` sequences are honored on both decode paths.
  Apps that need an accelerated execution provider this runtime doesn't configure, a different
  sampling strategy, or a KV-cache export shape this runtime doesn't auto-detect (for example
  `use_cache_branch`-gated merged graphs) supply their own `OnnxGenAiRuntime`; real-device
  verification (load time, token latency, peak memory, cancellation behavior, repeated-run
  stability against an actual model, for both decode paths) is tracked in #88 — this default has
  not yet been run against a real model on-device. `programmatic` model sources are also out of
  scope for this default runtime (no files to resolve, matching the Web member's own
  `programmatic` carve-out); it reports _runtime package unavailable_ rather than throwing.
- `createFixtureOnnxRuntime(options:)` — the deterministic in-memory fixture mandated above,
  public/importable like the Web member's `createFixtureOnnxRuntime` (this diverges deliberately
  from the private-to-tests fixture convention used by `AppleFoundationModelsProvider`, per the
  fixture's explicit mandate to support offline demos as well as tests).
- Any application-supplied implementation of `OnnxGenAiRuntime`.

**Model sources.** The Apple member honors `bundled`, `programmatic`, `app_managed`, and
`filesystem`, and rejects `registry` and `remote` in `capabilities()`, matching the support
matrix above. `SystemOnnxGenAiRuntime` resolves `bundled` under `Bundle.main.resourceURL`,
`filesystem` and `app_managed` as a directory path from `source.ref` (absolute for `filesystem`,
relative to the app's Application Support directory for `app_managed`).

**Capability gate order.** Model package structural validation (a hand-written
`getModelPackageValidationIssues` in `IndeRunOnnxProviders` — no generated JSON Schema validator
exists in Swift, so this is a scoped subset covering `id`/`format` presence, inline-secret keys,
and `source.ref` URL-userinfo, not a full AJV-equivalent port) → Apple source-type support →
`runtime.platforms` includes `apple` → declared tasks include `text_to_text` → delegate to
`runtime.prepare`. Every failure flattens to one `capability_unavailable` route rejection, for
example:

- `capability_unavailable`: _model source unavailable: 'registry' model sources are deferred on
  Apple platforms; supply model files as bundled, programmatic, app_managed, filesystem._
- `capability_unavailable`: _model files missing: 'model.onnx' not found at \<resolved path\>._
- `CapabilityMismatch` at run time when the same gate fails pre-attempt; `Timeout` when the
  generation budget (`constraints.timeoutMs`, else the provider's configured timeout) elapses;
  `Unavailable` for ONNX Runtime session initialization failures. There is no `AuthError`,
  `RateLimited`, or `Offline` path. Real `Task` cancellation (the caller cancelling its own task,
  as opposed to the provider's own deadline elapsing) propagates as a raw `CancellationError`
  rather than an `IndeRunException`, matching the established Swift-side convention
  (`OpenAIProvider`, `IndeRun.swift`) rather than the Web member's `AbortError → Timeout` mapping —
  the two platforms differ here because Swift Concurrency has first-class cancellation and the
  rest of this SDK already relies on it. `ORTSession.run()` itself is a blocking synchronous call
  that cannot be interrupted mid-call; cancellation is observed only between decode steps
  (`cancel: .soft`), so a cancelled or timed-out request still waits out its current in-flight
  step.

**Packaging and binary size.** ORT Mobile's native binary is statically linked via the SPM
`onnxruntime` product and adds meaningfully to app binary size; the model files themselves must
also fit on-device disk and load into device memory (see
[Platform Constraints](#platform-constraints-reference)). Neither IndeRun nor this provider owns
model download/update flows in Milestone 2 — apps that fetch models remotely still supply them as
`bundled`/`app_managed`/`programmatic` once resolved, per the model source matrix.

**Authoring a custom local provider.** Implement `OnnxGenAiRuntime` rather than a new
`ProviderAdapter` when the model is ONNX: `OnnxRuntimeAppleProvider` already owns descriptor
semantics, model package validation, source gating, timeouts, and error normalization. Implement
`ProviderAdapter` directly only for a different runtime family, mirroring the Web guidance above.

## Android Implementation

The Android member ships as its own Gradle library module, `inderun-onnx-providers`
(`android/inderun-onnx-providers`), following the same one-module-per-provider-family convention as
`inderun-mlkit-providers` and `inderun-openai-providers`. Provider id: `local.onnx.genai.android`.
Descriptor: `type: local`, `transport: in_process`, `supports.run: true` with all forward-looking
flags false, `cancel: soft`, `privacy.dataLeavesDevice: false`.

**Runtime seam.** `AndroidOnnxGenAiRuntime` has two suspend methods: `prepare(modelPackage)`
returning the `{available, reason?}` snapshot, and `generate(input)` returning normalized text — the
same shape as the Web and Apple members' runtime seams, adapted to Kotlin Coroutines (cancellation
is ambient via coroutine `Job` cancellation, matching Apple's `Task` cancellation model rather than
the Web member's explicit `AbortSignal` parameter). Two implementations exist:

- `SystemAndroidOnnxGenAiRuntime(context)` — the default. Runs inference through ONNX Runtime
  Mobile's Java bindings (`com.microsoft.onnxruntime:onnxruntime-android`) and tokenizes with a
  Hugging Face tokenizer (`ai.djl.huggingface:tokenizers` plus its Android native binding,
  `ai.djl.android:tokenizer-native`). Implemented across several files by concern, mirroring the
  Apple member's own split (`SystemOnnxGenAiRuntime.swift` + `OnnxSessionLoading*.swift` +
  `OnnxSampling.swift` + `OnnxTensorExecution.swift` + `SystemOnnxGenAiRuntime+Decoders.swift`):
  `SystemAndroidOnnxGenAiRuntime.kt` (orchestration), `OnnxSessionLoading.kt` (session/tokenizer/EP
  loading, asset extraction, checksums), `OnnxSessionLoadingKvCacheDetection.kt` (decode-strategy
  detection), `OnnxDecoders.kt` (the two decode-step strategies below), `OnnxSampling.kt`
  (temperature/top-p/seed sampling), and `OnnxTensorExecution.kt` (the dedicated dispatcher and
  `OrtException`-wrapping run helper).

  **IO contract**: this runtime auto-detects, from the loaded graph's declared input names, which
  of two decoder-only export shapes a model uses — no `ModelPackage` field or app-facing
  configuration selects it, identical in spirit to the Apple member's detection:
  - **Plain** (no `past_key_values.*` inputs): shape `[1, sequenceLength]`, the full sequence
    recomputed every decode step. Always supported; the fallback whenever KV-cache detection can't
    establish every assumption below.
  - **KV-cache** (`past_key_values.{layer}.key`/`.value` inputs present, the legacy (non-merged)
    Hugging Face Optimum `decoder_with_past_model` export convention): exactly one token is fed as
    `input_ids` per model call — this graph shape traces `input_ids`'s sequence-length axis fixed
    at 1, so the prompt is replayed through the same session one token at a time (discarding
    logits) to build up `past_key_values` before the first real generated token, then generation
    proceeds one token per call the same way, with each call's `present.{layer}.key`/`.value`
    outputs threaded back in as the next call's `past_key_values.*` inputs directly (no copy).
    Detection additionally requires `num_hidden_layers` (or GPT-2-style `n_layer`),
    `num_attention_heads`/`n_head` (or `num_key_value_heads` for GQA models), and
    `hidden_size`/`n_embd` (or an explicit `head_dim`) to be readable from `config.json`, and every
    expected `past_key_values.{layer}.{key,value}` input / `present.{layer}.{key,value}` output to
    be present by that naming convention; an optional `position_ids` input is fed the running
    absolute position when the graph declares it. Graphs that instead declare a `use_cache_branch`
    boolean input (merged Optimum exports) fall back to the plain path — this runtime does not
    implement the merged graph's alternate calling convention. Detection is deliberately
    conservative — any unresolvable assumption falls back to the plain path rather than guessing —
    and, like the rest of this default runtime, has not been exercised against a real KV-cache
    export on an Android device; that remains part of #88, mirroring the Apple member's own
    real-device carve-out (the Apple member's equivalent path *was* corrected against a real device
    failure on LaMini-GPT — the Android path is unverified, not merely undocumented).

  **Graph file convention**: same as Apple — `ModelPackage.files.required`'s _first_ entry is the
  ONNX graph file; remaining entries (for example external weight shards) must be present alongside
  it. Every file named in `ModelPackage.integrity.checksums` is verified before load, not only the
  required-file list; an algorithm prefix other than `sha256:` is a capability failure rather than a
  silently skipped check. The session cache key covers `id`, `format`, `version`, `source`, and
  `integrity.checksums` together, not `id` alone.

  **Execution.** `OrtEnvironment.getEnvironment()` already returns a process-wide singleton per its
  own Java API contract, so — unlike the Apple member's `ORTEnv`, which needed an explicit
  shared-instance wrapper — no separate wrapper is needed here; every session reuses the same
  environment instance as-is. Session creation and every `run()` call execute on a dedicated
  single-thread `CoroutineDispatcher` rather than `Dispatchers.IO`/`Dispatchers.Default`, since
  `OrtSession.run()` and session construction are blocking synchronous calls. The NNAPI execution
  provider is configured by default on the plain decode path (`SessionOptions.addNnapi()`), falling
  back to XNNPACK (`addXnnpack`) and then ORT's default CPU EP if NNAPI configuration fails on the
  host; `setIntraOpNumThreads` is set explicitly, bounded by the device's available processor
  count, rather than left at ORT's implicit default. **The KV-cache path never uses NNAPI**,
  regardless of host availability: its first decode call feeds a genuinely zero-length
  `past_key_values` tensor, and the Apple member's CoreML EP is documented to reject an analogous
  zero-length dynamic-shaped input at run time on a real device — this runtime applies the same
  conservative rule to NNAPI on the same reasoning, but whether NNAPI actually rejects it the same
  way is an unverified assumption carried over from the Apple finding, not a confirmed
  Android-device result (#88). Since ORT's execution provider list is fixed at session-creation
  time, that graph's session is created directly on XNNPACK/CPU. The plain decode path preallocates
  its `input_ids`/`attention_mask` buffers once per generation, as direct `LongBuffer`s sized to
  `promptLength + maxOutputTokens`, and writes into a growing subrange each step rather than
  allocating a fresh buffer per token; the KV-cache path's `past_key_values` reuse (above) is itself
  the buffer-reuse win for that path.

  **Decoding** defaults to greedy (argmax). Setting `generation.temperature` switches to sampling:
  logits are scaled by `1 / temperature`, optionally narrowed to the smallest token set whose
  cumulative probability reaches `generation.topP` (nucleus sampling), then sampled — seeded
  (reproducibly) via `kotlin.random.Random(seed)` when `generation.seed` is set, natively seedable
  unlike the Apple member's `SystemRandomNumberGenerator` (which needed a custom `SplitMix64`).
  `generation.stop` sequences are honored on both decode paths. **Stop conditions**: generation
  stops on the tokenizer's end-of-sequence token — resolved from the model config JSON's
  `eos_token_id` field, since the DJL tokenizer binding does not expose special token ids the way
  `swift-transformers` does on Apple — on a `generation.stop` suffix match, or once
  `maxOutputTokens` is reached, whichever comes first; cancellation is checked before every decode
  step.

  Unlike the Apple and Web members, this default runtime does **not** attempt chat-template
  application: `ai.djl.huggingface:tokenizers` (`0.33.0`) exposes no `applyChatTemplate`-equivalent
  API or special-token accessor on its public `HuggingFaceTokenizer` surface — this is a verified,
  permanent gap for this runtime, not an oversight pending evaluation, and it falls back
  unconditionally to a plain `"role: content"` join. Apps that need chat templates, an execution
  provider/sampling strategy this runtime doesn't configure, or a KV-cache export shape this runtime
  doesn't auto-detect (for example `use_cache_branch`-gated merged graphs) supply their own
  `AndroidOnnxGenAiRuntime`; real-device verification (load time, token latency, peak memory,
  cancellation behavior, repeated-run stability against an actual model, for both decode paths, and
  whether NNAPI actually degrades on the KV-cache path's zero-length tensor the way CoreML does) is
  tracked in #88 — this default has not yet been run against a real model on-device beyond the
  plain-path DistilGPT-2 verification below. `programmatic` model sources are out of scope for this
  default runtime (no files to resolve, matching the Web/Apple members' own `programmatic`
  carve-out); it reports _runtime package unavailable_ rather than throwing.

  **Native dependency**: `ai.djl.android:tokenizer-native`'s
  prebuilt `libdjl_tokenizer.so` dynamically links `libc++_shared.so`, but the artifact does not
  bundle it — an app that depends on `inderun-onnx-providers` and doesn't separately provide
  `libc++_shared.so` for every targeted ABI fails the first tokenizer load with
  `UnsatisfiedLinkError: dlopen failed: library "libc++_shared.so" not found`, surfaced by this
  provider as a `capability_unavailable` "tokenizer/config missing" reason (the underlying
  `UnsatisfiedLinkError` is attached as `originalError` but not included in the reason string).
  `inderun-onnx-providers` now declares a no-op CMake native target
  (`src/main/cpp/CMakeLists.txt`, `-DANDROID_STL=c++_shared`) purely so the NDK's own CMake
  toolchain copies the matching `libc++_shared.so` into the build output per ABI and AGP packages
  it — no binary committed to source control, sourced from the module's declared `ndkVersion`
  instead. This was found and fixed via real-device
  verification on an Android emulator (arm64-v8a, API 34): the default runtime downloads, loads,
  and generates text from a real DistilGPT-2 ONNX export end-to-end on the plain (no-KV-cache,
  no-sampling) decode path (load time, token latency, and repeated-run stability were not
  separately profiled — that remains a follow-up, matching the Apple member's own #88 carve-out).
  The EP configuration, KV-cache decode path, and sampling added since have not themselves been
  re-verified against that or any other real device.
- `createFixtureOnnxRuntime(options)` — the deterministic in-memory fixture mandated above,
  public/importable like the Web and Apple members' fixtures.
- Any application-supplied implementation of `AndroidOnnxGenAiRuntime`.

**Model sources.** The Android member honors `bundled`, `programmatic`, `app_managed`, and
`filesystem`, and rejects `registry` and `remote` in `capabilities()`, matching the support matrix
above. `SystemAndroidOnnxGenAiRuntime` resolves `bundled` by copying the referenced Android asset
directory (`context.assets`) into app-private storage, into a directory keyed by the session cache
key (not by `id` alone) so a changed `version`/`ref`/checksum extracts into a fresh directory
instead of reusing stale bytes; extraction is atomic (copied into a temp directory, marked complete,
then moved into place) so an interrupted copy cannot poison a later load. `filesystem` and
`app_managed` resolve to a directory path from `source.ref` (absolute for `filesystem`, relative to
`context.filesDir` for `app_managed`).

**Capability gate order.** Identical to the Apple member: model package structural validation (a
hand-written `getModelPackageValidationIssues` in `inderun-onnx-providers` — no generated JSON
Schema validator exists in Kotlin, so this is a scoped subset covering `id` presence, inline-secret
keys, and `source.ref` URL-userinfo, not a full AJV-equivalent port) → Android source-type support →
`runtime.platforms` includes `android` → declared tasks include `text_to_text` → delegate to
`runtime.prepare`. Every failure flattens to one `capability_unavailable` route rejection, for
example:

- `capability_unavailable`: _model source unavailable: 'registry' model sources are deferred on
  Android; supply model files as bundled, programmatic, app_managed, filesystem._
- `capability_unavailable`: _model files missing: 'model.onnx' not found at \<resolved path\>._
- `CapabilityMismatch` at run time when the same gate fails pre-attempt; `Timeout` when the
  generation budget (`constraints.timeoutMs`, else the provider's configured timeout) elapses via a
  `withTimeout` race around `runtime.generate`; `Unavailable` for ONNX Runtime session
  initialization failures. There is no `AuthError`, `RateLimited`, or `Offline` path. Real coroutine
  cancellation (the caller cancelling its own job, as opposed to the provider's own deadline
  elapsing) propagates as a raw `CancellationException` rather than an `IndeRunException`, matching
  the Apple member's `CancellationError` convention rather than the Web member's `AbortError →
Timeout` mapping. `OrtSession.run()` itself is a blocking synchronous call that cannot be
  interrupted mid-call; cancellation is observed only between decode steps (`cancel: soft`).

**Packaging and binary size.** ORT Mobile's Android AAR bundles native `.so` libraries per ABI and
adds meaningfully to app binary size; the model files themselves must also fit on-device disk and
load into device memory (see [Platform Constraints](#platform-constraints-reference)). Neither
IndeRun nor this provider owns model download/update flows in Milestone 2 — apps that fetch models
remotely still supply them as `bundled`/`app_managed`/`programmatic` once resolved, per the model
source matrix.

**Authoring a custom local provider.** Implement `AndroidOnnxGenAiRuntime` rather than a new
`ProviderAdapter` when the model is ONNX: `AndroidOnnxRuntimeProvider` already owns descriptor
semantics, model package validation, source gating, timeouts, and error normalization. Implement
`ProviderAdapter` directly only for a different runtime family, mirroring the Web and Apple guidance
above.

## Documentation Requirements For Platform Tickets (#85–#87)

Each platform implementation must update, in the same task:

- the provider matrix / family overview (`providers.md` and this document as needed)
- the supported model source types for that platform (this document's matrix)
- model package requirements it relies on (reference the `ModelPackage` schema; do not duplicate)
- platform-specific constraints (browser/runtime for Web; packaging, binary size, accelerators for
  mobile — see platform notes below)
- route rejection / error examples for that platform
- provider-authoring notes for custom local model providers

## Platform Constraints (Reference)

External technical claims below are drawn only from the official ONNX Runtime documentation.

- **Web** — ORT Web runs inference in the browser. WebAssembly (WASM) is the CPU baseline and
  supports all ONNX operators; WebGL, WebGPU, and WebNN are GPU/accelerator backends that support
  only a subset of operators, so backend availability and operator coverage vary by environment.
  Deployment must serve the ORT WASM artifacts and load/cache model files.
  Sources: <https://onnxruntime.ai/docs/tutorials/web/>,
  <https://onnxruntime.ai/docs/tutorials/web/ep-webgpu.html>.
- **Mobile (Android/Apple)** — ORT Mobile supports iOS and Android. CPU is the default on all
  targets; Android adds NNAPI and XNNPACK, Apple adds CoreML and XNNPACK. The model must fit on the
  device disk and load into device memory; the ORT format and quantization reduce model and binary
  size. Source: <https://onnxruntime.ai/docs/tutorials/mobile/>.
- **GenAI** — the ORT `generate()` API handles the generative loop (tokenization, inference, logits
  processing, search/sampling, KV-cache) for models such as Phi-3 and DeepSeek-R1-Distill, and is
  documented as _"in preview and is subject to change"_. Source:
  <https://onnxruntime.ai/docs/genai/>.
