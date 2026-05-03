# Architecture

**Project:** IndeRun (by Independo)  
**Scope in this document:** Interaction **Modes 1–3** (Run, Stream, Session).  
**Explicitly out of scope (for now):** **Mode 4** (Submit/Jobs). We design seams so Mode 4 is additive later, but we do
**not** optimize for it now.

---

## 0) Why this architecture

IndeRun is an execution layer that lets apps run the **same AI tasks** through one **unified interface**, independent of
where the model runs (on-device / embedded runtime / edge / cloud).

This architecture is based on **Approach 2** (shared “Engine Core” + platform “Host Services” + provider “Adapters”). It
is chosen because it:

- supports **policy-based routing** using capability metadata (privacy, latency, cost, connectivity, device
  constraints),
- supports **normalized streaming** (not just text) across wildly different provider streaming styles,
- provides **standard cancellation semantics** even when providers can only “soft cancel”,
- is **testable and deterministic**: routing decisions can be regression-tested with fixed snapshots,
- maps cleanly to **Web (TS), iOS (Swift), Android (Kotlin)**, and a **Capacitor bridge** as a *thin wrapper* (not a
  peer runtime).

---

## 1) Layering model

### 1.1 Conceptual layers

```
Layer A — Application (Consumers)
  - Web app (TS)
  - Native iOS app (Swift)
  - Native Android app (Kotlin)
  - Capacitor app (TS)  ← special consumer type

Layer B — IndeRun SDK surfaces (Public APIs)
  - @independo/inderun-web
  - IndeRun iOS SDK
  - IndeRun Android SDK
  - @independo/capacitor-inderun  ← thin facade/bridge

Layer C — Engine Core + Host Services + Provider Adapters
  - Engine Core (routing/policy/orchestrator/events)
  - Host Services (platform-specific OS access)
  - Provider Adapters (local / edge / cloud)
```

### 1.2 Capacitor is *one layer above*

Capacitor is best modeled as **distribution + bridge**, not a peer runtime:

- In a **Capacitor app**, the JS API is a facade:
    - on **Web**: delegates to `@independo/inderun-web`
    - on **iOS/Android**: delegates to native SDKs via the Capacitor bridge

```
Capacitor App (JS)
  uses @independo/capacitor-inderun (thin facade)
      ├─ Web: uses @independo/inderun-web directly
      ├─ iOS: bridge → IndeRun iOS SDK (Swift)
      └─ Android: bridge → IndeRun Android SDK (Kotlin)
```

---

## 2) Interaction modes (1–3)

IndeRun must support **three** interaction modes now.

### Mode 1 — Run (non-streaming)

- Use when the caller waits for a final result.
- API: `run(request) -> Result`

### Mode 2 — Stream (streaming)

- Use for token/chunk/snapshot streaming.
- API: `stream(request) -> StreamHandle`
- Handle provides `events()` and `cancel()`

### Mode 3 — Session (bidirectional realtime)

- Use for voice/realtime/continuous inputs and agentic loops.
- API: `openSession(config) -> SessionHandle`
- Handle provides `send()`, `events()`, `interrupt()`, `close()`

> Note: We keep **Mode 4 seams** (IDs, context caching, forward-compatible schema) but do not implement job/queue
> infrastructure.

---

## 3) Public API surface (canonical shapes)

The public API surface must exist on **each** platform and map to the same conceptual primitives.

### 3.1 Canonical types (conceptual)

- `TaskRequest`, `TaskResult`
- `IndeRunEvent` (unified event union)
- `IndeRunError` (typed error taxonomy)
- `runId`, `sessionId` (opaque strings)

### 3.2 API definitions (conceptual)

