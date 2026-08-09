# Web System-Model Provider Family

This document specifies the Web system-model provider family for IndeRun: the browser-managed
on-device model analog to the Apple Foundation Models provider (iOS) and Android ML Kit
GenAI/Gemini Nano provider (Android). It is the architecture baseline for #78.

## Classification And Boundaries

A **system-model** provider wraps a model the *system* (here, the browser) owns end to end:
availability, download, storage, and execution. This is distinct from the
[ONNX Runtime provider family](onnx-runtime-provider-family.md), where the application supplies
the model. `ModelPackage` and the model-loading contract do not apply here — there is no
developer-supplied model to describe. Custom model runtimes such as ONNX Runtime or WebLLM are
never members of this family unless this architecture decision changes.

The app-facing IndeRun API stays provider-neutral: browser-specific Prompt API details (session
objects, `LanguageModel` options) never cross the adapter boundary.

## Provider Family Members

Web only, for now: `local.system-model.web`, backed by Chrome's built-in
[Prompt API](https://developer.chrome.com/docs/ai/prompt-api) (`LanguageModel`). Apple Foundation
Models and Android ML Kit GenAI are separate, already-implemented provider families — not members
of this one; they are the platform precedent this family follows for Web.

## Interaction Mode And Task

Mode 1 `run` only, task `text_to_text`. `supports.streaming` and `supports.realtime` stay `false`;
this document does not imply Mode 2/3 support. The runtime seam (`SystemModelRuntime`) exposes only
`availability()` and `generate()` — no session object or streaming method is exposed through it, so
streaming/session support cannot leak in even as unused scaffolding.

## Browser Support

Desktop Chrome 138+ only (Windows 10/11, macOS 13+, Linux, ChromeOS Chromebook Plus 16389.0.0+),
requiring roughly 22 GB free storage and either a GPU with >4 GB VRAM or a CPU with 16 GB RAM and
4+ cores. These figures come from Chrome's own documentation and may drift; consult
<https://developer.chrome.com/docs/ai/prompt-api> rather than treating them as fixed. Edge exposes
an analogous API per public announcements, but this family has not verified whether Edge's global
shares the exact `LanguageModel` surface — do not claim Edge support until confirmed. Firefox and
Safari are unsupported. Everywhere unsupported, the provider degrades to an honest
`capability_unavailable` rejection rather than throwing.

## Capability State Vocabulary

Chrome's `LanguageModel.availability()` returns exactly four strings: `available`, `downloadable`,
`downloading`, `unavailable`. The provider surfaces a richer, provider-internal vocabulary by also
inspecting `DOMException.name` on `create()`/`prompt()` failure, since Chrome collapses several
distinct causes (missing hardware, disabled flag, storage exhaustion) into exception names rather
than structured availability states. This mapping is best-effort: Chrome does not expose all
states reliably, so `unavailable` is deliberately the least specific fallback.

| Internal kind           | Source                                              |
| ------------------------ | --------------------------------------------------- |
| `available`               | `availability()` → `"available"`                    |
| `downloadable`             | `availability()` → `"downloadable"`                  |
| `downloading`              | `availability()` → `"downloading"`                    |
| `model_unavailable`        | `availability()` → `"unavailable"`                     |
| `api_missing`               | `LanguageModel` global not defined                       |
| `browser_unsupported`        | `DOMException.name === "NotSupportedError"`               |
| `feature_disabled`            | `DOMException.name === "NotAllowedError" \| "SecurityError"` |
| `hardware_unsupported`          | `NotSupportedError` from `create()` (session creation)       |
| `resource_constrained`            | `DOMException.name === "QuotaExceededError"`                   |
| `unavailable`                       | any other thrown error (transient/unclassified)                 |

This vocabulary is provider-internal, not a public enum. It flattens into the shared route
planner's fixed rejection vocabulary as `capability_unavailable`, carrying the specific reason as
human-readable text — no new route-rejection codes are added.

## Provider Error Mapping

| Runtime signal                                        | `errorClass`          |
| ------------------------------------------------------- | ---------------------- |
| Any non-`available` capability kind (checked pre-attempt) | `CapabilityMismatch`   |
| Hardware/browser-feature failure during `generate()`        | `CapabilityMismatch`   |
| Storage/network constraints, transient failure                | `Unavailable`           |
| Generation aborted or exceeded its timeout budget                | `Timeout`               |
| Missing prompt/messages, malformed/empty output, unexpected throwable | `Internal`         |

There is no `AuthError`/`RateLimited`/`Offline` path — purely local execution, same as the ONNX
family and the platform system-model providers.

## Cancellation

`cancel: soft`, matching every other on-device adapter (ONNX, Apple Foundation Models, Android ML
Kit). The Prompt API accepts an `AbortSignal` on `create()`/`prompt()`, but this family stays
conservative and consistent with its siblings rather than claiming `hard`.

## Runtime Seam

`SystemModelRuntime` has two methods: `availability()` returning `{ kind, reason? }`, and
`generate(input, signal)` returning normalized text. Two implementations exist:

- `createChromePromptApiRuntime()` — the default. Targets the `LanguageModel` global only (no
  legacy `self.ai.languageModel` fallback: that shape predates the current stable API and is not
  worth carrying as dead code). Passes identical generation options to `availability()` and
  `create()`, per Chrome's own guidance that availability can depend on the requested
  configuration. Creates an ephemeral session per `generate()` call and always calls
  `session.destroy()`, so no session object or conversational state is ever retained across calls
  or exposed to the app — this is what keeps the provider Mode-1-only in practice, not just by
  type signature.
- `createFixtureSystemModelRuntime()` — the deterministic in-memory fixture used by tests; it also
  lets demos exercise the on-device route without a Prompt API-capable browser.

Runtime failures are signalled with `SystemModelRuntimeError`, whose `kind` (`capability`,
`unavailable`, `timeout`, `internal`) selects the IndeRun error class per the mapping table above;
anything else a runtime throws normalizes to `Internal`.

## Capability Gate Order

`runtime.availability()` is the only gate — there is no model package to validate and no source
gating, unlike the ONNX family. `capabilities()` and `run()` both delegate to it and both must
observe the same result immediately before executing, to avoid acting on a stale route decision.

## Web Implementation

Ships in `@independo/inderun-web` under the `./system-model` subpath entry point, kept out of the
provider-agnostic root index like the OpenAI and ONNX adapters. Provider id:
`local.system-model.web`. Descriptor: `type: local`, `transport: system_service` (the browser owns
model execution in a separate process, unlike the in-page ONNX runtime), `supports.run: true` with
all forward-looking flags false, `cancel: soft`, `privacy.dataLeavesDevice: false`. Option shapes
and the error table for consumers live in the package README, not here.

**Authoring a custom local provider.** Implement `SystemModelRuntime` rather than a new
`ProviderAdapter` when targeting a browser-managed model: the provider already owns descriptor
semantics, timeouts, and error normalization. Implement `ProviderAdapter` directly only for a
different provider family (for example a developer-supplied model, which belongs in the ONNX
family or a new one).

## Documentation Requirements

Future changes to this provider's behavior must update, in the same task: this document, the
provider matrix in `providers.md`, and the option/error tables in the package README. This mirrors
the closing requirement in the ONNX Runtime provider family specification.
