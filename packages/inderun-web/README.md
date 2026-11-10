<p align="center">
  <a href="https://inderun.dev">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://inderun.dev/brand/inderun-logo-dark.svg">
      <img alt="IndeRun" src="https://inderun.dev/brand/inderun-logo-light.svg" width="360">
    </picture>
  </a>
</p>

<p align="center">
  <a href="https://www.npmjs.com/package/@independo/inderun-web"><img alt="npm: @independo/inderun-web" src="https://img.shields.io/npm/v/@independo/inderun-web?logo=npm"></a>
  <a href="https://github.com/independo-gmbh/inderun/actions/workflows/javascript.yml"><img alt="JavaScript" src="https://github.com/independo-gmbh/inderun/actions/workflows/javascript.yml/badge.svg?branch=dev"></a>
  <a href="https://github.com/independo-gmbh/inderun/blob/main/LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue"></a>
  <a href="https://inderun.dev/docs"><img alt="Docs: inderun.dev" src="https://img.shields.io/badge/docs-inderun.dev-A0B3FF"></a>
</p>

# @independo/inderun-web

> Part of **[IndeRun](https://github.com/independo-gmbh/inderun)** — on-device AI for the devices
> your users actually have. A cloud route is used only if you configure one and the request permits it.
> New here? Start with the [documentation](https://inderun.dev/docs).

TypeScript/Web SDK for IndeRun.

This package provides the Web SDK entrypoint, the engine core, routing, telemetry, error normalization, the OpenAI-compatible cloud provider, the Web ONNX Runtime provider for developer-supplied local models, and the Web system-model provider for browser-managed on-device models.

The contract types this SDK's own signatures take and return — `TaskRequest`, `TaskResult`, `StreamEvent`, `StreamRunHandle`, `StreamTerminalOutcome`, `IndeRunError`, `ExecutionProvenance`, the telemetry interfaces, the host-service interfaces (from `/provider`), and (from the `/onnx` subpath) `ModelPackage` — are re-exported here, so a fully typed app does not need to depend on `@independo/inderun-contracts` separately. Import that package directly only if you want the JSON Schemas or the `get*ValidationIssues` validators.

## Entry points

| Import                                                                                        | For                                   | Contains                                                                                                                                                                                                                                     |
| --------------------------------------------------------------------------------------------- | ------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `@independo/inderun-web`                                                                      | Applications                          | `generateText` / `streamText`, `speak` / `generateSpeech` / `listVoices`, `createIndeRunWeb`, the advanced task API (`IndeRun`, `run()` / `stream()` / `checkCapabilities()`), model profiles, contract types, `IndeRunException`, telemetry |
| `@independo/inderun-web/provider`                                                             | Provider authors and host integrators | `ProviderAdapter` and the descriptor/capability types, `ProviderRegistry`, `HostServices` and the browser host services, the `create*` error constructors                                                                                    |
| `@independo/inderun-web/openai`, `/onnx`, `/system-model`, `/system-speech`, `/neural-speech` | Registering a provider by hand        | One provider adapter each                                                                                                                                                                                                                    |

The router, the route planner bindings and the Event Gate are engine internals and are not exported. Moving from 0.3?
See the [migration guide](https://github.com/independo-gmbh/inderun/blob/main/docs/migration.md).

## Basic Usage

On-device only, in a browser with a managed model (desktop Chrome with the Prompt API). Where there is none, the
call is refused before anything executes:

<!-- snippet:web-local-only -->
```ts
import { createIndeRunWeb, generateText } from "@independo/inderun-web";

// Registers the browser-managed model (Chrome's Prompt API). In a browser
// without it there is no eligible local provider, so the call is refused.
const inderun = createIndeRunWeb({ systemModel: {} });

const { text, provenance } = await generateText(inderun, {
  prompt: "Rewrite in plain language: Your appointment has been rescheduled.",
  execution: { privacy: "local_required" }
});

console.log(text, provenance?.providerId);
```
<!-- /snippet -->

### Optional cloud route

Register an OpenAI-compatible endpoint (through a same-origin proxy that holds the key) and a request can use it when
its privacy constraint permits:

```ts
import { createIndeRunWeb, generateText, streamText } from "@independo/inderun-web";

const inderun = createIndeRunWeb({
  openAI: {
    models: ["gpt-5.2"],
    endpointUrl: "/api/inderun/openai-responses",
    auth: "none"
  }
});

const { text, provenance } = await generateText(inderun, {
  prompt: "Write a one-sentence summary of IndeRun.",
  execution: { privacy: "local_preferred" }
});

const stream = await streamText(inderun, {
  system: "Use plain language.",
  prompt: "Explain routing."
});
for await (const delta of stream.textStream) process.stdout.write(delta);
const { finishReason } = await stream.result;
```

`generateText` and `streamText` take `prompt` or `messages`, an optional `system`, `model` (a
[model profile](https://github.com/independo-gmbh/inderun/blob/main/docs/architecture/api-layering.md#model-profiles),
default `"auto"`), the usual sampling options, and an `execution` policy that reuses the canonical
constraint values. Each call compiles to one `TaskRequest` — `toTaskRequest(options)` shows which —
and runs through the engine below, so errors, routing, and cancellation match the advanced API.

## Speech

```ts
import { createIndeRunWeb, listVoices, speak } from "@independo/inderun-web";

const inderun = createIndeRunWeb({ systemSpeech: {} });
const voices = await listVoices(inderun, { locale: "de-AT" });

const playback = await speak(inderun, {
  text: "Der Bus kommt.",
  locale: "de-AT",
  voice: voices[0]
});
stopButton.onclick = () => playback.cancel();
const { finishReason, provenance } = await playback.result; // "cancelled" after cancel()
```

`prepare(inderun)` is optional and makes the first call fast; see ADR 019. A provider's download starts only under
`autoDownload` at registration, for example `createIndeRunWeb({ systemSpeech: { autoDownload: true } })`, or
`prepare(inderun, { allowDownload: true })`.

`speak` compiles to `stream()` with playback delivery, so stopping is a normal ending, not an error.
`generateSpeech` compiles to `run()` with artifact delivery and returns an `artifact` to read with
`readArtifact()` and release with `disposeArtifact()`; routing refuses it on a provider that can
only play. `toSpeechRequest` shows the canonical request. See
[ADR 018](https://github.com/independo-gmbh/inderun/blob/main/docs/architecture/decisions/018-speech-application-api.md).

`systemSpeech` registers `web_system_speech`, over the browser's `speechSynthesis`. It only plays:
the browser offers no standard way to retrieve the audio, so `generateSpeech` needs another provider.
`local_required` is always refused, because a browser gives no reliable evidence that speech stays on
the device, and provenance reports locality `unknown`. Chrome also needs a user gesture before it will
speak, so call `speak` from a click handler. Details are in the
[system speech family doc](https://github.com/independo-gmbh/inderun/blob/main/docs/architecture/system-speech-provider-family.md).

## Model profiles

Models are bound where providers are configured, not at call sites. Every provider instance is a _target_ bound to one
model — `createIndeRunWeb({ openAI: { models: ["gpt-5.2", "gpt-5-mini"] } })` registers the targets
`openai:gpt-5.2` and `openai:gpt-5-mini` — and a _model profile_ names an ordered set of targets:

```ts
const inderun = createIndeRunWeb({
  openAI: { models: ["gpt-5.2", "gpt-5-mini"], endpointUrl: "/api/inderun/openai-responses", auth: "none" },
  systemModel: {},
  modelProfiles: {
    fast: ["local.system-model.web", "openai:gpt-5-mini"],
    smart: ["openai:gpt-5.2"]
  }
});

await inderun.run({ schemaVersion: "1.0", task: { kind: "text_to_text" }, prompt, modelProfile: "smart" });
```

A request that names no profile routes within the built-in `auto` profile: every registered target. A named profile is
an allow-list — targets outside it are rejected with `not_in_model_profile` — and its order ranks targets _within_ a
placement tier, so `local_required` and `local_preferred` keep their meaning. An unknown profile name fails validation.
See [API layering](https://github.com/independo-gmbh/inderun/blob/main/docs/architecture/api-layering.md#model-profiles).

## Advanced: the task API

Use `TaskRequest` with `run()` / `stream()` when you need the raw event sequence, build requests in code (for example
with your own `requestId`), or check capabilities before offering an option —
`await inderun.checkCapabilities()` reports every registered target's live availability. Both layers run through the
same engine.

## Streaming

For the full event sequence, use the advanced API. `stream()` returns the run handle, its canonical `StreamEvent` sequence, and a `cancel()` hook:

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

Streaming over the network needs a host that can deliver a response body incrementally.
`createBrowserHostServices` provides one; a custom host without a `streamingHttpClient` still runs
Mode 1, and a stream request is refused at routing time with a `streaming_unavailable` reason rather
than failing later.
`createBrowserHostServices` also provides a Web Audio `audioOutput` for providers that synthesize PCM themselves;
browsers need a user gesture before the first `open()`, and a page that has none gets `audio_not_allowed`.

Event types, ordering, the terminal guarantees, and cancellation are identical on every
SDK and documented once, in
[Streaming (Mode 2)](https://github.com/independo-gmbh/inderun/blob/main/docs/streaming.md).

### Custom OpenAI-compatible endpoints

The adapter speaks the OpenAI **Responses** API, not chat completions. A custom endpoint must
accept `"stream": true` and emit `text/event-stream` with the Responses event types —
`response.output_text.delta`, and `response.completed` / `response.incomplete` carrying the
response object. Unknown event types are ignored, so an endpoint that emits extra events is
fine; one that emits a different vocabulary entirely is not.

[OpenRouter](https://github.com/independo-gmbh/inderun/blob/main/docs/openrouter.md) is reached this way: point
`endpointUrl` at its Responses endpoint (through a proxy in browser apps) and list `vendor/model` ids as `models`.

## Security Model

Browser apps should use a proxy endpoint and keep provider credentials server-side. `createIndeRunWeb` rejects direct calls to the public OpenAI Responses endpoint unless `allowDirectOpenAIEndpoint: true` is set for a controlled environment.

This applies to streaming too, and is the reason `@independo/inderun-demo-proxy` relays event
streams rather than buffering them: a browser cannot open its own authenticated connection to
OpenAI without shipping the key in client code. Never embed a developer-owned API key in
distributed client code — put it behind a trusted backend proxy and point `endpointUrl` at that.

## Advanced: registering the OpenAI provider directly

`createIndeRunWeb` wires the OpenAI Responses provider for you. To register it
manually (e.g. alongside other providers), import it from the provider subpath and build the engine from
the `/provider` entry point:

```ts
import { IndeRun } from "@independo/inderun-web";
import { OpenAIResponsesProvider } from "@independo/inderun-web/openai";
import { ProviderRegistry, createBrowserHostServices } from "@independo/inderun-web/provider";

const registry = new ProviderRegistry();
registry.register(
  new OpenAIResponsesProvider({
    model: "gpt-5.2",
    endpointUrl: "/api/inderun/openai-responses",
    auth: "none"
  })
);
const inderun = new IndeRun(registry, createBrowserHostServices());
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

**Selecting a runtime from configuration.** `runtime` also takes a JSON-serializable descriptor, for
configuration that cannot carry a function (a bridge marshals `configure(options)` as JSON). The
provider builds the runtime and closes it with itself. `{ kind: "transformers_js" }` (optionally
with `device`, `dtype`, `localModelPath`, `pipelineOptions`) needs the optional peer
`@huggingface/transformers`; `{ kind: "fixture" }` needs no extra dependency. An unknown `kind`
throws a `TypeError` at construction. Passing a runtime object keeps working and stays yours to close.

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

| `source.sourceType` | Web                                                      |
| ------------------- | -------------------------------------------------------- |
| `registry`          | Supported (hub model id in `source.ref`)                 |
| `bundled`           | Supported (assets served by your app)                    |
| `app_managed`       | Supported (assets served by your app)                    |
| `programmatic`      | Supported (requires `createGenerator`)                   |
| `remote`            | Deferred — download yourself, then declare the files     |
| `filesystem`        | Unsupported — browsers cannot read arbitrary local paths |

### Errors

| Condition                                                     | `errorClass`         |
| ------------------------------------------------------------- | -------------------- |
| Capability gate fails pre-attempt, model missing/incompatible | `CapabilityMismatch` |
| Runtime initialization failure, resource exhaustion           | `Unavailable`        |
| Generation exceeded its timeout budget                        | `Timeout`            |
| Malformed/empty model output, unexpected runtime failure      | `Internal`           |

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

**Selecting a runtime from configuration.** `runtime` also takes a JSON-serializable descriptor:
`{ kind: "chrome_prompt_api" }` (optionally with `generation`) or `{ kind: "fixture" }`. Neither
needs an extra dependency. An unknown `kind` throws a `TypeError` at construction.

### Browser support

Desktop Chrome 138+ only (Windows 10/11, macOS 13+, Linux, ChromeOS), and requires roughly 22 GB
free storage plus either a >4 GB VRAM GPU or a 16 GB RAM / 4+ core CPU. These figures come from
Chrome and may change — see the [Prompt API docs](https://developer.chrome.com/docs/ai/prompt-api)
for the current requirements. Edge exposes an analogous API, but this package has not yet verified
whether it shares the exact `LanguageModel` global shape. Everywhere else, the provider reports
itself unavailable (`api_missing`) rather than throwing.

### Errors

| Condition                                                   | `errorClass`         |
| ----------------------------------------------------------- | -------------------- |
| Capability gate fails pre-attempt (any non-available state) | `CapabilityMismatch` |
| Hardware/browser-feature failure surfaced during generation | `CapabilityMismatch` |
| Storage/network constraints, transient failure              | `Unavailable`        |
| Generation aborted or exceeded its timeout budget           | `Timeout`            |
| Malformed/empty model output, unexpected runtime failure    | `Internal`           |

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

## On-Device Models: Neural speech

`local.onnx.speech.web` speaks with a developer-supplied neural speech model package, in the browser,
through the host's audio output or as an `audio/wav` artifact. Pass `neuralSpeech` to the factory, one
entry per model:

```ts
import { createIndeRunWeb } from "@independo/inderun-web";

const inderun = createIndeRunWeb({
  neuralSpeech: [{ modelPackage, runtime }]
});
```

The provider id is `local.onnx.speech.web:<modelPackage.id>` unless you pass `id`, so register one
entry per model. `runtime` is required: the provider does no inference itself. It is either a runtime
object or a JSON-serializable descriptor (see
[Selecting a runtime from configuration](#selecting-a-runtime-from-configuration-neural-speech)).
For a real model use
the ONNX Runtime runtime, which picks the pipeline from `modelPackage.speech.pipeline` (`articulino`
today) and runs its graphs on the `onnxruntime-web` wasm backend:

```ts
import { createOnnxNeuralSpeechRuntime } from "@independo/inderun-web/neural-speech";

const runtime = createOnnxNeuralSpeechRuntime();
```

`onnxruntime-web` is an optional peer dependency IndeRun does not bundle; install it yourself
(`pnpm add onnxruntime-web`). Without it the runtime reports itself unavailable. Package files are
fetched from `modelPackage.source.ref` (relative to the page) for `bundled` and `app_managed`
packages, laid out as `prepare_articulino_package.py` writes them (`model-package.json`,
`config.json`, the three graphs, `voices/<id>.safetensors`); pass `files` (a `SpeechPackageFiles`)
to read them from anywhere else. WASM threads need cross-origin isolation (see
[Runtime dependency](#runtime-dependency)); without it the backend runs single-threaded. Digits are
not read until the German frontend lands; write numbers as words. For demos and tests without a
model, use the fixture runtime:

```ts
import { createFixtureNeuralSpeechRuntime } from "@independo/inderun-web/neural-speech";

const runtime = createFixtureNeuralSpeechRuntime();
```

It synthesizes a deterministic tone, so a demo exercises routing, playback and cancellation without a
model. Playback goes through the browser audio output, which needs a user gesture before the first
sound, as in Chrome; artifact delivery does not. Artifacts are capped at 16 MiB. The seam types, the
sentence splitter and the WAV encoder are exported from `@independo/inderun-web/neural-speech`. See
[the family doc](https://github.com/independo-gmbh/inderun/blob/main/docs/architecture/neural-speech-provider-family.md)
in the monorepo.

### Selecting a runtime from configuration (neural speech)

For configuration that cannot carry a function, `runtime` takes a descriptor and the provider builds
the runtime, closing it with itself (an injected runtime stays yours to close). `{ kind: "fixture" }`
needs no extra dependency. `{ kind: "onnx" }` (optionally with `threads`, `speed`, `pauseMs`) needs
the optional peer `onnxruntime-web`, and reads package files from `modelPackage.source.ref`, so it
serves `bundled` and `app_managed` packages only; an OPFS-installed package still needs the function
form with `files`. An unknown `kind` throws a `TypeError` at construction.

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