```ts
// Mode 1
run(request: TaskRequest, opts?: RunOptions): Promise<TaskResult>

// Mode 2
stream(request: TaskRequest, opts?: StreamOptions): StreamHandle
interface StreamHandle {
  runId: string
  events(): AsyncIterator<IndeRunEvent>
  cancel(reason?: string): Promise<void>
}

// Mode 3
openSession(config: SessionConfig, opts?: SessionOptions): Promise<SessionHandle>
interface SessionHandle {
  sessionId: string
  send(input: InputEvent): Promise<void>
  events(): AsyncIterator<IndeRunEvent>
  interrupt(reason?: string): Promise<void>
  close(reason?: string): Promise<void>
}
```

### 3.3 Platform mappings

- Web/TS: `AsyncIterator<IndeRunEvent>`
- Swift: `AsyncStream<IndeRunEvent>`
- Kotlin: `Flow<IndeRunEvent>`
- Capacitor: event emitter channels keyed by `runId/sessionId`

---

## 4) Canonical schema & versioning

### 4.1 Canonical format choice

**Canonical interchange format:** JSON with JSON Schema (source of truth).

Why:

- Capacitor bridge payloads are JSON-serializable.
- Easy forward-compat parsing (ignore unknown fields).
- Straightforward codegen into TS/Swift/Kotlin.

> Internally, native SDKs can use strongly typed structs/classes; the canonical wire form remains JSON.

### 4.1.1 Milestone-1 contract subset

The first implementation artifact is `@independo/inderun-contracts`, which defines the Mode-1 text-to-text subset:

- `TaskRequest` with `schemaVersion = "1.0"`, `task.kind = "text_to_text"`, text input via `prompt` or text
  `messages`, `policy.execution = "on_device" | "cloud"`, optional generation hints, telemetry preferences, and
  `authContextRef`.
- `TaskResult` with text output, finish reason, optional token usage, and required telemetry fields `providerUsed` and
  `totalMs`.
- `IndeRunError` with normalized milestone error classes: `CapabilityMismatch`, `Offline`, `AuthError`, `RateLimited`,
  `Timeout`, `Unavailable`, and `Internal`.

Milestone-1 schemas intentionally allow unknown fields for forward-compatible parsing. Implementations must ignore
unknown fields they do not understand, but must still reject inline secret-like fields; credentials belong behind
`authContextRef`.

### 4.2 Versioning rules

- Every request/result/event includes `schemaVersion`.
- Backward-compatible evolution:
    - avoid field removals
    - add fields with defaults
    - deprecate with semantics (do not silently repurpose)

---

## 5) Request model (modality-first + future-proof)

A request should be typed by task and support multimodal parts, tools, and structured output.

### 5.1 TaskRequest (recommended shape)

```ts
type TaskRequest = {
  schemaVersion: string
  requestId?: string                 // client-supplied id (optional)
  task: { kind: string }             // "chat" | "embed" | "transcribe" | "tts" | ...

  // Inputs: allow message format, prompt, and multimodal parts
  prompt?: string
  messages?: Array<{
    role: "system"|"user"|"assistant"|"tool"
    content: string | Parts
  }>

  parts?: Array<
    | { type: "text"; text: string }
    | { type: "image"; bytes?: string; url?: string; mime?: string }
    | { type: "audio"; bytes?: string; url?: string; mime?: string; sampleRate?: number }
  >

  generation?: {
    maxOutputTokens?: number
    temperature?: number
    topP?: number
    seed?: number
    stop?: string[]
  }

  tools?: Array<ToolSpec>
  responseFormat?: { type: "text" | "json" | "schema"; schema?: unknown }

  constraints?: {
    privacyLevel?: "strict_local" | "local_preferred" | "cloud_allowed" | "cloud_only"
    maxLatencyMs?: number
    maxCostUsd?: number
    timeoutMs?: number
    streaming?: boolean
  }

  // Mode-4-ready seam (do not implement jobs yet):
  context?:
    | { mode: "ephemeral" }
    | { mode: "cached"; cacheId?: string; ttlMs?: number }

  telemetry?: {
    consent?: boolean
    level?: "off" | "minimal" | "debug"
    tags?: Record<string,string>
  }

  // Never include secrets inline:
  authContextRef?: string            // references a secure credential slot
}
```

