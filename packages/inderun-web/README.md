# @independo/inderun-web

[![npm](https://img.shields.io/npm/v/@independo/inderun-web?logo=npm)](https://www.npmjs.com/package/@independo/inderun-web)

> Part of **[IndeRun](https://github.com/independo-gmbh/inderun)** — an open-source AI execution
> framework that gives applications one unified API for running tasks across on-device, edge, and
> cloud providers. New here? Start with the [IndeRun README](https://github.com/independo-gmbh/inderun#readme).

TypeScript/Web SDK for IndeRun.

This package provides the Web SDK entrypoint, the engine core, routing, telemetry, error normalization, the OpenAI-compatible cloud provider, the Web ONNX Runtime provider for developer-supplied local models, and the Web system-model provider for browser-managed on-device models.

## Basic Usage

```ts
import { createIndeRunWeb } from "@independo/inderun-web";

const inderun = createIndeRunWeb({
  openAI: {
    model: "gpt-5.2",
    endpointUrl: "/api/inderun/openai-responses",
    auth: "none"
  }
});

const result = await inderun.run({
  schemaVersion: "1.0",
  task: { kind: "text_to_text" },
  prompt: "Write a one-sentence summary of IndeRun."
});
```

## Streaming

`stream()` returns the run handle, its canonical `StreamEvent` sequence, and a `cancel()` hook:

```ts
const { handle, events, cancel } = await inderun.stream({
  schemaVersion: "1.0",
  task: { kind: "text_to_text" },
  prompt: "Write a one-sentence summary of IndeRun."
});

for await (const event of events) {
  if (event.type === "content_delta") process.stdout.write(event.payload.text);
  if (event.type === "terminal") console.log(event.payload.outcome);
}
```

Order by `event.sequence`, not by arrival: it is the ordering authority for a run. Treat an
unrecognized `event.type` as ignore-or-pass-through — the set is open and additive. Exactly one
`terminal` event is produced per run, and `cancel()` is idempotent.

Streaming needs a host that can deliver a response body incrementally.
`createBrowserHostServices` provides one; a custom host without a
`streamingHttpClient` still runs Mode 1, and a stream request is refused at routing
time with a `streaming_unavailable` reason rather than failing later.

### Custom OpenAI-compatible endpoints

The adapter speaks the OpenAI **Responses** API, not chat completions. A custom endpoint must
accept `"stream": true` and emit `text/event-stream` with the Responses event types —
`response.output_text.delta`, and `response.completed` / `response.incomplete` carrying the
response object. Unknown event types are ignored, so an endpoint that emits extra events is
fine; one that emits a different vocabulary entirely is not.

## Security Model

Browser apps should use a proxy endpoint and keep provider credentials server-side. `createIndeRunWeb` rejects direct calls to the public OpenAI Responses endpoint unless `allowDirectOpenAIEndpoint: true` is set for a controlled environment.

This applies to streaming too, and is the reason `@independo/inderun-demo-proxy` relays event
streams rather than buffering them: a browser cannot open its own authenticated connection to
OpenAI without shipping the key in client code. Never embed a developer-owned API key in
distributed client code — put it behind a trusted backend proxy and point `endpointUrl` at that.

## Advanced: registering the OpenAI provider directly

`createIndeRunWeb` wires the OpenAI Responses provider for you. To register it
manually (e.g. alongside other providers), import it from the provider subpath:

```ts
import { OpenAIResponsesProvider } from "@independo/inderun-web/openai";
```

The provider normalizes OpenAI transport and API failures into the IndeRun error
taxonomy (`AuthError`, `RateLimited`, `Timeout`, `Unavailable`, `Internal`). The
exact status-to-class mapping is documented on the provider in code — see
`OpenAIResponsesProvider` — so it stays in sync with behavior.

## On-Device Models: ONNX Runtime (Web)

`local.onnx.genai.web` runs developer-supplied ONNX models in the browser. Registering it is what
makes `constraints.privacy = "local_required"` routable. Pass `onnx` to the factory (`openAI` and
`onnx` are both optional, but at least one is required):

```ts
import { createIndeRunWeb } from "@independo/inderun-web";

const inderun = createIndeRunWeb({
  onnx: {
    modelPackage: {
      id: "phi-3-mini-web",
      format: "onnx",
      tasks: ["text_to_text"],
      runtime: { platforms: ["web"] },
      source: { sourceType: "registry", ref: "onnx-community/Phi-3-mini-4k-instruct" }
    }
  }
});
```

`modelPackage` is the provider-neutral `ModelPackage` contract from
`@independo/inderun-contracts`; only `id` and `format` are required, and the package is validated
(including the inline-secret and URL-userinfo rules) before every attempt. Model files must never
carry credentials — use `authContextRef` and secure storage instead.

Options: `id` (defaults to `local.onnx.genai.web`), `modelPackage` (required), `runtime`, and
`timeoutMs` (a request's `constraints.timeoutMs` wins).

The default runtime loads **quantized** weights (`q4f16` on WebGPU, `q4` otherwise). Transformers.js
would otherwise pick `fp32`, which makes ONNX Runtime fail session creation with an allocation error
(`std::bad_alloc`) for anything but tiny models. Override with `dtype` when your model does not
publish that variant:

```ts
import { OnnxRuntimeWebProvider, createTransformersJsRuntime } from "@independo/inderun-web/onnx";

const provider = new OnnxRuntimeWebProvider({
  modelPackage,
  runtime: createTransformersJsRuntime({ dtype: "q8", device: "wasm" })
});
```

The default runtime targets models that load through the Transformers.js `text-generation` pipeline
— for example `onnx-community/gemma-3-1b-it-ONNX`. Multimodal exports split across separate
encoder/decoder graphs need `AutoProcessor` plus a model-specific class and should implement the
runtime seam instead — see [Custom runtimes](#custom-runtimes).

### Runtime dependency

The default runtime uses [Transformers.js](https://www.npmjs.com/package/@huggingface/transformers),
which runs ONNX models on `onnxruntime-web` and owns the generation loop (ONNX Runtime GenAI has no
browser build). It is an optional dependency that IndeRun does not bundle — install it yourself:

```sh
pnpm add @huggingface/transformers
```

If the package is present but fails to initialize, the provider reports itself unavailable and
routing produces an explainable `capability_unavailable` rejection instead of throwing. Bundlers do
need to resolve the specifier, so an app that imports `@independo/inderun-web/onnx` without
installing Transformers.js should pass its own runtime (or a `load` override) — see
[Custom runtimes](#custom-runtimes). WASM threads additionally require
cross-origin isolation (`Cross-Origin-Opener-Policy: same-origin`,
`Cross-Origin-Embedder-Policy: require-corp`) on whatever serves your app.

### Supported model sources

| `source.sourceType` | Web         |
| ------------------- | ----------- |
| `registry`          | Supported (hub model id in `source.ref`) |
| `bundled`           | Supported (assets served by your app) |
| `app_managed`       | Supported (assets served by your app) |
| `programmatic`      | Supported (requires `createGenerator`) |
| `remote`            | Deferred — download yourself, then declare the files |
| `filesystem`        | Unsupported — browsers cannot read arbitrary local paths |

### Errors

| Condition                                                   | `errorClass`         |
| ----------------------------------------------------------- | -------------------- |
| Capability gate fails pre-attempt, model missing/incompatible | `CapabilityMismatch` |
| Runtime initialization failure, resource exhaustion          | `Unavailable`        |
| Generation exceeded its timeout budget                       | `Timeout`            |
| Malformed/empty model output, unexpected runtime failure     | `Internal`           |

A purely local runtime never produces `AuthError`, `RateLimited`, or `Offline`.

### Custom runtimes

Swap the execution backend without touching provider semantics by implementing
`OnnxTextGenerationRuntime`:

```ts
import {
  OnnxRuntimeWebProvider,
  OnnxRuntimeError,
  createFixtureOnnxRuntime,
  type OnnxTextGenerationRuntime
} from "@independo/inderun-web/onnx";

const runtime: OnnxTextGenerationRuntime = {
  async prepare(modelPackage) {
    return { available: true };
  },
  async generate({ messages, generation }, signal) {
    // Throw OnnxRuntimeError("capability" | "unavailable" | "timeout" | "internal", …)
    // to steer IndeRun error normalization.
    return { text: "…" };
  }
};
```

`createFixtureOnnxRuntime()` provides a deterministic in-memory runtime for tests and offline demos.

## On-Device Models: Web System-Model Provider

`local.system-model.web` runs a browser-managed on-device model — currently
[Chrome's Prompt API](https://developer.chrome.com/docs/ai/prompt-api) (`LanguageModel`, Gemini
Nano). Unlike the ONNX provider above, this provider takes no `modelPackage`: the browser owns
model availability, download, and execution. Registering it also makes
`constraints.privacy = "local_required"` routable. Pass `systemModel` to the factory:

```ts
import { createIndeRunWeb } from "@independo/inderun-web";

const inderun = createIndeRunWeb({
  systemModel: {}
});
```

Options: `id` (defaults to `local.system-model.web`), `runtime` (defaults to
`createChromePromptApiRuntime()`), and `timeoutMs` (a request's `constraints.timeoutMs` wins).

### Browser support

Desktop Chrome 138+ only (Windows 10/11, macOS 13+, Linux, ChromeOS), and requires roughly 22 GB
free storage plus either a >4 GB VRAM GPU or a 16 GB RAM / 4+ core CPU. These figures come from
Chrome and may change — see the [Prompt API docs](https://developer.chrome.com/docs/ai/prompt-api)
for the current requirements. Edge exposes an analogous API, but this package has not yet verified
whether it shares the exact `LanguageModel` global shape. Everywhere else, the provider reports
itself unavailable (`api_missing`) rather than throwing.

### Errors

| Condition                                                   | `errorClass`         |
| ------------------------------------------------------------- | --------------------- |
| Capability gate fails pre-attempt (any non-available state)   | `CapabilityMismatch`  |
| Hardware/browser-feature failure surfaced during generation   | `CapabilityMismatch`  |
| Storage/network constraints, transient failure                | `Unavailable`         |
| Generation aborted or exceeded its timeout budget              | `Timeout`             |
| Malformed/empty model output, unexpected runtime failure       | `Internal`            |

A purely local runtime never produces `AuthError`, `RateLimited`, or `Offline`. See
[`docs/architecture/web-system-model-provider-family.md`](https://github.com/independo-gmbh/inderun/blob/main/docs/architecture/web-system-model-provider-family.md)
in the monorepo for the full capability-state vocabulary.

### Custom runtimes

Swap the execution backend without touching provider semantics by implementing
`SystemModelRuntime`:

```ts
import {
  SystemModelWebProvider,
  SystemModelRuntimeError,
  createFixtureSystemModelRuntime,
  type SystemModelRuntime
} from "@independo/inderun-web/system-model";

const runtime: SystemModelRuntime = {
  async availability() {
    return { kind: "available" };
  },
  async generate({ messages, generation }, signal) {
    // Throw SystemModelRuntimeError("capability" | "unavailable" | "timeout" | "internal", …)
    // to steer IndeRun error normalization.
    return { text: "…" };
  }
};
```

`createFixtureSystemModelRuntime()` provides a deterministic in-memory runtime for tests and
offline demos.

## Commands

```sh
pnpm --filter @independo/inderun-web build
pnpm --filter @independo/inderun-web test
```

## About IndeRun

This package is developed and published from the
[independo-gmbh/inderun](https://github.com/independo-gmbh/inderun) monorepo. For the
architecture overview, provider model, and getting-started guides, see the
[IndeRun documentation](https://github.com/independo-gmbh/inderun#readme). Built by
[Independo GmbH](https://www.independo.app) · Licensed MIT.
