# Providers

This document explains the **Provider** concept in IndeRun and lists the provider types we currently plan for / discussed, including how they map to underlying **runtimes** and **model artifacts**.

> **TL;DR**: A **Provider** is an *execution backend* selected by the IndeRun Router. A Provider wraps a specific runtime (system framework, inference engine, or cloud API) and exposes a stable IndeRun adapter contract (run/stream/session, capabilities, cancellation, errors, telemetry).

---

## 1) Vocabulary

### Provider (IndeRun)
A **Provider** is a pluggable execution backend. It must implement the IndeRun adapter contract:

- `describe()` → static capability descriptor (tasks, transport, cancel semantics, limits, privacy)
- `capabilities(host)` → dynamic capability snapshot (availability *now*)
- `run()` (Mode 1)
- `stream()` (Mode 2, optional per provider)
- `openSession()` (Mode 3, optional per provider)
- `cancel()` / `interrupt()` (best-effort, with standardized IndeRun guarantees)

Providers are what the **Router** chooses at runtime.

For Mode 1 route planning, providers do not participate directly in cross-platform selection logic. Each platform
adapter supplies its `describe()` output plus a dynamic `capabilities(host)` snapshot to the shared Rust planner, which
returns a deterministic route plan containing selected provider ID, fallback order, and rejection reasons.

### Runtime (inside a provider)
A **Runtime** is the underlying inference mechanism a provider uses, e.g.:

- OS-managed system framework (Apple Foundation Models, Android ML Kit GenAI)
- on-device inference runtime (Core ML, ExecuTorch)
- cloud API transport (HTTP/SSE/realtime)

A provider typically wraps a single runtime, but may include multiple execution paths internally.

### Model (artifact / selection)
A **Model** is the actual weights and configuration used by a runtime, e.g.:

- Apple-managed on-device model(s) (via Foundation Models)
- Gemini Nano / system-provided on-device model(s) (via Android ML Kit GenAI)
- `.mlpackage` / `.mlmodelc` for Core ML
- exported ExecuTorch model package
- OpenAI model name (`model="..."`) via API

IndeRun may later add `modelRef` to requests; **routing chooses providers**, not models.

---

## 2) IndeRun Provider contract (reference)

### 2.1 ProviderDescriptor (static-ish metadata)
This is used by routing and policy evaluation.

```ts
type ProviderDescriptor = {
  id: string
  type: "local" | "edge" | "cloud"
  transport: "in_process" | "system_service" | "http" | "sse" | "realtime"
  streamingStyle?: "tokens" | "chunks" | "snapshots"

  supports: {
    run: boolean
    streaming: boolean
    realtime: boolean
    tools: boolean
    reasoningEvents: boolean
    structuredOutput: boolean
    multimodal: boolean
  }

  cancel: "hard" | "soft" | "none"

  tasks: string[] // e.g. ["text_to_text", "tts", "embed"]

  limits?: {
    maxInputTokens?: number
    maxOutputTokens?: number
    maxImageBytes?: number
    maxAudioSeconds?: number
  }

  privacy?: {
    dataLeavesDevice: boolean
    regions?: string[]
  }
}
```

### 2.2 Dynamic capabilities (`capabilities(host)`)
Evaluated at runtime (per request or per session tick):

- availability of system API/runtime
- network reachability (for cloud)
- host service availability, including secure credential storage and normalized HTTP transport for cloud providers
- auth availability (credential slots referenced by `authContextRef`)
- device constraints (thermal/low-power/memory class)

Cloud providers must resolve credentials through `host.secureStorage` using `request.authContextRef` during execution.
They must not accept raw API keys, bearer tokens, or provider secrets on `TaskRequest`; those fields are invalid at the
contract validation layer.

### 2.3 Shared route-planning boundary

The shared Rust planner only consumes normalized provider descriptor data and dynamic capability snapshots. It does not:

- execute providers
- access host services directly
- resolve credentials
- make HTTP calls
- own Mode 2 or Mode 3 orchestration

Platform SDKs remain responsible for mapping the selected provider ID back to a concrete provider adapter instance and
then executing the request locally.

---

## 3) Provider inventory (planned/discussed)

### 3.1 System-managed on-device LLM providers