### 5.2 Notes

- **Secrets never travel in request payloads.** Use `authContextRef` to reference credentials stored in secure storage.
- `context` exists now to avoid a future breaking change when provider caching primitives are added.
- Mode 4 is not implemented, but `requestId` + `context` are needed later for idempotency/dedup and caching.

---

## 6) Unified event model (content vs mechanics)

Streaming cannot be “just text”. The event model must separate **user-visible content** from **mechanics** (
reasoning/tool events).

### 6.1 IndeRunEvent union (minimum)

```ts
type IndeRunEvent =
  | { type: "content_delta"; runId?: string; sessionId?: string; delta: ContentDelta }
  | { type: "reasoning_delta"; runId?: string; sessionId?: string; delta: ReasoningDelta } // never render by default
  | { type: "tool_call"; runId?: string; sessionId?: string; call: ToolCall }
  | { type: "tool_output"; runId?: string; sessionId?: string; output: ToolOutput }
  | { type: "audio_delta"; runId?: string; sessionId?: string; chunk: string; mime: string; sampleRate?: number }
  | { type: "image_artifact"; runId?: string; sessionId?: string; bytes?: string; url?: string; mime?: string }
  | { type: "progress"; runId?: string; sessionId?: string; stage: string; pct?: number }
  | { type: "metrics"; runId?: string; sessionId?: string; ttfbMs?: number; tokensSoFar?: number; providerLatencyMs?: number }
  | { type: "done"; runId?: string; result: TaskResult }
  | { type: "error"; runId?: string; error: IndeRunError }
  | { type: "cancelled"; runId?: string; reason?: string }
```

### 6.2 Rendering & safety defaults

- Default UI should render **only** `content_delta` (and media artifacts if applicable).
- `reasoning_delta`, `tool_call`, `tool_output` are **mechanics** and should be **opt-in**.
- Telemetry redaction is independent from event emission (see §11).

---

## 7) Cancellation semantics (standardized guarantee)

Providers differ widely: some support aborting HTTP/SSE, some only allow stopping delivery, some do nothing. IndeRun
must still behave predictably.

### 7.1 Provider capability

Each provider declares:

- `cancel: "hard" | "soft" | "none"`

### 7.2 IndeRun guarantee (Mode 2 + Mode 3)

After `cancel()` / `interrupt()`:

1. **No more events** are delivered to the consumer.
2. IndeRun emits a terminal `cancelled` event (unless already `done/error`).
3. Any fallback chain is stopped.

### 7.3 How it’s enforced

The Engine Core owns an **Event Gate** per `runId/sessionId`:

- all adapter events flow through the gate
- cancel closes the gate
- late provider callbacks/events are suppressed

This makes “soft cancel” reliable from the app’s perspective.

---

## 8) Provider capability metadata (required for routing)

Policy-based routing is only robust if provider adapters publish sufficient metadata.

### 8.1 ProviderDescriptor (static-ish)

