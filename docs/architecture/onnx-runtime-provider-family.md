# ONNX Runtime Provider Family

This document specifies the ONNX Runtime (ORT) provider family for IndeRun and the
provider-neutral model-loading contract used for developer-supplied/custom local models. It is the
architecture baseline for the platform implementation tickets: #85 (Web), #87 (Android), and #86
(Apple platforms). Those tickets implement providers; they must not re-decide the boundaries below.

Field-level shapes live in the schema, not in this prose (see
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

**GenAI has no browser build.** ORT GenAI ships Python, .NET, C/C++, and Java packages only; there
is no JavaScript/browser distribution, and `onnxruntime-web` provides raw inference without a
generative loop (tokenization, sampling, KV cache). The Web member satisfies the _role_ GenAI was
mandated for — not the literal package — by defaulting to Transformers.js, which runs ONNX models on
`onnxruntime-web` and owns the generative loop. Source:
<https://onnxruntime.ai/docs/genai/howto/install.html>.

**The mobile members target raw ORT Mobile, not the ORT GenAI package.** Both shipped mobile members
(Apple, Android) default to the platform's raw ONNX Runtime Mobile bindings plus a hand-written
decode loop and an external tokenizer, rather than `onnxruntime-genai`/`onnxruntime-extensions`. This
keeps both defaults on the same well-established, non-preview API surface used by the Web member's
underlying runtime. Both mobile members auto-detect and reuse `past_key_values`/KV-cache export
shapes where the graph and `config.json` support it (falling back to full-sequence recompute
otherwise) and configure an accelerated execution provider (CoreML/XNNPACK on Apple, NNAPI/XNNPACK on
Android) with a CPU fallback, though none of it has been exercised against a real model on a real
device beyond the plain-path verification noted in each platform section (#88). This is exactly what
the injectable seam exists for regardless: the seam is the contract, and any application (or a future
IndeRun default) can supply an ORT-GenAI-backed `OnnxGenAiRuntime`/`AndroidOnnxGenAiRuntime`
implementation without changing the provider.

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

IndeRun does not own model download/update flows today. Host applications may bundle,
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
  download itself.
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

Ships in `@independo/inderun-web` under the `./onnx` subpath entry point. Provider id:
`local.onnx.genai.web`. Runtime seam: `OnnxTextGenerationRuntime` (`prepare`/`generate`), with a
default `createTransformersJsRuntime()` (lazy `@huggingface/transformers` import, not bundled by
IndeRun), a `createFixtureOnnxRuntime()` test/demo seam, and support for an application-supplied
implementation. Model sources: `registry`, `bundled`, `programmatic`, `app_managed` (see
[Model Source Support Matrix](#model-source-support-matrix) for the full per-platform picture).

Implementation detail (runtime seam internals, quantization defaults, capability gate order, error
mapping, browser/WASM constraints) lives in code comments in
[`packages/inderun-web/src/providers/onnx/`](../../packages/inderun-web/src/providers/onnx/) and in
[`packages/inderun-web/README.md`](../../packages/inderun-web/README.md) — this document does not
duplicate it, to avoid drifting out of sync with the implementation.

**Authoring a custom local provider:** implement `OnnxTextGenerationRuntime`, per
[Authoring A Custom Local ONNX Provider](#authoring-a-custom-local-onnx-provider) below.

## Apple Implementation

Ships as its own SwiftPM library product, `IndeRunOnnxProviders`
(`ios/IndeRun/Sources/IndeRunOnnxProviders`). Provider id: `local.onnx.genai.apple`. Runtime seam:
`OnnxGenAiRuntime` (`prepare`/`generate`), with a default `SystemOnnxGenAiRuntime()` (ONNX Runtime
SPM bindings + `swift-transformers` tokenizer), a `createFixtureOnnxRuntime(options:)` test/demo
seam, and support for an application-supplied implementation. Model sources: `bundled`,
`programmatic`, `app_managed`, `filesystem` (see
[Model Source Support Matrix](#model-source-support-matrix)).

Landing this member raised the whole SDK's minimum platforms to **iOS 16 / macOS 14** — a
package-wide, breaking bump for every IndeRun Apple consumer, not only ONNX users — because its
dependencies require it; see `Package.swift`.

Implementation detail (decode-strategy auto-detection between the plain and KV-cache IO shapes,
execution-provider fallback and the KV-cache/CoreML incompatibility, buffer reuse, sampling,
capability gate order, cancellation semantics) lives in code comments in
[`ios/IndeRun/Sources/IndeRunOnnxProviders/`](../../ios/IndeRun/Sources/IndeRunOnnxProviders/) —
this document does not duplicate it, to avoid drifting out of sync with the implementation. Real
device verification beyond the plain decode path is tracked in #88.

**Authoring a custom local provider:** implement `OnnxGenAiRuntime`, per
[Authoring A Custom Local ONNX Provider](#authoring-a-custom-local-onnx-provider) below.

## Android Implementation

Ships as its own Gradle library module, `inderun-onnx-providers` (`android/inderun-onnx-providers`).
Provider id: `local.onnx.genai.android`. Runtime seam: `AndroidOnnxGenAiRuntime`
(`prepare`/`generate`), with a default `SystemAndroidOnnxGenAiRuntime(context)` (ONNX Runtime Mobile
Java bindings + a Hugging Face tokenizer via `ai.djl`), a `createFixtureOnnxRuntime(options)`
test/demo seam, and support for an application-supplied implementation. Model sources: `bundled`,
`programmatic`, `app_managed`, `filesystem` (see
[Model Source Support Matrix](#model-source-support-matrix)).

Implementation detail (decode-strategy auto-detection, execution-provider fallback and the
KV-cache/NNAPI incompatibility, buffer reuse, sampling, the Android-specific
`libc++_shared.so`/`tokenizer-native` packaging fix, capability gate order, cancellation semantics)
lives in code comments in
[`android/inderun-onnx-providers/`](../../android/inderun-onnx-providers/) — this document does not
duplicate it, to avoid drifting out of sync with the implementation. One notable platform gap:
unlike Apple and Web, this default runtime does not apply chat templates (the DJL tokenizer binding
exposes no equivalent API), falling back unconditionally to a plain `"role: content"` join. Real
device verification beyond the plain-path DistilGPT-2 check is tracked in #88.

**Authoring a custom local provider:** implement `AndroidOnnxGenAiRuntime`, per
[Authoring A Custom Local ONNX Provider](#authoring-a-custom-local-onnx-provider) below.

## Authoring A Custom Local ONNX Provider

For a new ONNX-backed model, implement the runtime seam for the target platform
(`OnnxTextGenerationRuntime` on Web, `OnnxGenAiRuntime` on Apple, `AndroidOnnxGenAiRuntime` on
Android) rather than a new `ProviderAdapter`: the existing platform provider already owns descriptor
semantics, model package validation, source gating, timeouts, and error normalization. Implement
`ProviderAdapter` directly only for a different runtime family.

## Documentation Requirements For Future Platform Work

A change to this provider family (new platform member, new model source type, new capability
condition) must update, in the same task:

- the provider matrix / family overview (`providers.md` and this document as needed)
- the supported model source types for that platform (this document's matrix)
- model package requirements it relies on (reference the `ModelPackage` schema; do not duplicate)
- the relevant platform's code comments (implementation detail belongs there, not here — see
  CONTEXT.md §8 "Where technical detail belongs")

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