#### A) `AppleFoundationModelsProvider` (iOS)
- **Type:** `local`
- **Transport:** `system_service` (conceptually; implementation may be framework calls)
- **Runtime:** Apple Foundation Models framework
- **Models:** Apple-managed on-device models (not shipped as your weights)
- **Primary tasks:** `text_to_text` for Mode 1 `run()`
- **Notes:**
  - implemented in the iOS Swift package as an explicitly registered provider through `IndeRunAppleProviders`
  - availability varies by OS, device eligibility, Apple Intelligence enablement, and model readiness, and is checked dynamically
  - model choice/config may be constrained by system API
- **Cancellation:** `soft`; Mode 2 stream/session cancellation is not implemented in this provider yet

**Typical capability flags (initial milestone):**
- `supports.run = true`
- `supports.streaming = false`
- `supports.realtime = false`
- `supports.tools = false`
- `privacy.dataLeavesDevice = false`

**Mode-1 Swift error mapping:**
- system model unavailable before route selection or execution -> `CapabilityMismatch`
- unexpected Foundation Models/runtime failures -> `Internal`

---

#### B) `AndroidMlKitGenAiProvider` (Android)
- **Type:** `local`
- **Transport:** `system_service`
- **Runtime:** Android ML Kit GenAI APIs (backed by system on-device model stack)
- **Models:** typically Gemini Nano/system-provided models
- **Primary tasks:** `text_to_text` (initially)
- **Notes:**
  - device support and availability vary
  - API surface dictates available features
- **Cancellation:** often `soft`; IndeRun enforces standardized cancellation semantics

**Typical capability flags (initial milestone):**
- `supports.run = true`
- `supports.streaming = false` (until implemented)
- `supports.realtime = false` (until implemented)
- `privacy.dataLeavesDevice = false`

---

### 3.2 Cloud providers

#### C) `OpenAIProvider` (Web + iOS + Android)
- **Type:** `cloud`
- **Transport:** `http` (Mode 1), later `sse` (Mode 2), later `realtime` (Mode 3)
- **Runtime:** OpenAI Responses API for Mode 1
- **Models:** configured by model name per environment/policy
- **Primary tasks:** `text_to_text` (initially), later many modalities
- **Notes:**
  - **Production browser apps** should use a proxy/your backend (do not ship API keys to clients)
  - Web, iOS, and Android providers all post the same Responses-compatible JSON subset to either the OpenAI endpoint or a configured proxy/gateway endpoint
  - direct OpenAI authentication must use `authContextRef` and `SecureStorageService`, never raw request fields
  - rate limits and transient errors require typed mapping and optional retry policies
- **Cancellation:** for Mode 1, cancellation follows the native async primitive (`AbortController`, `Task.cancel()`, coroutine cancellation) and should abort the active HTTP attempt where the host transport supports it

**Typical capability flags (initial milestone):**
- `supports.run = true`
- `supports.streaming = false` (until implemented)
- `supports.realtime = false` (until implemented)
- `privacy.dataLeavesDevice = true` (cloud egress)

**Mode-1 parity behavior (Web/iOS/Android):**
- request mapping uses `model` plus either prompt text or a Responses `input` array built from canonical `messages`
- `system` messages are mapped to OpenAI `developer` role in the Responses input array
- supported generation fields are `max_output_tokens`, `temperature`, `top_p`, and `stop`
- `401` / `403` -> `AuthError`
- `429` -> `RateLimited`
- `408` / `504` -> `Timeout`
- `409` / `5xx` -> `Unavailable`
- other non-2xx responses or malformed success payloads -> `Internal`

---

### 3.3 Custom model runtimes (on-device inference engines)

These providers enable **developer-supplied** models for tasks like TTS, embeddings, vision, or custom LLMs. They become important after the text→text milestone.

#### D) `CoreMLProvider` (iOS)
- **Type:** `local`
- **Transport:** `in_process`
- **Runtime:** Core ML
- **Models:** `.mlpackage` / `.mlmodelc` (Apple-provided gallery models or developer-converted models)
- **Primary tasks:** depends on model: `tts`, `embed`, `vision`, possibly `text_to_text` if you ship a CoreML LLM + generation loop
- **Notes:**
  - Core ML is a runtime; **models must be converted** to Core ML format
  - full pipelines (e.g., TTS) may require multiple sub-models + Swift glue
  - per-model limits vary; capability reporting should be model-aware
- **Cancellation:** often `soft` (depends on execution style)

**Typical capability flags (varies by model):**
- `supports.run = true`
- `supports.streaming = usually false` (unless you implement token streaming manually)
- `privacy.dataLeavesDevice = false`