```ts
type ProviderDescriptor = {
  id: string
  type: "local" | "edge" | "cloud"
  transport: "in_process" | "system_service" | "http" | "sse" | "realtime"
  streamingStyle?: "tokens" | "chunks" | "snapshots"

  supports: {
    streaming: boolean
    realtime: boolean
    multimodal: boolean
    tools: boolean
    reasoningEvents: boolean
    structuredOutput: boolean
  }

  cancel: "hard" | "soft" | "none"

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

### 8.2 ProviderDynamicCapabilities (evaluated at runtime)

Computed per request (or per session tick) using Host Services:

- runtime availability (local runtime present?)
- connectivity reachability (online? DNS reachable?)
- auth availability (credential slot present?)
- device constraints (thermal, low power, memory class)

---

## 9) Engine Core modules (Mode 1–3)

### 9.1 Core components

1) **ProviderRegistry**

- loads adapters and descriptors
- maintains health metrics per provider (error rates, latency EWMA, breaker state)

2) **CapabilitiesSnapshot**

- pulled from Host Services:
    - network (online/metered/bandwidth)
    - device constraints (thermal/battery/memory class)
    - storage budgets if needed for caching
- for sessions: refreshed periodically or on meaningful changes

3) **PolicyEngine**

- hard constraints: privacy/offline/cost/latency limits
- soft preferences: weights and heuristics
- allow/deny lists by provider/model/region

4) **Router**

- filters candidate providers by capabilities + policy
- scores candidates deterministically (inspectable scoring)
- produces a primary + fallback chain
- outputs a **route explanation** for debugging

5) **Orchestrator**

- Mode 1: attempt chain; return final `TaskResult`
- Mode 2: stream orchestration:
    - normalize provider deltas → IndeRun events
    - enforce cancellation gate
    - handle fallback policy when partial output exists (see below)
- Mode 3: session orchestration:
    - open/send/events/interrupt/close state machine
    - tool loop integration strategy (app-managed or engine-managed)

6) **EventBus + Gate**

- event normalization + multiplexing
- cancellation guarantee enforcement

7) **Telemetry**

- standardized spans/events, configurable levels (off/minimal/debug)

### 9.2 Routing algorithm (deterministic, inspectable)

```
inputs: request, policy, capabilitiesSnapshot, providerDescriptors, healthState

1) candidates = providers supporting task + required features
2) candidates = candidates ∩ allowlist - denylist
3) candidates = filterHardConstraints(candidates, policy, snapshot)
4) for each candidate:
     score = wL*latencyScore + wC*costScore + wQ*qualityScore
             - penalties (warmup, metered, thermal, privacy risk)
5) primary = argmax(score)
6) fallbacks = buildFallbackChain(primary, candidates, policy)
7) execute(primary -> fallbacks) with time budgets + cancellation gating
```

**Key requirement:** expose “why selected” and “why rejected” for debugging.

### 9.3 Fallback nuance for streaming/session

Fallback is easy for Mode 1; harder for Mode 2/3 when partial output exists.

Define a policy option:

- `fallbackBehavior: "continue" | "fail_on_partial"`

Recommended default for developer sanity:

- Mode 2: **continue** (emit a `progress` marker + route change metadata)
- Mode 3: usually **fail_on_partial** unless the provider supports session continuation semantics

---

## 10) Provider adapter interface (Mode 1–3)

Adapters hide provider-specific APIs behind a uniform contract.

```ts
interface ProviderAdapter {
  describe(): ProviderDescriptor

  capabilities(host: HostServices): Promise<ProviderDynamicCapabilities>

  estimate?(req: TaskRequest): Promise<{ latencyMs?: number; costUsd?: number }>

  run(req: TaskRequest, ctx: RunContext): Promise<TaskResult>

  stream?(req: TaskRequest, ctx: RunContext): AsyncIterator<IndeRunEvent>

  openSession?(cfg: SessionConfig, ctx: SessionContext): Promise<ProviderSession>

  cancel?(id: { runId?: string; sessionId?: string }, reason?: string): Promise<void>
}

