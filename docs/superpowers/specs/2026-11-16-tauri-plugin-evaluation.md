# Tauri plugin for IndeRun: evaluation and roadmap

Status: evaluation only. Nothing here is implemented, and no GitHub issue or milestone covers Tauri yet. This document
is the input for deciding whether to open one.

Sources read: `docs/architecture/{technical-brief,architecture,providers}.md`, `docs/getting-started/capacitor.md`,
`docs/platforms/compatibility.md`, the Capacitor bridge
([independo-gmbh/capacitor-inderun](https://github.com/independo-gmbh/capacitor-inderun) at `main`, v1.3.0), and the
Tauri v2 plugin guides ([Plugin Development](https://tauri.app/develop/plugins/),
[Mobile Plugin Development](https://tauri.app/develop/plugins/develop-mobile/),
[Calling the Frontend](https://tauri.app/develop/calling-frontend/), read from the `tauri-apps/tauri-docs` source).

## Short answer

**On iOS and Android it is a medium effort. Most of the work has been done before.** A Tauri mobile plugin is built
like the Capacitor plugin: a JS API, a Swift class and a Kotlin class that forward canonical requests to the existing
IndeRun Swift and Kotlin SDKs. About two thirds of the Capacitor plugin's native and TypeScript logic carries over
once its Capacitor types are removed. Two packaging risks need a spike before anyone commits to a date (see
[Risks](#risks)).

**On desktop it takes more work, and the payoff is smaller.** Tauri desktop plugins are Rust only. IndeRun has no Rust
engine, only the Rust route planner. Windows and Linux have no on-device IndeRun provider beyond ONNX Runtime with a
model the app supplies. Desktop can start with the existing Web SDK running inside the webview. A native macOS path to
Apple Foundation Models is possible but needs its own work.

**Estimate:** about 7 to 10 engineer-weeks for a mobile plugin that matches Capacitor, plus desktop through the
webview and a release pipeline. Add about 2 to 3 weeks for native macOS. The uncertainty is mostly in the spikes.

## How Tauri plugins work (the parts that matter here)

- A plugin is a **Cargo crate** (`tauri-plugin-<name>`), plus an optional **npm package** with the JS bindings, an
  **Android library module** (Kotlin) and an **iOS Swift package**.
- The template splits the Rust side into `desktop.rs` (pure Rust) and `mobile.rs`. `mobile.rs` registers the native
  plugin with `register_android_plugin` / `register_ios_plugin` and forwards calls with
  `PluginHandle::run_mobile_plugin`.
- **Android:** a class extending `app.tauri.plugin.Plugin`, annotated `@TauriPlugin`, with one `@Command fun x(invoke:
  Invoke)` per command. Arguments are parsed with `invoke.parseArgs` into `@InvokeArg` classes. Results go back with
  `invoke.resolve(JSObject)`. Commands run on the **main thread**, so long work must run in the plugin's own coroutine
  scope. The Capacitor plugin already does this.
- **iOS:** a class extending `Plugin` from the `Tauri` Swift package, with `@objc func x(_ invoke: Invoke)` commands.
  Arguments are parsed with `invoke.parseArgs(T.self)`, where `T` is `Decodable`.
- **Events:** the plugin can broadcast with `trigger(event, data)`, and JS listens with `addPluginListener`. Commands
  can also take a **`Channel`** argument, which is per-call and ordered and meant for streaming.
- **Security:** each command has to be allowed by a permission file (`permissions/*.toml`) and listed in the app's
  capability file (`src-tauri/capabilities/*.json`), for example `inderun:default`. Capacitor has no equivalent.
- **Calling Rust from mobile code** is possible through JNI or C FFI, but Tauri does not provide it. We don't need it.

## How it maps onto IndeRun

```text
App JS (webview)
  │  @independo/tauri-plugin-inderun   ← same app-facing API as capacitor-inderun
  │  invoke("plugin:inderun|run" | "startStream" | …, { …, onEvent: Channel })
  ▼
tauri-plugin-inderun (Rust crate)      ← thin: command table, permissions, forwards to mobile; no routing
  ├─ mobile.rs ─► iOS: Swift Plugin    ─► IndeRun Swift SDK (SwiftPM, tag v0.5.x)
  │            └► Android: Kotlin Plugin ─► IndeRun Kotlin SDK (Maven Central 0.5.x)
  └─ desktop.rs ─► (phase 3) nothing native; the JS side runs @independo/inderun-web in the webview
```

This fits the architecture rule already written for Capacitor in `architecture.md`. A bridge forwards canonical
requests to the platform SDKs and returns the same normalized shapes. It is not an engine, and it never routes,
retries, falls back or makes up a terminal outcome. The Rust crate must stay thin for that reason. Routing stays in
the Swift and Kotlin engines, which already call the shared Rust planner.

### Command surface (same as Capacitor)

`configure`, `run`, `checkCapabilities`, `startStream`, `startPrepare`, `cancelStream`, `readArtifact`,
`disposeArtifact`, `close`. The JS facade on top (`speak`, `generateSpeech`, `listVoices`, profiles, error
normalization) is the same as `capacitor-inderun/src/index.ts`.

### What carries over from capacitor-inderun

| Capacitor piece | Size | Tauri equivalent | Reuse |
| --- | --- | --- | --- |
| `src/definitions.ts`, `errors.ts`, `artifacts.ts` | ~470 lines | Same, with no Capacitor import | Almost verbatim |
| `src/streaming.ts` (rebuilds the stream on the JS side) | ~380 lines | Same logic over a `Channel` instead of `addListener` | Most of it. Only the transport changes |
| `src/index.ts` (facade, lazy web fallback) | ~460 lines | Same. `registerPlugin` is replaced by `invoke` | Most of it |
| `src/web.ts` (`WebPlugin` over `@independo/inderun-web`) | ~360 lines | Becomes the **desktop** implementation | Most of it |
| `IndeRunCapacitorBridge.swift` + stream registry | ~720 lines | Tauri `Plugin` subclass + the same bridge | Logic carries over. Its 31 `JSObject`/`CAPPluginCall` uses change |
| `IndeRunSerializer.kt`, `IndeRunCapacitorPlugin.kt`, registry, config | ~1,570 lines | `@TauriPlugin` class + the same serializer | Logic carries over. ~90 Capacitor type uses change |
| Tests (~1,960 TS lines plus Swift tests) | | Same scenarios | Can be ported |

Two details make the port cheaper than it looks:

- On Android, Capacitor's `JSObject` and Tauri's `app.tauri.plugin.JSObject` both subclass `org.json.JSONObject`.
  If `IndeRunSerializer.kt` is changed to produce `JSONObject`, it can serve both plugins.
- On iOS, Tauri's `Invoke` can resolve with an `Encodable`. The IndeRun Swift contracts are already `Codable`, so
  some of the hand-written `JSObject` encoding can go away.

**Recommendation:** don't copy the code. First extract the transport-neutral parts (the TS stream rebuilding and
facade, the Swift bridge, the Kotlin serializer) so both bridges share them. Otherwise every contract change has to
be made in two bridge repos, plus three SDKs. A later section discusses where that shared code should live.

## What has to be adjusted

### In the IndeRun SDKs (this repository)

Probably **nothing is required** for mobile. The plugin uses the released SwiftPM and Maven artifacts, just as
Capacitor does. Possible small follow-ups, depending on the spikes:

1. **Apple XCFramework linkage.** `InderunRouteCoreFFI` and `InderunSpeechTextFFI` are **dynamic** frameworks
   (`@rpath/…framework`, see `scripts/build-route-core-apple.mjs`). A Tauri app builds its iOS plugin's Swift package
   through Tauri's Cargo build, not through Xcode's SwiftPM integration. A dynamic `binaryTarget` may therefore link
   but never be copied into the `.app`, so the app would crash at launch with `dyld: Library not loaded`. If the spike
   confirms this, we either document an "Embed Frameworks" step for `gen/apple`, or this repository offers a static
   variant. That decision would need its own ADR, because the committed frameworks, the provenance manifests and
   `verify:route-core-apple` all assume dylibs.
2. **Docs:** add a Tauri row to `docs/platforms/compatibility.md` and a `docs/getting-started/tauri.md` quickstart
   (ADR 024), and extend the bridge paragraph in `architecture.md` from "Capacitor" to "bridges (Capacitor, Tauri)".

### In a new repository `tauri-plugin-inderun`

Use a separate repository, like `capacitor-inderun`. It versions on its own schedule, consumes tagged SDK releases,
and keeps a Tauri toolchain out of this repository's CI. Names: crate `tauri-plugin-inderun` and npm
`@independo/tauri-plugin-inderun`. The plugin identifier is `inderun`, which meets Tauri's lowercase identifier
rule.

Work items:

- Scaffold with `tauri plugin new inderun` (with the Android and iOS projects). Raise the minimums to **iOS 16** and
  **Android minSdk 26** to match the SDKs.
- Rust crate: the command table, `build.rs` with `COMMANDS`, the permission files and a `default` set that allows
  every command, and plugin config (an optional default `configure` payload). No routing logic. It must not
  deserialize the contract payloads into Rust types. It passes them through as `serde_json::Value`, so the crate never
  becomes a fourth contract implementation.
- Streaming over a `Channel`, one per `startStream` or `startPrepare` call. Channels are per-call and ordered, which
  is cleaner than Capacitor's global `indeRunStreamEvent` listener plus a filter on `streamId`. `sequence` stays the
  ordering authority. The JS side must still drop events that arrive after `cancel()` or after the terminal event, as
  `streaming.ts` already does.
- Secrets: same as Capacitor. Only `authContextRef` or `auth: "none"` is allowed, resolved by the SDK's host secure
  storage (Keychain or Android keystore). Raw keys never cross `invoke`.
- `artifactDestinations`: stays opaque refs resolved natively. A Tauri app may want them resolved against its own
  `appDataDir`. That can come later.
- CI: build the example app for iOS (macOS runner) and Android (emulator), and run the ported bridge tests. Release
  to crates.io and npm with semantic-release, pinned to the IndeRun SDK version as `capacitor-inderun` is.

## Desktop options

Tauri desktop (macOS, Windows, Linux) has no Swift or Kotlin plugin mechanism. Only Rust runs there.

| Option | What you get | Effort | Recommendation |
| --- | --- | --- | --- |
| **A. Web SDK in the webview** (the plugin's JS side falls back to `@independo/inderun-web`, as Capacitor's `web.ts` does) | ONNX Runtime Web with a model the app supplies, an OpenAI-compatible cloud route, and Web Speech where the webview has it (WebView2 and WKWebView. WebKitGTK is uncertain) | Low (~1–2 weeks: CSP must allow `wasm-unsafe-eval`, WASM loading over `tauri://` and `http://tauri.localhost`, docs) | **Do first.** The cost is low, and apps get one API on every target |
| **A+. Tauri-provided host services** for the Web SDK (HTTP through Rust to avoid CORS, secure storage through the OS keychain, artifact destinations in `appDataDir`) | The cloud route works without a proxy. `authContextRef` resolves natively | Medium (~2 weeks) | After A, if users ask for it |
| **B. Native macOS** through a `@_cdecl` C shim over the Swift SDK, called from `desktop.rs` | Apple Foundation Models (macOS 26+), Core AI and ONNX speech on Mac | Medium–high (~2–3 weeks: a C ABI, threading, a streaming callback, packaging the Swift dylibs into the `.app`) | Later. This is the only desktop path to a real on-device model |
| **C. A Rust engine** | Every desktop OS, natively | Very high. This would be a fourth engine, with matching parity, conformance fixtures and providers | **No.** It is not in scope and would add parity cost to every future change |

Be honest about one limitation in the docs. With option A, a `local_required` text request on Windows or Linux has
**no eligible provider unless the app ships an ONNX model**. Chrome's Prompt API is not exposed in Tauri's webviews,
including WebView2. The capability check will report this correctly. Users should still not be led to expect
anything else.

## Risks

| Risk | Impact | How to resolve |
| --- | --- | --- |
| Dynamic route-core XCFrameworks are not embedded in a Tauri iOS app (see above) | iOS blocker | Spike in week 1. Fix with a documented embed step or a static variant (ADR) |
| **Android toolchain floor.** IndeRun needs `compileSdk` 37, AGP 9.1+ and Kotlin Gradle plugin 2.4.21. Tauri's generated `gen/android` project and its `tauri-android` library may pin older AGP and Kotlin versions | Android blocker until aligned | Spike in week 1. Check whether `tauri android init` output builds with AGP 9.1 and Kotlin 2.4 |
| Two native toolchains per bridge (Capacitor and Tauri) double the maintenance for every contract change | Ongoing cost | Extract a shared bridge core before or during the port |
| `run_mobile_plugin` from Rust is synchronous | Long runs could block a Tauri thread | Don't route long calls through Rust command handlers. Use the async mobile call or let JS invoke the native command directly, and check which one Tauri 2.x supports for plugin commands |
| Tauri permission and capability setup is a new failure mode (a command not allowed, so `invoke` is rejected) | Developer experience | Ship `inderun:default` and add an entry to Troubleshooting |
| Tauri's iOS and Android support is younger than Capacitor's | Unknown edge cases | Test on devices. Record the results in `docs/verification/` |

## Roadmap

| Phase | Scope | Estimate | Exit criterion |
| --- | --- | --- | --- |
| 0. Spike | A minimal Tauri app that links the IndeRun Swift and Kotlin SDKs and calls `checkCapabilities()` on a physical iPhone and Android device | 1 week | Both platforms launch and return capability snapshots, or a written blocker with a fix proposal |
| 1. Shared bridge core | Extract the transport-neutral TS, Swift and Kotlin code from `capacitor-inderun`. Capacitor keeps working unchanged | 1–2 weeks | Capacitor's tests pass on the extracted core |
| 2. Mobile MVP | `configure`, `run`, `checkCapabilities`, `close`, error normalization, permissions | 1–2 weeks | Capacitor's `run` scenarios pass on iOS and Android through Tauri |
| 3. Streaming and the rest | `startStream` and `startPrepare` over `Channel`, `cancelStream`, artifacts, speech facade | 2 weeks | Streaming conformance scenarios hold: one terminal event and no events after cancel |
| 4. Desktop through the webview (option A) | The JS fallback to `@independo/inderun-web`, CSP and WASM loading, docs | 1–2 weeks | The example app runs on macOS, Windows and Linux |
| 5. Release and docs | Example app, CI, crates.io and npm publishing, `docs/getting-started/tauri.md`, compatibility row | 1–2 weeks | A published 0.1.0 with a tested-set entry |
| 6. Optional | A+ host services, B native macOS | 2–5 weeks | Decided after phase 5 based on user feedback |

**Total for phases 0–5: ~7–10 engineer-weeks.** Phase 1 is optional, but skipping it costs more over time.

## Open decisions for the owner

1. **Shared bridge core, or copy.** Extracting first adds ~1–2 weeks now and saves duplicate work later.
   Recommended: extract. Where it lives is the next question: a third repository, `capacitor-inderun`, or a package
   in this monorepo. A monorepo package would version with the SDK, which fits the existing rule that bridges stay
   pinned to the SDK version.
2. **Desktop ambition:** option A only, or also commit to B (native macOS) now.
3. **Static Apple frameworks:** if the spike confirms the embedding problem, either accept a documented manual step
   or change this repository's Apple packaging (needs an ADR).
4. **Milestone:** open a GitHub issue or milestone for this, since scope is tracked there and not in this document.