**Model sources:**
- Apple model gallery (prebuilt assets)
- Developer models optimized/converted with `coremltools`

---

#### E) `ExecuTorchProvider` (iOS + Android)
- **Type:** `local`
- **Transport:** `in_process`
- **Runtime:** ExecuTorch (PyTorch deployment runtime)
- **Models:** exported ExecuTorch packages (from PyTorch)
- **Primary tasks:** often `tts`, `embed`, `vision`, custom LLM inference depending on model
- **Notes:**
  - closer to PyTorch ecosystem than Core ML (often less conversion friction)
  - performance depends on available delegates/backends and model/operator support
  - packaging and runtime size are considerations
- **Cancellation:** typically `soft` (unless runtime supports interruption)

**Typical capability flags (varies by model):**
- `supports.run = true`
- `supports.streaming = false` by default
- `privacy.dataLeavesDevice = false`

---

### 3.4 Cross-platform solution runtimes

#### F) `MediaPipeLLMProvider` (Web + iOS + Android)
- **Type:** `local` (or `edge` depending on deployment)
- **Transport:** varies (often in-process + callbacks)
- **Runtime:** MediaPipe LLM Inference solution stack
- **Models:** constrained to what the MediaPipe solution supports
- **Primary tasks:** often `text_to_text`, sometimes multimodal depending on setup
- **Notes:**
  - attractive for a single cross-platform approach
  - you inherit MediaPipe’s supported models and API surface
  - event normalization from callbacks to IndeRunEvent is required
- **Cancellation:** often `soft`

---

## 4) How routing “sees” these providers (examples)

### 4.1 Milestone 1 (text→text, policy toggle)
Request contract field: `policy.execution = on_device | cloud`

- iOS candidates:
  - on-device: `AppleFoundationModelsProvider`
  - cloud: `OpenAIProvider`
- Android candidates:
  - on-device: `AndroidMlKitGenAiProvider`
  - cloud: `OpenAIProvider`
- Web candidates:
  - cloud: `OpenAIProvider`

Routing rule (initial milestone):
- if `on_device`: choose on-device provider if available else `CapabilityMismatch`
- if `cloud`: choose OpenAI provider if online + auth else `Offline/AuthError`

Providers must not require provider-specific public request fields for this milestone. Cloud credentials are referenced
through `authContextRef`; direct keys or tokens in `TaskRequest` are invalid.

At execution time the cloud adapter resolves the credential slot via `SecureStorageService` and performs provider network
calls through `HttpClientService`. Missing or empty credential slots map to the normalized `AuthError` class.
The `HttpRequest` and `HttpResponse` transport payloads are schema-backed contracts; the `HttpClientService` callable
interface remains a language-native host service.

### 4.2 Later expansion (custom models)
If you add Core ML or ExecuTorch:
- iOS on-device candidates might include:
  - `AppleFoundationModelsProvider` (system LLM)
  - `CoreMLProvider` (custom model)
  - `ExecuTorchProvider` (custom model)
Router then uses capabilities + policy preferences to select the best backend.

---

## 5) Implementation notes for adapter authors

### 5.1 Keep providers honest: capability checks must be dynamic
Do not rely on “probe once at startup.” Availability changes with:
- device/OS support
- permissions
- runtime initialization failures
- network conditions (for cloud)
- memory/thermal constraints (for heavy local runtimes)

### 5.2 Cancellation: adapt hard/soft to IndeRun guarantee
Even if a provider can’t truly interrupt execution:
- close the Event Gate on cancel
- suppress late events
- emit terminal `cancelled`

### 5.3 Errors: always map to IndeRunError taxonomy
Provider-specific exceptions should never leak to the app boundary.

### 5.4 Telemetry: normalize metrics
Emit comparable metrics across providers:
- total duration
- provider latency where meaningful
- error class
- (later) TTFB, token counts, fallback counts

---

## 6) Planned next additions (not in Milestone 1)

- Mode 2 streaming: `stream()` + unified IndeRunEvent union
- Mode 3 sessions: `openSession()` + bidirectional InputEvent/IndeRunEvent loop
- tool calling + reasoning events (mechanics vs content separation)
- richer policy engine (fallback, weights, constraints)
- model selection (`modelRef`) and model catalog (per provider)
- Mode 4 submit/jobs (future; additive)