interface ProviderSession {
  send(input: InputEvent): Promise<void>
  events(): AsyncIterator<IndeRunEvent>
  interrupt(reason?: string): Promise<void>
  close(reason?: string): Promise<void>
}
```

### 10.1 Bridging reality (what adapters normalize)

Adapters translate to the shared event model from sources such as:

- Swift `AsyncSequence`
- Kotlin `Flow`
- callback APIs `(partial, done)`
- token callbacks (embedded runtimes)
- HTTP + SSE deltas
- bidirectional realtime event streams

---

## 11) Host Services boundary (platform-specific OS access)

Host Services are the only place that touches OS APIs directly. Engine Core never imports platform code.

### 11.1 Minimum HostServices

- `ConnectivityService`: online, metered, bandwidth class, DNS reachability
- `DeviceConstraintsService`: thermal state, low power mode, memory class, battery level
- `SecureStorage`: Keychain/Keystore/WebCrypto wrappers; credential slots
- `Clock`: monotonic and wall clock
- `Crypto`: hashing/signature verification (for cache keys / fingerprints)

### 11.2 Optional HostServices for Mode 3 (sessions)

- `AudioIO`: capture/playback hooks, audio device state
- `RealtimeTransport`: helper for platform sockets/RTC if needed

---

## 12) Privacy & telemetry enforcement points

### 12.1 Privacy enforcement (two gates)

1) **Router filter**: excludes providers that violate privacy constraints.
2) **Pre-attempt guard**: re-check before each attempt and on session open (prevents TOCTOU drift).

### 12.2 Telemetry levels

- `off`: nothing stored
- `minimal`: timings + provider id + error classes (no payload)
- `debug`: route explanations + richer spans; payloads only if explicit consent + safe handling

**Rule:** adapters must never log raw prompts unless explicitly allowed by policy + consent.

---

## 13) Repository layout (recommended)

```
inderun/
  packages/                          # JS/TS workspace
    inderun-contracts/               # schema + generated TS types
    inderun-web/                     # web sdk (public API + web host services + web providers)
    capacitor-inderun/               # capacitor facade + native bridge code
  core/                              # shared engine core (tech choice: Rust/TS/etc.)
    engine/                          # routing/policy/orchestrator/event gate
    schema/                          # canonical JSON schema (source of truth)
    providers/                       # built-in provider adapters (optional)
    tests/
  ios/
    IndeRun/                         # Swift Package
      Sources/IndeRunSwift/
      Sources/IndeRunCore/
  android/
    inderun-android/
      inderun-kotlin/
      inderun-core/
  docs/
    architecture/
      inderun-architecture.md
  tools/
    codegen/                         # schema -> TS/Swift/Kotlin generation
    release/                         # publish automation
```

---

## 14) Testing strategy (Mode 1–3)

1) **Deterministic core tests**

- routing decisions given fixed snapshots
- scoring function tests
- fallback behavior tests
- cancellation gate tests (“no events after cancel”)

2) **Adapter contract tests**

- provider error mapping into `IndeRunError`
- event normalization correctness
- hard vs soft cancel behavior

3) **Platform integration tests**

- Swift `AsyncStream` mapping
- Kotlin `Flow` mapping
- Capacitor event channeling by `runId/sessionId`

---

## 15) Mode 4 (future) — readiness without implementation

We keep these seams ready, but unused:

- `requestId` (client-supplied) and engine-generated `runId/sessionId`
- `context` object (ephemeral/cached) already in schema
- telemetry fields can later include `queued_ms` without schema breaks

We explicitly do **not** implement now:

- durable job store / queue
- background schedulers for replay
- submit/status/result handles

---

## 16) Implementation plan (starter)

1) Ship `@independo/inderun-contracts` (schema + TS types + validators).
2) Implement Engine Core minimal:
    - ProviderRegistry, Router (simple scoring), Orchestrator for Mode 1 & Mode 2,
    - Event Gate + cancellation semantics,
    - typed errors + normalized telemetry.
3) Implement first providers:
    - one cloud provider (HTTP/SSE),
    - one iOS local provider (system-service or in-process),
    - one Android local provider (Flow/callback-based).
4) Add Mode 3 Session once Mode 2 is stable.
5) Add `@independo/capacitor-inderun` facade once native SDK APIs are stable.

---

## Appendix A — Glossary

- **Provider:** an execution backend (local runtime, edge service, cloud API).
- **Adapter:** provider-specific implementation that maps provider IO to IndeRun schema/events.
- **Host Services:** platform API wrapper layer (connectivity, secure storage, device constraints).
- **Router:** selects provider(s) based on policy + capabilities + health.
- **Orchestrator:** executes attempts + fallback + cancellation, emits events.
- **Event Gate:** core mechanism that enforces cancellation guarantees and suppresses late events.
