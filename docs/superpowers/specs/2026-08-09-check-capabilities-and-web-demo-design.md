# checkCapabilities() Introspection + Web Demo Routing Showcase

Status: approved design, ready for implementation planning (`writing-plans`).

## Context

Milestone 2 issue #78 added a third Web provider (`local.system-model.web`, browser-owned Chrome
Prompt API) alongside the existing OpenAI-compatible cloud provider and the ONNX Runtime local
provider (`local.onnx.genai.web`). The Web demo app (`packages/inderun-web-demo`) currently only
demonstrates two providers via a forced binary "On Device / Cloud" toggle that maps directly to
`constraints.privacy = "local_required"` or `"cloud_required"` — it never shows IndeRun's actual
value proposition: automatic, capability-based routing across providers.

With three real providers now available in the browser, this is the first point where the demo can
show genuine routing behavior: preference in, automatic provider selection out, based on live
per-provider availability (e.g. Prompt API only in Chrome 138+, ONNX everywhere, cloud needs the
proxy reachable).

This also surfaced a real bug (already fixed and committed): `SystemModelWebProvider` defaulted to
the deterministic fixture runtime instead of `createChromePromptApiRuntime()`, contradicting its
own spec doc and README. That fix is done; this spec is unrelated follow-on work.

Two things are in scope for this spec:

1. A small, reusable introspection method — `checkCapabilities()` — added to the `IndeRun`
   orchestrator on **all three platforms** (TS/Web, Swift/iOS, Kotlin/Android), for architecture
   parity per `CLAUDE.md` §4 (cross-platform consistency is a stated goal). The Web demo is the
   first consumer, but this is not a demo-only hack.
2. A redesign of the Web demo app to use it: a 4-way privacy-preference control, live per-provider
   capability badges, and a routing-transparency panel showing why a provider was selected/rejected.

**Out of scope** (deferred, tracked separately): generating the interface *signatures* themselves
from a shared spec across platforms — filed as
[independo-gmbh/inderun#123](https://github.com/independo-gmbh/inderun/issues/123), explicitly
marked "needs research, not ready to implement," scheduled as the last issue of Milestone 2. This
spec's `checkCapabilities()` is hand-written per platform, matching how every other method on these
classes is written today.

## Part 1: `checkCapabilities()` on all three platforms

### Shared shape

A "capability snapshot" per registered provider: provider id, its static descriptor, and its
current dynamic capability check result. No new data travels across the wire or through contracts —
this is pure in-process introspection built entirely from data that already exists
(`ProviderAdapter.describe()` + `ProviderAdapter.capabilities(host)`), exposed on the already-private
`registry`/`hostServices` the orchestrator already holds.

### TypeScript — `packages/inderun-web/src/engine.ts`

Add a new exported type (in `engine.ts` or alongside `ProviderAdapter` in `provider.ts` — prefer
`provider.ts` since it's a provider-shaped type, consistent with where `ProviderDescriptor`/
`ProviderDynamicCapabilities` already live):

```ts
export interface ProviderCapabilitySnapshot {
  providerId: string;
  descriptor: ProviderDescriptor;
  capabilities: ProviderDynamicCapabilities;
}
```

New method on `IndeRun`:

```ts
/**
 * Reports each registered provider's static descriptor and current dynamic capability check,
 * without executing a task. Useful for UI that shows live provider availability before a run.
 */
async checkCapabilities(): Promise<ProviderCapabilitySnapshot[]> {
  return Promise.all(
    this.registry.list().map(async (provider) => ({
      providerId: provider.describe().id,
      descriptor: provider.describe(),
      capabilities: await provider.capabilities(this.hostServices)
    }))
  );
}
```

Export `ProviderCapabilitySnapshot` from `packages/inderun-web/src/index.ts` alongside the existing
`ProviderDescriptor`/`ProviderDynamicCapabilities` exports (check the exact export block — `index.ts`
already re-exports these two from `provider.js`).

**Test** (TDD, add to `packages/inderun-web/src/engine.test.ts` — read the existing file first to
match its fixture/provider-construction style exactly, e.g. how it builds fake `ProviderAdapter`s
and a `HostServices` instance):

- Registering two fake providers (one `available: true`, one `available: false, reason: "..."`) and
  asserting `checkCapabilities()` returns both snapshots with correct `providerId`/`descriptor`/
  `capabilities`, in registration order (matches `registry.list()`'s `Map` insertion-order
  guarantee).
- Asserts it does **not** execute `run()` on any provider (no side effects beyond the capability
  check) — e.g. a fake provider whose `run()` throws should not cause `checkCapabilities()` to
  reject.

### Swift — `ios/IndeRun/Sources/IndeRunSwift/IndeRun.swift` + `IndeRunCore/Provider.swift`

New type in `Provider.swift`, next to `ProviderDescriptor`/`ProviderDynamicCapabilities`:

```swift
public struct ProviderCapabilitySnapshot: Sendable {
    public let providerId: String
    public let descriptor: ProviderDescriptor
    public let capabilities: ProviderDynamicCapabilities
}
```

New method on `IndeRun` (the class already holds `private let registry: ProviderRegistry` and
`private let hostServices: HostServices`):

```swift
public func checkCapabilities() async -> [ProviderCapabilitySnapshot] {
    var snapshots: [ProviderCapabilitySnapshot] = []
    for provider in registry.list() {
        let descriptor = provider.describe()
        let capabilities = await provider.capabilities(host: hostServices)
        snapshots.append(
            ProviderCapabilitySnapshot(
                providerId: descriptor.id,
                descriptor: descriptor,
                capabilities: capabilities
            )
        )
    }
    return snapshots
}
```

(Sequential loop, not a concurrent `TaskGroup` — matches the low-provider-count, simplicity-first
style of the rest of this class; do not over-engineer with concurrency here.)

**Test**: add to `ios/IndeRun/Tests/IndeRunTests/IndeRunTests.swift` — read the existing file first
to match its fake-provider/registry-construction pattern. Same two assertions as TS: snapshot
correctness for available + unavailable providers, and no `run()` side effects.

### Kotlin — `android/inderun-kotlin/.../IndeRun.kt` + `inderun-core/.../Provider.kt`

New type in `Provider.kt`, next to `ProviderDescriptor`/`ProviderDynamicCapabilities`:

```kotlin
data class ProviderCapabilitySnapshot(
    val providerId: String,
    val descriptor: ProviderDescriptor,
    val capabilities: ProviderDynamicCapabilities
)
```

New method on `IndeRun` (already holds `private val registry: ProviderRegistry` and
`private val hostServices: HostServices`):

```kotlin
suspend fun checkCapabilities(): List<ProviderCapabilitySnapshot> {
    return registry.list().map { provider ->
        val descriptor = provider.describe()
        val capabilities = provider.capabilities(hostServices)
        ProviderCapabilitySnapshot(descriptor.id, descriptor, capabilities)
    }
}
```

**Test**: add to `android/inderun-kotlin/src/test/kotlin/app/independo/inderun/sdk/IndeRunTest.kt` —
read the existing file first to match its style. Same two assertions as TS/Swift.

### Docs requirement (CLAUDE.md §8 — must land in the same task)

Add a short paragraph to `docs/architecture/architecture.md` describing `checkCapabilities()` as
part of the engine core's public surface: what it returns, that it performs no execution/side
effects, and that it exists on all three platforms with the same shape. Check the file's existing
structure first (read it) and place this next to wherever `run()`/the engine surface is already
described, rather than creating a new top-level section for one method.

## Part 2: Web demo redesign (`packages/inderun-web-demo`)

### Provider wiring — `src/demo-client.ts`

- Add a third provider registration: `systemModel: {}` passed to `createIndeRunWeb`. No env-var
  gating needed (unlike ONNX's fixture-vs-real split) — the Chrome runtime's own `availability()`
  check naturally reports `api_missing`/etc. on unsupported browsers, so there is no offline/CI
  concern; the badge will just show "unavailable" in non-Chrome test environments, which is
  correct and desired behavior for a live demo.
- Add a `TelemetryService` implementation that records the most recent `route_decided` event's
  `payload` (a loosely-typed `{ [key: string]: unknown }` per the `TelemetryEvent` contract — read
  `engine.ts`'s `safeEmit({ type: "route_decided", ... payload: {...} })` call for the exact field
  names it populates: `selectedProviderId`, `fallbackProviderIds`, `rejectedProviders`,
  `explanation`, `constraints`, `preferences`, `plannerSource`, `plannerUnavailableReason`).
  Since `payload` is untyped at the contract level, this module should define its own narrow local
  interface describing the fields it reads (e.g. `RouteDecidedPayload`) and validate/cast
  defensively — do not assume the untyped payload is safe to use without guards.
- Pass this telemetry service via `hostServices: { telemetry }` in the `createIndeRunWeb(...)` call.
- Change `runPrompt(prompt: string, executionMode: "on_device" | "cloud")` to
  `runPrompt(prompt: string, privacy: Privacy)` where `Privacy` is imported from
  `@independo/inderun-contracts` (`"local_required" | "local_preferred" | "cloud_allowed" |
  "cloud_required"`). Build `constraints: { privacy }` directly — no more mode-to-constraint mapping
  logic.
- Add `checkProviderCapabilities(): Promise<ProviderCapabilitySnapshot[]>` wrapping
  `inderun.checkCapabilities()` (imported type from `@independo/inderun-web`, added in Part 1).
- Add `getLastRouteDecision(): RouteDecidedPayload | undefined` (or similar) exposing what the
  telemetry service captured for the most recent run, for the UI layer to read after each run
  completes.
- Update `getDemoClientConfig()` to also report whatever's useful about the system-model provider
  for the "hint" text under the run button — check how `onDeviceModel` is used today in `app.ts` and
  extend consistently (e.g. note that the Prompt API needs no configured model, unlike ONNX).

### UI — `src/app.ts`

Replace the current `AppState`/render structure's mode selector and metadata panel. Key changes:

1. **Preference selector**: replace `#mode-on-device`/`#mode-cloud` buttons with four buttons/a
   segmented control for the four `Privacy` values. Suggested labels: "Local Only"
   (`local_required`), "Prefer Local" (`local_preferred`), "Cloud Allowed" (`cloud_allowed`,
   default/pre-selected — matches today's implicit default of not forcing a constraint), "Cloud
   Only" (`cloud_required`). Follow the existing `.mode-btn`/`.mode-btn.active` CSS pattern in
   `styles.css` for these four buttons (rename class if useful, e.g. `.preference-btn`, but keep the
   same visual language — pill-shaped, active-state fill).
2. **Provider availability panel** (new section, placed near the composer): on mount, and after
   every run completes (Prompt API download state can change between runs), call
   `checkProviderCapabilities()` and render one badge per provider: id, a short human label (Cloud /
   ONNX Local / Prompt API Local — derive from `descriptor.type`/`descriptor.transport` or hardcode
   a small id→label map, whichever reads cleaner in the render function), available/unavailable
   state, and the `reason` string when unavailable. This is async and mount-time, so `mountApp` needs
   an initial capability fetch before or alongside first render — follow the existing `render()`
   closure pattern in `app.ts`, adding a loading state for this panel distinct from the run
   `status` state machine (do not conflate provider-availability loading with the existing
   `idle/running/success/error` states, which are about the *run*, not the *badges*).
3. **Routing decision panel**: after a run (success or error), show the captured route decision:
   selected provider + `explanation.summary`, and if `rejectedProviders` is non-empty, list each
   rejected provider id with its reason `code`s and `message`s. This can replace or sit alongside
   the existing "Attempt Metadata" panel — read the current `renderRunMetadata` function and decide
   whether to extend it in place or add a new `renderRoutingDecision` function; prefer a new
   function for clarity since the data source (telemetry capture) is different from
   `state.result`/`state.error`.
4. **Known Limitations copy**: update the existing `<ul>` to mention the Prompt API is Chrome
   138+ desktop-only and that its badge will show unavailable elsewhere — this is expected, not a
   bug, and the copy should say so explicitly (a reviewer seeing "unavailable" for Prompt API in
   Firefox/Safari should understand why immediately).

### Testing — `src/app.test.ts`

Read the existing file fully first (already done during design) — it mounts the app with a mocked
`runPrompt`, clicks mode buttons, and asserts on `root.textContent`. Extend this pattern:

- Mock `checkProviderCapabilities` returning a fixed 3-provider snapshot list (mix of available/
  unavailable) and assert the badge panel renders all three with correct states.
- Click each of the 4 preference buttons and assert `runPrompt` is called with the corresponding
  `Privacy` value (replacing the existing 2 mode-button tests).
- Mock `getLastRouteDecision` returning a fixture `route_decided` payload with one rejected provider
  and assert the routing-decision panel renders the explanation and the rejection reason.
- Keep the existing success/error rendering assertions, updated for the new `AppDependencies` shape
  (`runPrompt(prompt, privacy)` instead of `runPrompt(prompt, executionMode)`).

### Non-goals for this spec

- No changes to `packages/inderun-demo-proxy` (server-side proxy is unaffected).
- No changes to routing/engine *behavior* — `checkCapabilities()` is read-only introspection, and
  the demo's privacy preferences use the existing `Privacy` contract exactly as-is.
- No visual/CSS system redesign beyond what's needed for the new panels — follow existing
  `styles.css` variables and patterns (`--accent`, `.panel`, `.pill`, `.mode-btn` conventions) rather
  than introducing a new design language.
- Real-browser verification of the Prompt API path is not achievable in this environment (no
  Chrome 138+ available) — same caveat as the original #78 work; note this explicitly rather than
  claiming it was tested.

## Verification

- TS: `pnpm --filter @independo/inderun-web test`, `pnpm --filter @independo/inderun-web build`,
  `pnpm --filter @independo/inderun-web-demo test`, `pnpm --filter @independo/inderun-web-demo build`
- Swift: `swift test`, `cd ios/IndeRun && swiftlint lint --strict`
- Kotlin: `cd android && ./gradlew test`, `cd android && ./gradlew spotlessCheck`
- `pnpm lint`, `pnpm format:check` (or the JS-scoped variants used earlier in this session)
- Manual (best effort, flag if unavailable): run `packages/inderun-web-demo` locally
  (`pnpm --filter @independo/inderun-web-demo dev`) in a real browser and click through all four
  preference options, observing badge states and routing decisions change appropriately.

## Risks / follow-ups

- `checkCapabilities()` calls every provider's `capabilities(host)`, which for the OpenAI provider
  is a cheap synchronous-shaped check (no network call — verified in `openai-provider.ts`) but for
  future providers could become expensive or side-effecting; this spec doesn't add any guard against
  that because none of today's three providers need one, but a future provider author should keep
  `capabilities()` cheap and side-effect-free, consistent with its existing contract.
- The interface-generation issue (#123) is explicitly not part of this work; `checkCapabilities()`
  here is hand-written per platform like everything else today.
